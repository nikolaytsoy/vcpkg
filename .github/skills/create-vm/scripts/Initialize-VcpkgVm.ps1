<#
.SYNOPSIS
Sets up the vcpkg VM over PowerShell Direct and takes the "clean-baseline" checkpoint.

.DESCRIPTION
Runs the steps of VcpkgVm.Guest.ps1 inside the VM (Base,
Toolchain, Tools) and restarts the VM when a step asks for it.

Asks for the VM Administrator password.

.PARAMETER Name
VM name.

.PARAMETER RepoUrl
vcpkg repository to clone to C:\vcpkg.

.PARAMETER Branch
Branch to clone.
#>
param(
    [string]$Name = 'vcpkg',
    [string]$RepoUrl = 'https://github.com/microsoft/vcpkg.git',
    [string]$Branch = 'master'
)

. "$PSScriptRoot\VcpkgVm.Common.ps1"
Assert-Elevated

$credential = Get-VcpkgVmCredential $Name
if ((Get-VM -Name $Name).State -ne 'Running') { Start-VM -Name $Name }
Wait-VcpkgVmReady -Name $Name -Credential $credential -TimeoutMinutes 10 -CheckPassword

$guestScript = Get-Content -LiteralPath "$PSScriptRoot\VcpkgVm.Guest.ps1" -Raw
foreach ($step in 'Base', 'Toolchain', 'Tools') {
    Write-Step $step
    $output = Invoke-Command -VMName $Name -Credential $credential -ArgumentList $guestScript, $step, $RepoUrl, $Branch -ScriptBlock {
        param($ScriptText, $Step, $RepoUrl, $Branch)
        & ([scriptblock]::Create($ScriptText)) -Step $Step -RepoUrl $RepoUrl -Branch $Branch
    }
    if ($output -contains 'REBOOT-REQUIRED') { Restart-VcpkgVmGuest $Name $credential }
}

Write-Step "Taking checkpoint 'clean-baseline'"
# A guest shutdown; -Force only closes guest applications that block it.
Stop-VM -Name $Name -Force
Checkpoint-VM -Name $Name -SnapshotName 'clean-baseline'
Start-VM -Name $Name
Wait-VcpkgVmReady -Name $Name -Credential $credential
