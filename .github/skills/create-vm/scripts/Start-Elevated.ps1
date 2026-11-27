<#
.SYNOPSIS
Runs a create-vm host script elevated in a new window and waits for it.

.DESCRIPTION
Shows a UAC prompt and runs the script in a new elevated Windows PowerShell
window, where the user types the prompted secrets. The window's output is
appended to %TEMP%\create-vm.log. When the window closes, prints the
output of this run and exits with the script's exit code. Exits with 1 if the
user declines the UAC prompt.

Parameter values are written into the elevated command as escaped string or
number literals, so they cannot change the command.

.PARAMETER Script
File name of a script in this folder, for example New-VcpkgVm.ps1.

.PARAMETER Parameters
Script parameters, for example @{ Name = 'vcpkg'; MemoryGB = 32 }.
#>
param(
    [Parameter(Mandatory)][string]$Script,
    [hashtable]$Parameters = @{}
)

$ErrorActionPreference = 'Stop'

function ConvertTo-Literal($Value) {
    if ($Value -is [int] -or $Value -is [long]) { return "$Value" }
    "'" + [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent([string]$Value) + "'"
}

$scriptPath = Join-Path $PSScriptRoot (Split-Path -Leaf $Script)
if (-not (Test-Path -LiteralPath $scriptPath)) { throw "No script $scriptPath." }
$log = Join-Path $env:TEMP 'create-vm.log'
$start = if (Test-Path -LiteralPath $log) { (Get-Item -LiteralPath $log).Length } else { 0 }

$splat = ($Parameters.GetEnumerator() | ForEach-Object { "$(ConvertTo-Literal $_.Key) = $(ConvertTo-Literal $_.Value)" }) -join '; '
$command = @"
Start-Transcript -LiteralPath $(ConvertTo-Literal $log) -Append | Out-Null
`$code = 0
`$parameters = @{ $splat }
try { & $(ConvertTo-Literal $scriptPath) @parameters } catch { Write-Host (`$_ | Out-String) -ForegroundColor Red; `$code = 1 }
Stop-Transcript | Out-Null
exit `$code
"@
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
try {
    $process = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
} catch {
    Write-Host "The elevated window did not start: $($_.Exception.Message)"
    exit 1
}

if (Test-Path -LiteralPath $log) {
    $stream = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
    try {
        $stream.Position = $start
        (New-Object IO.StreamReader($stream)).ReadToEnd()
    } finally {
        $stream.Close()
    }
}
exit $process.ExitCode
