$ErrorActionPreference = 'Stop'

$ServerDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$MinecraftVersion = '1.21.11'
$RequiredJavaMajor = 21
$Port = 25565
$ManifestUrl = 'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json'
$RuntimeDir = Join-Path $ServerDir '.runtime'
$PortableJavaDir = Join-Path $RuntimeDir 'java21'
$DownloadDir = Join-Path $RuntimeDir 'downloads'

Set-Location -LiteralPath $ServerDir

function Write-Step {
    param([string] $Message)
    Write-Host "==> $Message"
}

function Write-SoftWarning {
    param([string] $Message)
    Write-Host "WARNING: $Message" -ForegroundColor Yellow
}

function Invoke-WithRetry {
    param(
        [scriptblock] $Action,
        [int] $Retries = 3,
        [int] $DelaySeconds = 2
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            return & $Action
        } catch {
            $lastError = $_
            if ($attempt -lt $Retries) {
                Start-Sleep -Seconds $DelaySeconds
            }
        }
    }

    throw $lastError
}

function Invoke-DownloadFile {
    param(
        [string] $Uri,
        [string] $OutFile
    )

    New-Item -ItemType Directory -Path (Split-Path -Parent $OutFile) -Force | Out-Null
    $tempFile = "$OutFile.tmp"
    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue

    Invoke-WithRetry -Action {
        Invoke-WebRequest -Uri $Uri -OutFile $tempFile -UseBasicParsing
    } | Out-Null

    Move-Item -LiteralPath $tempFile -Destination $OutFile -Force
}

function Get-Json {
    param([string] $Uri)

    return Invoke-WithRetry -Action {
        Invoke-RestMethod -Uri $Uri
    }
}

function Get-JavaMajorVersion {
    param([string] $JavaPath)

    try {
        $output = & $JavaPath -version 2>&1 | Out-String
    } catch {
        return $null
    }

    if ($output -notmatch 'version "([^"]+)"') {
        return $null
    }

    $version = $Matches[1]
    if ($version -match '^1\.(\d+)') {
        return [int] $Matches[1]
    }

    if ($version -match '^(\d+)') {
        return [int] $Matches[1]
    }

    return $null
}

function Find-Java {
    $paths = New-Object System.Collections.Generic.List[string]

    $portableJava = Join-Path $PortableJavaDir 'bin\java.exe'
    if (Test-Path -LiteralPath $portableJava -PathType Leaf) {
        $paths.Add($portableJava)
    }

    if ($env:JAVA_HOME) {
        $paths.Add((Join-Path $env:JAVA_HOME 'bin\java.exe'))
    }

    $javaCommand = Get-Command java -ErrorAction SilentlyContinue
    if ($javaCommand) {
        $paths.Add($javaCommand.Source)
    }

    $searchRoots = @(
        (Join-Path $env:ProgramFiles 'Eclipse Adoptium'),
        (Join-Path $env:ProgramFiles 'Java'),
        (Join-Path $env:ProgramFiles 'Microsoft'),
        (Join-Path $env:ProgramFiles 'Zulu'),
        (Join-Path $env:ProgramFiles 'Amazon Corretto')
    )

    if (${env:ProgramFiles(x86)}) {
        $searchRoots += @(
            (Join-Path ${env:ProgramFiles(x86)} 'Eclipse Adoptium'),
            (Join-Path ${env:ProgramFiles(x86)} 'Java')
        )
    }

    foreach ($root in $searchRoots | Where-Object { $_ -and (Test-Path -LiteralPath $_) }) {
        Get-ChildItem -LiteralPath $root -Recurse -Filter java.exe -ErrorAction SilentlyContinue |
            ForEach-Object { $paths.Add($_.FullName) }
    }

    foreach ($path in $paths | Where-Object { $_ } | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }

        $major = Get-JavaMajorVersion -JavaPath $path
        if ($major -and $major -ge $RequiredJavaMajor) {
            return [pscustomobject]@{
                Path = $path
                Major = $major
            }
        }
    }

    return $null
}

function Get-AdoptiumArchitecture {
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    switch ($arch) {
        'X64' { return 'x64' }
        'Arm64' { return 'aarch64' }
        'X86' { return 'x86' }
        default { throw "Unsupported Windows architecture for automatic Java download: $arch" }
    }
}

function Install-PortableJava {
    Write-Step 'Java 21 was not found. Downloading portable Eclipse Temurin 21 JRE.'

    $architecture = Get-AdoptiumArchitecture
    $javaZip = Join-Path $DownloadDir 'temurin21-jre.zip'
    $extractDir = Join-Path $RuntimeDir 'java21-extract'
    $downloadUrl = "https://api.adoptium.net/v3/binary/latest/21/ga/windows/$architecture/jre/hotspot/normal/eclipse?project=jdk"

    Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
    Invoke-DownloadFile -Uri $downloadUrl -OutFile $javaZip
    Expand-Archive -LiteralPath $javaZip -DestinationPath $extractDir -Force

    $javaExe = Get-ChildItem -LiteralPath $extractDir -Recurse -Filter java.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\bin\\java\.exe$' } |
        Select-Object -First 1

    if (-not $javaExe) {
        throw 'Portable Java download completed, but java.exe was not found inside the archive.'
    }

    Remove-Item -LiteralPath $PortableJavaDir -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item -LiteralPath (Split-Path -Parent (Split-Path -Parent $javaExe.FullName)) -Destination $PortableJavaDir -Force
    Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $javaZip -Force -ErrorAction SilentlyContinue
}

function Install-JavaWithWinget {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        return $false
    }

    Write-Step 'Trying Java 21 install with winget.'
    $wingetArgs = @(
        'install',
        '--id', 'EclipseAdoptium.Temurin.21.JRE',
        '-e',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--silent'
    )

    & $winget.Source @wingetArgs
    if ($LASTEXITCODE -eq 0) {
        return $true
    }

    try {
        Write-Step 'Winget install may need administrator approval.'
        $adminCommand = 'winget install --id EclipseAdoptium.Temurin.21.JRE -e --accept-package-agreements --accept-source-agreements --silent'
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($adminCommand))
        $process = Start-Process -FilePath powershell.exe -ArgumentList "-NoProfile -EncodedCommand $encodedCommand" -Verb RunAs -Wait -PassThru
        return ($process.ExitCode -eq 0)
    } catch {
        Write-SoftWarning 'Administrator Java install was cancelled or blocked.'
        return $false
    }
}

function Ensure-Java {
    $java = Find-Java
    if ($java) {
        return $java
    }

    try {
        Install-PortableJava
    } catch {
        Write-SoftWarning "Portable Java install failed: $($_.Exception.Message)"
    }

    $java = Find-Java
    if ($java) {
        return $java
    }

    if (Install-JavaWithWinget) {
        $java = Find-Java
        if ($java) {
            return $java
        }
    }

    throw 'Java 21 could not be installed automatically. Check the internet connection, Windows permissions, or install Java 21 manually.'
}

function Get-MinecraftVersionMetadata {
    Write-Step "Checking Minecraft server metadata for $MinecraftVersion."
    $manifest = Get-Json -Uri $ManifestUrl
    $entry = $manifest.versions | Where-Object { $_.id -eq $MinecraftVersion } | Select-Object -First 1
    if (-not $entry) {
        throw "Minecraft version $MinecraftVersion was not found in the official Mojang manifest."
    }

    return Get-Json -Uri $entry.url
}

function Ensure-ServerJar {
    $serverJar = Join-Path $ServerDir 'server.jar'
    $metadata = $null

    try {
        $metadata = Get-MinecraftVersionMetadata
    } catch {
        if (Test-Path -LiteralPath $serverJar -PathType Leaf) {
            Write-SoftWarning "Could not reach Mojang metadata. Existing server.jar will be used without online verification."
            return $serverJar
        }

        throw "server.jar is missing and Mojang metadata could not be reached: $($_.Exception.Message)"
    }

    $expectedSha1 = $metadata.downloads.server.sha1
    $downloadUrl = $metadata.downloads.server.url

    if (Test-Path -LiteralPath $serverJar -PathType Leaf) {
        $actualSha1 = (Get-FileHash -Algorithm SHA1 -LiteralPath $serverJar).Hash.ToLowerInvariant()
        if ($actualSha1 -eq $expectedSha1) {
            return $serverJar
        }

        $backup = Join-Path $ServerDir ("server.jar.bad.{0}" -f (Get-Date -Format 'yyyyMMddHHmmss'))
        Write-SoftWarning 'server.jar is missing or damaged. Downloading a clean copy.'
        Move-Item -LiteralPath $serverJar -Destination $backup -Force
    } else {
        Write-Step 'server.jar was not found. Downloading it from Mojang.'
    }

    Invoke-DownloadFile -Uri $downloadUrl -OutFile $serverJar
    $newSha1 = (Get-FileHash -Algorithm SHA1 -LiteralPath $serverJar).Hash.ToLowerInvariant()
    if ($newSha1 -ne $expectedSha1) {
        Remove-Item -LiteralPath $serverJar -Force -ErrorAction SilentlyContinue
        throw 'Downloaded server.jar failed SHA1 verification.'
    }

    return $serverJar
}

function Test-FirewallRule {
    param(
        [string] $DisplayName,
        [string] $Protocol
    )

    try {
        $rule = Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction Stop
        $port = $rule | Get-NetFirewallPortFilter -ErrorAction Stop
        return ($rule.Enabled -eq 'True' -and
            $rule.Action -eq 'Allow' -and
            $port.Protocol -eq $Protocol -and
            $port.LocalPort -eq "$Port")
    } catch {
        return $false
    }
}

function Ensure-Firewall {
    if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
        return
    }

    $tcpOk = Test-FirewallRule -DisplayName 'Minecraft Java Server 25565 TCP' -Protocol 'TCP'
    $udpOk = Test-FirewallRule -DisplayName 'Minecraft Java Server 25565 UDP' -Protocol 'UDP'

    if ($tcpOk -and $udpOk) {
        return
    }

    $firewallScript = Join-Path $ServerDir 'open_firewall_admin.ps1'
    if (-not (Test-Path -LiteralPath $firewallScript -PathType Leaf)) {
        Write-SoftWarning 'Firewall setup script was not found. External players may not be able to connect.'
        return
    }

    try {
        Write-Step 'Opening Minecraft firewall rules. Approve the administrator prompt if it appears.'
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$firewallScript`""
        $process = Start-Process -FilePath powershell.exe -ArgumentList $arguments -Verb RunAs -Wait -PassThru

        if ($process.ExitCode -ne 0) {
            Write-SoftWarning 'Firewall setup did not complete. The server can still start, but outside connections may fail.'
        }
    } catch {
        Write-SoftWarning 'Firewall setup was cancelled or blocked. The server can still start, but outside connections may fail.'
    }
}

function Test-EulaAccepted {
    $eulaPath = Join-Path $ServerDir 'eula.txt'
    if (-not (Test-Path -LiteralPath $eulaPath -PathType Leaf)) {
        @(
            '#By changing the setting below to TRUE you are indicating your agreement to the Minecraft EULA.'
            '#https://aka.ms/MinecraftEULA'
            'eula=false'
        ) | Set-Content -LiteralPath $eulaPath -Encoding ASCII
        return $false
    }

    return [bool] (Select-String -LiteralPath $eulaPath -Pattern '^eula=true$' -Quiet)
}

function Test-PortAvailable {
    $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $listener) {
        return $true
    }

    $process = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
    if ($process) {
        Write-Host "Port $Port is already in use by PID $($process.Id) ($($process.ProcessName))."
        if ($process.ProcessName -eq 'java') {
            Write-Host 'A Java server is already listening on this port, so no second server was started.'
        }
    } else {
        Write-Host "Port $Port is already in use."
    }

    return $false
}

function Get-JavaMemoryArgs {
    try {
        $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $totalGb = [math]::Round($computer.TotalPhysicalMemory / 1GB, 2)

        if ($totalGb -ge 8) {
            return @('-Xms1G', '-Xmx4G')
        }

        if ($totalGb -ge 4) {
            return @('-Xms512M', '-Xmx2G')
        }

        return @('-Xms512M', '-Xmx1G')
    } catch {
        return @('-Xms512M', '-Xmx2G')
    }
}

function Invoke-Main {
    if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
        throw 'This launcher is designed for Windows. Use the Minecraft server jar directly on other operating systems.'
    }

    if (-not (Test-EulaAccepted)) {
        Write-SoftWarning 'Minecraft EULA is not accepted. Read https://aka.ms/MinecraftEULA, set eula=true, then run start.bat again.'
        exit 1
    }

    if (-not (Test-PortAvailable)) {
        exit 0
    }

    $serverJar = Ensure-ServerJar
    $java = Ensure-Java
    Write-Step "Using Java $($java.Major): $($java.Path)"

    Ensure-Firewall

    $memoryArgs = Get-JavaMemoryArgs
    Write-Step "Using memory settings: $($memoryArgs -join ' ')"
    Write-Step "Starting Minecraft server $MinecraftVersion on port $Port."
    & $java.Path @memoryArgs -jar $serverJar nogui
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Minecraft server exited with code $exitCode."
    }
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-Main
} catch {
    Write-Host ''
    Write-Host 'Launcher failed.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ''
    Write-Host 'Common fixes:'
    Write-Host '- Check that this folder is writable.'
    Write-Host '- Check the internet connection if Java or server.jar must be downloaded.'
    Write-Host '- Approve the Windows administrator prompt for firewall rules.'
    Write-Host '- Make sure no other program is using port 25565.'
    exit 1
}
