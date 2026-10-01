[CmdletBinding()]
param(
    [switch]$NoBuild,
    [ValidateRange(1,16)]
    [int]$BuildJobs = 2
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Winget = Get-Command winget.exe -ErrorAction SilentlyContinue
if (-not $Winget) {
    throw "winget.exe is required for the developer bootstrap. Install/update Microsoft App Installer first."
}

function Invoke-Winget([string[]]$Arguments,[string]$Label) {
    Write-Host ""
    Write-Host "== $Label =="
    & $Winget.Source @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Label failed with winget exit code $LASTEXITCODE." }
}

function Refresh-ProcessEnvironment {
    $MachinePath = [Environment]::GetEnvironmentVariable("Path","Machine")
    $UserPath = [Environment]::GetEnvironmentVariable("Path","User")
    $env:Path = "$MachinePath;$UserPath"
    foreach ($Name in @("CUDA_PATH","CUDA_PATH_V13_1")) {
        $Value = [Environment]::GetEnvironmentVariable($Name,"Machine")
        if (-not $Value) { $Value = [Environment]::GetEnvironmentVariable($Name,"User") }
        if ($Value) { [Environment]::SetEnvironmentVariable($Name,$Value,"Process") }
    }
}

$Common = @("--exact","--accept-package-agreements","--accept-source-agreements")

if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
    Invoke-Winget (@("install","--id","Git.Git","--silent") + $Common) "Git for Windows"
}
if (-not (Get-Command cmake.exe -ErrorAction SilentlyContinue)) {
    Invoke-Winget (@("install","--id","Kitware.CMake","--silent") + $Common) "CMake"
}
if (-not (Get-Command ninja.exe -ErrorAction SilentlyContinue)) {
    Invoke-Winget (@("install","--id","Ninja-build.Ninja","--silent") + $Common) "Ninja"
}

$ProgramFilesX86 = [Environment]::GetFolderPath("ProgramFilesX86")
$VsWhere = Join-Path $ProgramFilesX86 "Microsoft Visual Studio\Installer\vswhere.exe"
$HasVctools = $false
if (Test-Path $VsWhere -PathType Leaf) {
    $Install = & $VsWhere -latest -version "[17.0,18.0)" -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    $HasVctools = -not [string]::IsNullOrWhiteSpace(($Install | Out-String))
}
if (-not $HasVctools) {
    $VsOverride = "--wait --passive --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
    Invoke-Winget (@("install","--id","Microsoft.VisualStudio.2022.BuildTools","--override",$VsOverride) + $Common) "Visual Studio 2022 C++ Build Tools"
}

$Nvcc = Get-Command nvcc.exe -ErrorAction SilentlyContinue
$CudaOk = $false
if ($Nvcc) {
    $NvccText = (& $Nvcc.Source --version | Out-String)
    $CudaOk = $NvccText -match "release\s+13\.1"
}
if (-not $CudaOk) {
    Invoke-Winget (@("install","--id","Nvidia.CUDA","--version","13.1","--silent") + $Common) "NVIDIA CUDA Toolkit 13.1"
}

$VcRuntime = Join-Path $env:WINDIR "System32\vcruntime140.dll"
if (-not (Test-Path $VcRuntime -PathType Leaf)) {
    Invoke-Winget (@("install","--id","Microsoft.VCRedist.2015+.x64","--silent") + $Common) "Microsoft VC++ 2015-2022 x64 runtime"
}

Refresh-ProcessEnvironment

Write-Host ""
Write-Host "== Developer toolchain validation =="
foreach ($Command in @("git.exe","cmake.exe","ninja.exe","nvcc.exe")) {
    $Resolved = Get-Command $Command -ErrorAction SilentlyContinue
    if (-not $Resolved) { throw "$Command is still unavailable after bootstrap." }
    Write-Host "  $Command -> $($Resolved.Source)"
}

$NvccText = (& nvcc.exe --version | Out-String)
if ($NvccText -notmatch "release\s+13\.1") {
    throw ("CUDA 13.1 was requested, but nvcc reports:" + [Environment]::NewLine + $NvccText)
}
Write-Host $NvccText.Trim()

if (-not $NoBuild) {
    Write-Host ""
    Write-Host "== Clean Qwen3.8 / SM75 production build =="
    & (Join-Path $Root "scripts\build-windows-sm75.ps1") -Clean -BuildJobs $BuildJobs
    & (Join-Path $Root "scripts\verify-windows-sm75.ps1")
    & (Join-Path $Root "scripts\package-windows-sm75.ps1")
    & (Join-Path $Root "scripts\verify-package-windows-sm75.ps1")
}

Write-Host ""
Write-Host "Developer bootstrap completed."
