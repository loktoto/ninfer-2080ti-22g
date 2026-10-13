[CmdletBinding()]
param([string]$ToolRoot = '')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Lock = Get-Content -LiteralPath (Join-Path $RepoRoot 'config\windows-sm75-toolchain.json') -Raw | ConvertFrom-Json
if ($Lock.cuda_compiler -ne '13.1.80' -or $Lock.ninja -ne '1.13.2') {
    throw 'Update this provisioner for the changed CUDA/Ninja toolchain lock before provisioning.'
}
if (-not $ToolRoot) { $ToolRoot = Join-Path $RepoRoot '.deps\toolchain' }
$ToolRoot = [IO.Path]::GetFullPath($ToolRoot)
New-Item -ItemType Directory -Force -Path $ToolRoot | Out-Null

function Get-Download([string]$Url, [string]$Path) {
    & curl.exe --location --fail --silent --show-error --retry 3 --output $Path $Url
    if ($LASTEXITCODE -ne 0) { throw "Download failed: $Url" }
}
function Get-VerifiedArchive([string]$Url, [string]$Path, [string]$Hash) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Hash) {
        Get-Download $Url $Path
    }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Hash) {
        throw "SHA-256 mismatch: $Path"
    }
}

# Winget's version 13.1 currently resolves to CUDA 13.1.1, whose nvcc does not
# match the production lock. NVIDIA's 13.1.0 redistributables pin nvcc 13.1.80.
$ManifestPath = Join-Path $ToolRoot 'redistrib_13.1.0.json'
Get-Download 'https://developer.download.nvidia.com/compute/cuda/redist/redistrib_13.1.0.json' $ManifestPath
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if ($Manifest.release_label -ne '13.1.0' -or $Manifest.cuda_nvcc.version -ne $Lock.cuda_compiler) {
    throw 'NVIDIA redistribution manifest does not match the pinned CUDA compiler.'
}
$CudaRoot = Join-Path $ToolRoot 'cuda-13.1.0'
New-Item -ItemType Directory -Force -Path $CudaRoot | Out-Null
foreach ($Component in @('cuda_nvcc','libnvvm','cuda_crt','cuda_cudart','cuda_cccl','cuda_cuobjdump','cuda_nvtx')) {
    $Item = $Manifest.$Component.'windows-x86_64'
    $Zip = Join-Path $ToolRoot ($Component + '.zip')
    Get-VerifiedArchive ('https://developer.download.nvidia.com/compute/cuda/redist/' + $Item.relative_path) $Zip $Item.sha256
    $Extract = Join-Path $ToolRoot ($Component + '-extracted')
    Expand-Archive -LiteralPath $Zip -DestinationPath $Extract -Force
    $Package = @(Get-ChildItem -LiteralPath $Extract -Directory)
    if ($Package.Count -ne 1) { throw "Unexpected package layout: $Component" }
    Get-ChildItem -LiteralPath $Package[0].FullName | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $CudaRoot -Recurse -Force
    }
    Write-Host "Verified and provisioned $Component $($Manifest.$Component.version)"
}
$CmakeVersion = [string]$Lock.cmake
$CmakeName = "cmake-$CmakeVersion-windows-x86_64"
$CmakeBase = "https://github.com/Kitware/CMake/releases/download/v$CmakeVersion/"
$Checksums = Join-Path $ToolRoot "cmake-$CmakeVersion-SHA-256.txt"
Get-Download ($CmakeBase + "cmake-$CmakeVersion-SHA-256.txt") $Checksums
$HashLine = @(Get-Content -LiteralPath $Checksums | Where-Object {
    $_ -match ('  ' + [Regex]::Escape($CmakeName + '.zip') + '$')
})
if ($HashLine.Count -ne 1) { throw 'CMake checksum was not found.' }
$CmakeZip = Join-Path $ToolRoot "$CmakeName.zip"
Get-VerifiedArchive ($CmakeBase + "$CmakeName.zip") $CmakeZip ($HashLine[0].Split(' ')[0])
Expand-Archive -LiteralPath $CmakeZip -DestinationPath $ToolRoot -Force
$NinjaZip = Join-Path $ToolRoot 'ninja-1.13.2.zip'
Get-VerifiedArchive 'https://github.com/ninja-build/ninja/releases/download/v1.13.2/ninja-win.zip' $NinjaZip '07fc8261b42b20e71d1720b39068c2e14ffcee6396b76fb7a795fb460b78dc65'
$NinjaRoot = Join-Path $ToolRoot 'ninja-1.13.2'
Expand-Archive -LiteralPath $NinjaZip -DestinationPath $NinjaRoot -Force

# Process-only activation; leave the machine-wide PATH and NVIDIA driver intact.
$env:CUDA_PATH = $CudaRoot
$env:PATH = "$CudaRoot\bin;$(Join-Path $ToolRoot $CmakeName)\bin;$NinjaRoot;$env:PATH"
Write-Host 'Pinned portable CUDA, CMake and Ninja tools provisioned and activated.'
