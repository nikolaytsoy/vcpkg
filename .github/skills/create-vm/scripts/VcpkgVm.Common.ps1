# Shared helpers for the create-vm host scripts. Dot-source; do not run directly.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }

function Write-Note([string]$Message) { Write-Host "    $Message" }

function Assert-Elevated {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script elevated (Run as administrator).'
    }
}

function Get-VcpkgVmBootTime([string]$Name, [pscredential]$Credential) {
    Invoke-Command -VMName $Name -Credential $Credential -ScriptBlock { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime }
}

function Wait-VcpkgVmReady {
    # Waits until PowerShell Direct accepts the credential. With -After, also waits for a boot later than that guest time.
    # The guest rejects the credential until its first boot finishes, so a rejection stops the wait only with
    # -CheckPassword, for a VM that is past its first boot.
    param(
        [string]$Name,
        [pscredential]$Credential,
        [datetime]$After = [datetime]::MinValue,
        [int]$TimeoutMinutes = 30,
        [switch]$CheckPassword
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $lastError = 'none'
    Write-Note "Waiting for PowerShell Direct on VM '$Name'..."
    while ((Get-Date) -lt $deadline) {
        try {
            if ((Get-VcpkgVmBootTime $Name $Credential) -gt $After) { return }
        } catch {
            $lastError = $_.Exception.Message
            if ($CheckPassword -and $lastError -match 'credential is invalid') { throw "VM '$Name' rejected the Administrator password." }
        }
        Start-Sleep -Seconds 15
    }
    throw "VM '$Name' did not become reachable over PowerShell Direct within $TimeoutMinutes minutes. Last error: $lastError"
}

function Restart-VcpkgVmGuest([string]$Name, [pscredential]$Credential) {
    Write-Step "Restarting VM '$Name'"
    # A delayed restart lets the PowerShell Direct call return before the guest goes down. The wait compares
    # with the guest time of the restart, not the previous boot time, which moves when the guest clock is adjusted.
    $restartTime = Invoke-Command -VMName $Name -Credential $Credential -ScriptBlock {
        & shutdown.exe /r /t 5 /d p:4:1
        if ($LASTEXITCODE -ne 0) { throw "shutdown.exe failed with exit code $LASTEXITCODE." }
        Get-Date
    }
    Wait-VcpkgVmReady -Name $Name -Credential $Credential -After $restartTime
}

function Read-VcpkgVmSecret([string]$Prompt) {
    [Net.NetworkCredential]::new('', (Read-Host $Prompt -AsSecureString)).Password
}

function Get-VcpkgVmCredential([string]$Name, [switch]$New) {
    $password = Read-Host "Administrator password for VM '$Name'" -AsSecureString
    if ($password.Length -eq 0) { throw 'The password must not be empty.' }
    if ($New -and [Net.NetworkCredential]::new('', $password).Password -cne (Read-VcpkgVmSecret 'Repeat the password')) {
        throw 'The passwords do not match.'
    }
    New-Object pscredential 'Administrator', $password
}