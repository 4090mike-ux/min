$ErrorActionPreference = 'Stop'

$ServerDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RequiredJavaMajor = 21
$Port = 25565

Set-Location -LiteralPath $ServerDir

function Write-Step {
    param([string] $Message)
    Write-Host "==> $Message"
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

function Install-Java {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw 'Java 21 is not installed and winget was not found. Install Java 21 manually, then run start.bat again.'
    }

    Write-Step 'Java 21 was not found. Installing Eclipse Temurin 21 JRE with winget.'
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
        return
    }

    Write-Step 'Java install needs administrator approval. Approve the Windows prompt to continue.'
    $adminCommand = 'winget install --id EclipseAdoptium.Temurin.21.JRE -e --accept-package-agreements --accept-source-agreements --silent'
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($adminCommand))
    $process = Start-Process -FilePath powershell.exe -ArgumentList "-NoProfile -EncodedCommand $encodedCommand" -Verb RunAs -Wait -PassThru

    if ($process.ExitCode -ne 0) {
        throw 'Java 21 installation failed or was cancelled.'
    }
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
    $tcpOk = Test-FirewallRule -DisplayName 'Minecraft Java Server 25565 TCP' -Protocol 'TCP'
    $udpOk = Test-FirewallRule -DisplayName 'Minecraft Java Server 25565 UDP' -Protocol 'UDP'

    if ($tcpOk -and $udpOk) {
        return
    }

    $firewallScript = Join-Path $ServerDir 'open_firewall_admin.ps1'
    if (-not (Test-Path -LiteralPath $firewallScript -PathType Leaf)) {
        Write-Warning 'Firewall setup script was not found. External players may not be able to connect.'
        return
    }

    Write-Step 'Opening Minecraft firewall rules. Approve the administrator prompt if it appears.'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$firewallScript`""
    $process = Start-Process -FilePath powershell.exe -ArgumentList $arguments -Verb RunAs -Wait -PassThru

    if ($process.ExitCode -ne 0) {
        Write-Warning 'Firewall setup did not complete. Run open_firewall_admin.ps1 as administrator if outside connections fail.'
    }
}

function Test-EulaAccepted {
    $eulaPath = Join-Path $ServerDir 'eula.txt'
    if (-not (Test-Path -LiteralPath $eulaPath -PathType Leaf)) {
        return $false
    }

    return [bool] (Select-String -LiteralPath $eulaPath -Pattern '^eula=true$' -Quiet)
}

$serverJar = Join-Path $ServerDir 'server.jar'
if (-not (Test-Path -LiteralPath $serverJar -PathType Leaf)) {
    throw "server.jar was not found in $ServerDir"
}

if (-not (Test-EulaAccepted)) {
    Write-Warning 'Minecraft EULA is not accepted. Edit eula.txt and set eula=true after reading the EULA.'
    exit 1
}

$listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($listener) {
    $process = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
    if ($process) {
        Write-Host "Port $Port is already in use by PID $($process.Id) ($($process.ProcessName))."
        Write-Host 'If this is the Minecraft server, it is already running.'
    } else {
        Write-Host "Port $Port is already in use."
    }
    exit 0
}

$java = Find-Java
if (-not $java) {
    Install-Java
    $java = Find-Java
}

if (-not $java) {
    throw 'Java 21 is still not available after installation.'
}

Write-Step "Using Java $($java.Major): $($java.Path)"
Ensure-Firewall

Write-Step 'Starting Minecraft server.'
& $java.Path -Xms1G -Xmx4G -jar $serverJar nogui
