<#
.SYNOPSIS
Builds the vcpkg CI container images with wslc. Run it in the VM after Install-Wslc.ps1.

.DESCRIPTION
Builds images from the Dockerfiles in scripts\azure-pipelines of this
repository and tags them with the names that vcpkg CI uses, read from the
pipeline files. No registry credentials are needed. Build output goes to
%TEMP%\vcpkg-vm\wslc-build-<image>.log.

.PARAMETER Image
Images to build: linux, arm64-linux, android. Default: all three.
#>
param([ValidateSet('linux', 'arm64-linux', 'android')][string[]]$Image = @('linux', 'arm64-linux', 'android'))

$ErrorActionPreference = 'Stop'
$pipelines = (Resolve-Path -LiteralPath "$PSScriptRoot\..\azure-pipelines").Path
$images = @{
    'linux'       = @{ Dir = 'linux'; Yaml = 'azure-pipelines.yml'; Pattern = '[\w.-]+/vcpkg-linux:[\w.-]+' }
    'arm64-linux' = @{ Dir = 'linux-arm64'; Yaml = 'azure-pipelines.yml'; Pattern = '[\w.-]+/vcpkg-arm64-linux:[\w.-]+' }
    'android'     = @{ Dir = 'android'; Yaml = 'android\azure-pipelines.yml'; Pattern = '[\w.-]+/vcpkg-android:[\w.-]+' }
}
New-Item -ItemType Directory -Force -Path "$env:TEMP\vcpkg-vm" | Out-Null

foreach ($name in $Image) {
    $spec = $images[$name]
    $match = Select-String -LiteralPath "$pipelines\$($spec.Yaml)" -Pattern $spec.Pattern | Select-Object -First 1
    if (-not $match) { throw "No $name image name in $pipelines\$($spec.Yaml)." }
    $tag = $match.Matches[0].Value
    $log = "$env:TEMP\vcpkg-vm\wslc-build-$name.log"
    Write-Host "Building $tag (log: $log)"
    Push-Location "$pipelines\$($spec.Dir)"
    try {
        & cmd.exe /d /c "wslc build . -t $tag --build-arg BUILD_DATE=$(Get-Date -Format yyyy-MM-dd) > `"$log`" 2>&1"
        if ($LASTEXITCODE -ne 0) {
            Get-Content -LiteralPath $log -Tail 30 | ForEach-Object { Write-Host "  $_" }
            throw "wslc build failed for $tag with exit code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }
}
& wslc image list
