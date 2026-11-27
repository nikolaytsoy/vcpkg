<#
.SYNOPSIS
Read-only host report before creating the vcpkg review VM.

.DESCRIPTION
Prints logical processors, memory, free disk space, Hyper-V state, existing
VMs, and whether "Default Switch" exists. Suggests a VM size: all logical processors
and half of the host memory. The user decides the final size. Works without elevation.

.PARAMETER Name
VM name to check for conflicts.
#>
param([string]$Name = 'vcpkg')

. "$PSScriptRoot\VcpkgVm.Common.ps1"

$cs = Get-CimInstance Win32_ComputerSystem
$os = Get-CimInstance Win32_OperatingSystem
$logical = [int]$cs.NumberOfLogicalProcessors
$memoryGB = [math]::Floor($cs.TotalPhysicalMemory / 1GB)
$freeMemoryGB = [math]::Floor($os.FreePhysicalMemory / 1MB)

Write-Step 'Host'
Write-Note "$($os.Caption), build $($os.BuildNumber)"
Write-Note "$logical logical processors, $memoryGB GB memory ($freeMemoryGB GB free now)"
Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
    Write-Note ('{0} {1:N0} GB free' -f $_.DeviceID, ($_.FreeSpace / 1GB))
}

Write-Step 'Hyper-V'
$hyperV = (Get-CimInstance Win32_OptionalFeature -Filter "Name='Microsoft-Hyper-V'").InstallState -eq 1
Write-Note "Enabled: $hyperV"
Write-Note "Hypervisor running: $($cs.HypervisorPresent)"
if ($hyperV -and -not $cs.HypervisorPresent) { Write-Note 'Hyper-V is enabled but not running. Restart the host, or turn on virtualization in the firmware settings.' }
if ($hyperV) {
    try {
        $vms = @(Get-VM)
        Write-Note "Existing VMs: $(if ($vms) { ($vms | ForEach-Object { "$($_.Name) ($($_.State))" }) -join ', ' } else { 'none' })"
        if ($vms | Where-Object Name -eq $Name) { Write-Note "A VM named '$Name' exists. Choose another name." }
        Write-Note "Default Switch: $([bool](Get-VMSwitch -Name 'Default Switch' -ErrorAction SilentlyContinue))"
    } catch {
        Write-Note 'Cannot list VMs and switches without elevation. New-VcpkgVm.ps1 checks the name and Default Switch.'
    }
}

$suggestedVcpu = [math]::Min(1024, $logical)
$suggestedMemoryGB = [math]::Max(4, [math]::Floor($memoryGB / 2))
Write-Step 'Suggested VM size'
Write-Note "-ProcessorCount $suggestedVcpu -MemoryGB $suggestedMemoryGB (all logical processors, half of the host memory)"
Write-Note 'The VM memory is static: each VM start needs that much free host memory.'
if ($suggestedMemoryGB -gt $freeMemoryGB) { Write-Note "Only $freeMemoryGB GB is free now. Close programs on the host or choose less memory." }
if ($logical -lt 8 -or $memoryGB -lt 24) { Write-Note 'This host is small. Builds in the VM will be slow, and the host can run short of memory.' }