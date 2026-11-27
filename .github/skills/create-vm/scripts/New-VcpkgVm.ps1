<#
.SYNOPSIS
Creates the vcpkg review VM with an unattended Windows Server installation.

.DESCRIPTION
Applies Windows Server from the ISO to a new
dynamic VHDX, writes an unattend.xml, creates a Generation 2 VM on
"Default Switch", starts it, and waits until PowerShell Direct accepts the
Administrator credential.

unattend.xml answers the first-boot setup screens (computer name, time zone,
region and keyboard from the host, license, Administrator password), so
Windows starts without anyone at the console.

The ISO and the VHDX partitions appear as drives on the host while the image
is applied. The script writes only to the disk of the VHDX it creates. If a
step before the first boot fails, it removes the VM and the VHDX it created.

.PARAMETER IsoPath
Windows Server 2025 ISO, for example the evaluation ISO from
https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025

.PARAMETER Name
VM name and guest computer name: 1 to 15 letters, digits, or hyphens, not
only digits.

.PARAMETER ProcessorCount
vCPUs.

.PARAMETER MemoryGB
Static memory in GB.

.PARAMETER DiskGB
Maximum size of the dynamic VHDX.

.PARAMETER VhdFolder
Folder for <Name>.vhdx. Created if it does not exist. Defaults to the
Hyper-V default VHD folder.

Asks twice for the password of the VM's local Administrator.
#>
param(
    [Parameter(Mandatory)][string]$IsoPath,
    [ValidatePattern('^(?![0-9]+$)[A-Za-z0-9-]{1,15}$')][string]$Name = 'vcpkg',
    [Parameter(Mandatory)][ValidateRange(2, 1024)][int]$ProcessorCount,
    [Parameter(Mandatory)][ValidateRange(4, 4096)][int]$MemoryGB,
    [ValidateRange(64, 65536)][int]$DiskGB = 200,
    [string]$VhdFolder
)

. "$PSScriptRoot\VcpkgVm.Common.ps1"
Assert-Elevated

$IsoPath = (Resolve-Path -LiteralPath $IsoPath).Path
if (-not $VhdFolder) { $VhdFolder = (Get-VMHost).VirtualHardDiskPath }
$VhdPath = [IO.Path]::GetFullPath((Join-Path $VhdFolder "$Name.vhdx"))
if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { throw "A VM named '$Name' already exists." }
if (Test-Path -LiteralPath $VhdPath) { throw "$VhdPath already exists." }
if (-not (Get-VMSwitch -Name 'Default Switch' -ErrorAction SilentlyContinue)) {
    throw "'Default Switch' does not exist. Do not create an external switch; check the host's Hyper-V networking."
}
$Credential = Get-VcpkgVmCredential $Name -New

function New-UnattendXml([string]$ComputerName, [string]$Password) {
    # Windows Setup expects the password with this suffix, as UTF-16LE base64.
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Password + 'AdministratorPassword'))
    $inputLocale = @((Get-WinUserLanguageList)[0].InputMethodTips)[0]
    if (-not $inputLocale) { $inputLocale = '0409:00000409' }
    $component = 'processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"'
    @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" $component>
      <ComputerName>$ComputerName</ComputerName>
      <TimeZone>$((Get-TimeZone).Id)</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" $component>
      <InputLocale>$inputLocale</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>$((Get-Culture).Name)</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" $component>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>$encoded</Value>
          <PlainText>false</PlainText>
        </AdministratorPassword>
      </UserAccounts>
    </component>
  </settings>
</unattend>
"@
}

$isoMounted = $false
$vhdCreated = $false
$vhdMounted = $false
$succeeded = $false
try {
    Write-Step "Mounting $IsoPath"
    Mount-DiskImage -ImagePath $IsoPath | Out-Null
    $isoMounted = $true
    $isoVolume = Get-DiskImage -ImagePath $IsoPath | Get-Volume | Where-Object DriveLetter | Select-Object -First 1
    if (-not $isoVolume) { throw "The mounted ISO has no drive letter." }
    $wim = "$($isoVolume.DriveLetter):\sources\install.wim"
    # A Windows Server ISO has several images; use Standard with the desktop (also matches the evaluation image name).
    $image = Get-WindowsImage -ImagePath $wim | Where-Object ImageName -like '*Standard*(Desktop Experience)' | Select-Object -First 1
    if (-not $image) { throw "No Standard (Desktop Experience) image in $wim." }

    Write-Step "Creating $VhdPath"
    New-Item -ItemType Directory -Force -Path $VhdFolder | Out-Null
    New-VHD -Path $VhdPath -SizeBytes ([int64]$DiskGB * 1GB) -Dynamic | Out-Null
    $vhdCreated = $true
    Mount-VHD -Path $VhdPath
    $vhdMounted = $true
    $disk = Get-VHD -Path $VhdPath | Get-Disk
    # Write only to the empty disk backed by the VHDX created above.
    if ($disk.Location -ne $VhdPath -or $disk.PartitionStyle -ne 'RAW') {
        throw "Mounted disk $($disk.Number) is not the new empty VHDX. Stopping."
    }
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT
    # The EFI partition stays basic data until bcdboot is done: Windows cannot assign a drive letter to an ESP.
    $efi = New-Partition -DiskNumber $disk.Number -Size 260MB -AssignDriveLetter
    Format-Volume -Partition $efi -FileSystem FAT32 -NewFileSystemLabel System -Force -Confirm:$false | Out-Null
    $windows = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $windows -FileSystem NTFS -NewFileSystemLabel Windows -Force -Confirm:$false | Out-Null
    $efiRoot = "$((Get-Partition -DiskNumber $disk.Number -PartitionNumber $efi.PartitionNumber).DriveLetter):"
    $windowsRoot = "$((Get-Partition -DiskNumber $disk.Number -PartitionNumber $windows.PartitionNumber).DriveLetter):"

    Write-Step "Applying $($image.ImageName)"
    Expand-WindowsImage -ImagePath $wim -Index $image.ImageIndex -ApplyPath "$windowsRoot\" | Out-Null

    Write-Step 'Writing boot files and unattend.xml'
    & bcdboot.exe "$windowsRoot\Windows" /s $efiRoot /f UEFI
    if ($LASTEXITCODE -ne 0) { throw "bcdboot failed with exit code $LASTEXITCODE." }
    Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $efi.PartitionNumber -AccessPath "$efiRoot\"
    Set-Partition -DiskNumber $disk.Number -PartitionNumber $efi.PartitionNumber -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    New-Item -ItemType Directory -Force -Path "$windowsRoot\Windows\Panther" | Out-Null
    $xml = New-UnattendXml $Name $Credential.GetNetworkCredential().Password
    Set-Content -LiteralPath "$windowsRoot\Windows\Panther\unattend.xml" -Value $xml -Encoding UTF8

    $succeeded = $true
} finally {
    # Each cleanup runs even if another one fails.
    if ($vhdMounted) { Dismount-VHD -Path $VhdPath -ErrorAction Continue }
    if ($isoMounted) { Dismount-DiskImage -ImagePath $IsoPath -ErrorAction Continue | Out-Null }
    if (-not $succeeded -and $vhdCreated) { Remove-Item -LiteralPath $VhdPath -Force -ErrorAction Continue }
}

Write-Step "Creating and starting VM '$Name'"
$vm = $null
try {
    $vm = New-VM -Name $Name -Generation 2 -MemoryStartupBytes ([int64]$MemoryGB * 1GB) -VHDPath $VhdPath -SwitchName 'Default Switch'
    Set-VMProcessor -VM $vm -Count $ProcessorCount -ExposeVirtualizationExtensions $true
    Set-VMMemory -VM $vm -DynamicMemoryEnabled $false
    Set-VM -VM $vm -AutomaticCheckpointsEnabled $false -CheckpointType Standard -AutomaticStopAction ShutDown
    Start-VM -VM $vm
} catch {
    Write-Note "Removing VM '$Name' and $VhdPath"
    if ($vm) { Remove-VM -VM $vm -Force -ErrorAction Continue }
    Remove-Item -LiteralPath $VhdPath -Force -ErrorAction Continue
    throw
}
Wait-VcpkgVmReady -Name $Name -Credential $Credential
