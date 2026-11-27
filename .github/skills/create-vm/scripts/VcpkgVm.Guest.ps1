<#
.SYNOPSIS
Guest-side setup steps for the vcpkg review VM. Initialize-VcpkgVm.ps1 runs it inside the VM.

.DESCRIPTION
Base       Removes cached unattend files (they can hold the encoded Administrator
           password), enables Win32 long paths, and uninstalls Microsoft
           Defender Antivirus.
Toolchain  Installs Git, clones the vcpkg repository to C:\vcpkg, bootstraps it,
           and runs the vcpkg CI image provisioning (provision-entire-image.ps1).
Tools      Installs GitHub CLI and VS Code Insiders. Its copilot command
           installs Copilot CLI on first run.

A step that needs a reboot outputs REBOOT-REQUIRED. Native command output goes
to %TEMP%\vcpkg-vm\<Step>.log of the Administrator.
#>
param(
    [Parameter(Mandatory)][ValidateSet('Base', 'Toolchain', 'Tools')][string]$Step,
    [string]$RepoUrl = 'https://github.com/microsoft/vcpkg.git',
    [string]$Branch = 'master'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$logDir = "$env:TEMP\vcpkg-vm"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = "$logDir\$Step.log"

function Write-GuestStep([string]$Message) { Write-Host "  [vm] $Message" }

function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Invoke-Logged([string]$CommandLine) {
    # Runs through cmd.exe into the step log: over PowerShell Direct, Windows PowerShell turns
    # native stderr text (such as curl progress) into a terminating error.
    Add-Content -LiteralPath $log -Value "`r`n> $CommandLine"
    & cmd.exe /d /c "$CommandLine >> `"$log`" 2>&1"
    if ($LASTEXITCODE -ne 0) {
        Get-Content -LiteralPath $log -Tail 30 | ForEach-Object { Write-Host "  [vm]   $_" }
        throw "Failed with exit code ${LASTEXITCODE}: $CommandLine (log: $log)"
    }
}

function Invoke-LoggedScript([string]$Path) {
    Invoke-Logged "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"`$ErrorActionPreference='Stop'; & '$Path'`""
}

$rebootRequired = $false
switch ($Step) {
    'Base' {
        Write-GuestStep 'Removing cached unattend files, enabling long paths'
        Get-ChildItem -LiteralPath 'C:\Windows\Panther' -Filter '*unattend*.xml' -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Force
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1

        if ((Get-WindowsFeature -Name Windows-Defender).Installed) {
            Write-GuestStep 'Uninstalling Microsoft Defender Antivirus'
            if (-not (Uninstall-WindowsFeature -Name Windows-Defender -WarningAction SilentlyContinue).Success) { throw 'Uninstalling Windows-Defender failed.' }
            $rebootRequired = $true
        }
    }

    'Toolchain' {
        $ciBase = 'https://raw.githubusercontent.com/microsoft/vcpkg/master/scripts/azure-pipelines/windows'
        $dir = "$env:TEMP\vcpkg-ci"
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Write-GuestStep 'Installing Git (vcpkg CI deploy-git.ps1)'
        Invoke-Logged "curl.exe -fsSL -o `"$dir\utility-prefix.ps1`" $ciBase/utility-prefix.ps1"
        Invoke-Logged "curl.exe -fsSL -o `"$dir\deploy-git.ps1`" $ciBase/deploy-git.ps1"
        Invoke-LoggedScript "$dir\deploy-git.ps1"
        Remove-Item -LiteralPath $dir -Recurse -Force
        Update-SessionPath

        Write-GuestStep "Cloning $RepoUrl ($Branch) to C:\vcpkg and bootstrapping it"
        Invoke-Logged 'git config --system core.longpaths true'
        # Git Credential Manager must not open a sign-in prompt in the VM; git uses only tokens from Set-Tokens.ps1.
        Invoke-Logged 'git config --system credential.interactive false'
        Invoke-Logged "git clone --branch $Branch $RepoUrl C:\vcpkg"
        Invoke-Logged 'C:\vcpkg\bootstrap-vcpkg.bat -disableMetrics'

        Write-GuestStep "Running provision-entire-image.ps1 (output in $log)"
        Invoke-LoggedScript 'C:\vcpkg\scripts\azure-pipelines\windows\provision-entire-image.ps1'
        $rebootRequired = $true
    }

    'Tools' {
        $dir = "$env:TEMP\vcpkg-tools"
        New-Item -ItemType Directory -Force -Path $dir | Out-Null

        Write-GuestStep 'Installing GitHub CLI'
        $release = Invoke-RestMethod 'https://api.github.com/repos/cli/cli/releases/latest'
        $msi = $release.assets | Where-Object name -match '^gh_.*_windows_amd64\.msi$'
        $sums = $release.assets | Where-Object name -match '_checksums\.txt$'
        Invoke-Logged "curl.exe -fsSL -o `"$dir\$($msi.name)`" $($msi.browser_download_url)"
        Invoke-Logged "curl.exe -fsSL -o `"$dir\checksums.txt`" $($sums.browser_download_url)"
        $expected = (Select-String -LiteralPath "$dir\checksums.txt" -SimpleMatch $msi.name).Line.Split(' ')[0]
        if ((Get-FileHash -LiteralPath "$dir\$($msi.name)").Hash -ne $expected) { throw "SHA256 mismatch for $($msi.name)." }
        $proc = Start-Process msiexec.exe -ArgumentList "/i `"$dir\$($msi.name)`" /quiet /norestart" -Wait -PassThru
        if ($proc.ExitCode -notin 0, 3010) { throw "msiexec failed with exit code $($proc.ExitCode)." }

        Write-GuestStep 'Installing VS Code Insiders'
        Invoke-Logged "curl.exe -fsSL -o `"$dir\VSCodeInsidersSetup.exe`" https://update.code.visualstudio.com/latest/win32-x64/insider"
        $signature = Get-AuthenticodeSignature -LiteralPath "$dir\VSCodeInsidersSetup.exe"
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
            throw 'The VS Code Insiders installer does not have a valid Microsoft signature.'
        }
        $proc = Start-Process "$dir\VSCodeInsidersSetup.exe" -ArgumentList '/VERYSILENT /NORESTART /MERGETASKS=!runcode,addtopath' -Wait -PassThru
        if ($proc.ExitCode -ne 0) { throw "VS Code Insiders setup failed with exit code $($proc.ExitCode)." }
        Remove-Item -LiteralPath $dir -Recurse -Force
    }
}

if ($rebootRequired) { 'REBOOT-REQUIRED' }
