[CmdletBinding()]
param(
    [string]$OutputPath = "",
    [string]$VcpkgCommit = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$LockPath = Join-Path $RepoRoot "config\windows-sm75-toolchain.json"
if (-not (Test-Path $LockPath -PathType Leaf)) {
    throw "Production toolchain lock not found: $LockPath"
}
$Expected = Get-Content $LockPath -Raw | ConvertFrom-Json
if ($Expected.schema_version -ne 1 -or $Expected.profile -ne "qwen3.8-27b-sm75") {
    throw "Unexpected Windows SM75 toolchain lock contract."
}
$LockSha256 = (Get-FileHash $LockPath -Algorithm SHA256).Hash.ToLowerInvariant()

if (-not [string]::IsNullOrWhiteSpace($VcpkgCommit) -and
    $VcpkgCommit -ne [string]$Expected.vcpkg_commit) {
    throw "vcpkg drift: expected $($Expected.vcpkg_commit), got '$VcpkgCommit'."
}

function Require-Command([string]$Name) {
    $Command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $Command) { throw "Required tool '$Name' was not found in PATH." }
    return $Command.Source
}

$Cl = Require-Command "cl.exe"
$Nvcc = Require-Command "nvcc.exe"
$CMake = Require-Command "cmake.exe"
$Ninja = Require-Command "ninja.exe"

$VcTools = ([string]$env:VCToolsVersion).Trim().TrimEnd("\")
if ($VcTools -ne [string]$Expected.msvc_toolset) {
    throw "MSVC toolset drift: expected $($Expected.msvc_toolset), got '$VcTools'."
}

$Sdk = ([string]$env:WindowsSDKVersion).Trim().TrimEnd("\")
if ($Sdk -ne [string]$Expected.windows_sdk) {
    throw "Windows SDK drift: expected $($Expected.windows_sdk), got '$Sdk'."
}

$ClText = (& $Cl 2>&1 | Out-String)
if ($ClText -notmatch "Compiler Version\s+([0-9.]+)") {
    throw "Unable to parse cl.exe compiler version."
}
$ClVersion = $Matches[1]
if ($ClVersion -ne [string]$Expected.msvc_compiler) {
    throw "cl.exe drift: expected $($Expected.msvc_compiler), got '$ClVersion'."
}

$NvccText = (& $Nvcc --version | Out-String)
if ($LASTEXITCODE -ne 0 -or $NvccText -notmatch "V([0-9]+\.[0-9]+\.[0-9]+)") {
    throw "Unable to parse nvcc compiler build."
}
$CudaCompiler = $Matches[1]
if ($CudaCompiler -ne [string]$Expected.cuda_compiler) {
    throw "CUDA compiler drift: expected $($Expected.cuda_compiler), got '$CudaCompiler'."
}

$CMakeLine = (& $CMake --version | Select-Object -First 1)
if ($LASTEXITCODE -ne 0 -or $CMakeLine -notmatch "^cmake version\s+([0-9.]+)") {
    throw "Unable to parse CMake version."
}
$CMakeVersion = $Matches[1]
if ($CMakeVersion -ne [string]$Expected.cmake) {
    throw "CMake drift: expected $($Expected.cmake), got '$CMakeVersion'."
}

$NinjaVersion = (& $Ninja --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $NinjaVersion -ne [string]$Expected.ninja) {
    throw "Ninja drift: expected $($Expected.ninja), got '$NinjaVersion'."
}

$ResolvedVcpkgCommit = if (-not [string]::IsNullOrWhiteSpace($VcpkgCommit)) {
    $VcpkgCommit
} else {
    [string]$Expected.vcpkg_commit
}

$Record = [ordered]@{
    schema_version = 1
    artifact_type = "ninfer_windows_sm75_toolchain"
    profile = [string]$Expected.profile
    toolchain_lock_sha256 = $LockSha256
    msvc_toolset = $VcTools
    msvc_compiler = $ClVersion
    windows_sdk = $Sdk
    cuda_compiler = $CudaCompiler
    cmake = $CMakeVersion
    ninja = $NinjaVersion
    vcpkg_commit = $ResolvedVcpkgCommit
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $Parent = Split-Path $OutputPath -Parent
    if ($Parent) { New-Item -ItemType Directory -Force -Path $Parent | Out-Null }
    $Record | ConvertTo-Json -Depth 4 | Set-Content $OutputPath -Encoding UTF8
}

Write-Host "Windows SM75 production toolchain verified."
Write-Host "  MSVC toolset: $VcTools"
Write-Host "  cl.exe:       $ClVersion"
Write-Host "  Windows SDK:  $Sdk"
Write-Host "  CUDA nvcc:    $CudaCompiler"
Write-Host "  CMake:        $CMakeVersion"
Write-Host "  Ninja:        $NinjaVersion"
Write-Host "  vcpkg:        $ResolvedVcpkgCommit"
Write-Host "  Lock SHA-256: $LockSha256"
