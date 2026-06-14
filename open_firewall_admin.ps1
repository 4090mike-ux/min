$ErrorActionPreference = 'Stop'

$ServerDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ResultPath = Join-Path $ServerDir 'firewall_result.txt'

$rules = @(
    @{ Name = 'Minecraft Java Server 25565 TCP'; Protocol = 'TCP' },
    @{ Name = 'Minecraft Java Server 25565 UDP'; Protocol = 'UDP' }
)

foreach ($rule in $rules) {
    $existing = Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue
    if ($existing) {
        Set-NetFirewallRule -DisplayName $rule.Name -Enabled True -Action Allow -Direction Inbound -Profile Any
        Get-NetFirewallPortFilter -AssociatedNetFirewallRule $existing |
            Set-NetFirewallPortFilter -Protocol $rule.Protocol -LocalPort 25565
    } else {
        New-NetFirewallRule `
            -DisplayName $rule.Name `
            -Direction Inbound `
            -Action Allow `
            -Protocol $rule.Protocol `
            -LocalPort 25565 `
            -Profile Any | Out-Null
    }
}

Get-NetFirewallRule -DisplayName 'Minecraft Java Server 25565 *' |
    Get-NetFirewallPortFilter |
    Select-Object Protocol, LocalPort |
    Out-File -LiteralPath $ResultPath -Encoding utf8
