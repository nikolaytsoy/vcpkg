<#
.SYNOPSIS
Installs WSL with wslc (WSL containers) in this VM. Run it in the VM.

.DESCRIPTION
Enables the Windows features Microsoft-Windows-Subsystem-Linux and
VirtualMachinePlatform, and installs the latest WSL release from
https://github.com/microsoft/WSL/releases, which includes wslc.exe. Restart
the VM when the script asks, then check with: wslc run --rm hello-world
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$restartRequired = $false

foreach ($feature in 'Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform') {
    if ((Get-WindowsOptionalFeature -Online -FeatureName $feature).State -ne 'Enabled') {
        Write-Host "Enabling $feature"
        $result = Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart -WarningAction SilentlyContinue
        if ($result.RestartNeeded) { $restartRequired = $true }
    }
}

if (-not (Get-Command wslc.exe -ErrorAction SilentlyContinue)) {
    $release = Invoke-RestMethod 'https://api.github.com/repos/microsoft/WSL/releases/latest'
    $asset = $release.assets | Where-Object name -match '\.x64\.msi$'
    $msi = Join-Path $env:TEMP $asset.name
    Write-Host "Installing WSL $($release.tag_name)"
    & curl.exe -fsSL -o $msi $asset.browser_download_url
    if ($LASTEXITCODE -ne 0) { throw "Download failed: $($asset.browser_download_url)" }
    $signature = Get-AuthenticodeSignature -LiteralPath $msi
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw "$($asset.name) does not have a valid Microsoft signature."
    }
    $proc = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /quiet /norestart" -Wait -PassThru
    Remove-Item -LiteralPath $msi -Force
    if ($proc.ExitCode -notin 0, 3010) { throw "msiexec failed with exit code $($proc.ExitCode)." }
    $restartRequired = $true
}

if ($restartRequired) {
    Write-Host 'Restart the VM (Restart-Computer). Then check with: wslc run --rm hello-world'
} else {
    Write-Host 'WSL with wslc is installed.'
}
