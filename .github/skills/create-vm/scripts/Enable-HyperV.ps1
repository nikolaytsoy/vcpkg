<#
.SYNOPSIS
Enables Hyper-V on the host.

.DESCRIPTION
Enables the Microsoft-Hyper-V Windows feature. Restart the host afterwards.
#>
. "$PSScriptRoot\VcpkgVm.Common.ps1"
Assert-Elevated

Write-Step 'Enabling Hyper-V'
$result = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All -NoRestart -WarningAction SilentlyContinue
if ($result.RestartNeeded) { Write-Host 'Restart the host to finish.' -ForegroundColor Yellow }
