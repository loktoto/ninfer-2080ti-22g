[CmdletBinding()]
param(
    [string]$BuildDir = "build-windows-sm75",
    [string]$InstallDir = "out\windows-sm75",
    [ValidateSet("Release","RelWithDebInfo","Debug")]
    [string]$Config = "Release",
    [string]$VcpkgRoot = "",
    [string]$VcpkgCommit = "b3ae22aef2b857af6e80d756c13f15db12be4e8a",
    [ValidateRange(1,16)]
    [int]$BuildJobs = 2,
    [switch]$SkipDependencies,
    [switch]$Clean
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$BuildPath = Join-Path $RepoRoot $BuildDir
$InstallPath = Join-Path $RepoRoot $InstallDir

function Require-Command([string]$Name) {
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "Required command '$Name' was not found in PATH." }
    return $cmd.Source
}

function Invoke-Checked([scriptblock]$Command, [string]$Description) {
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE."
    }
}

function Import-Vs2022Environment {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        throw "vswhere.exe was not found. Install Visual Studio 2022 Build Tools."
    }

    $install = & $vswhere -latest -version "[17.0,18.0)" -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $install) {
        throw "Visual Studio 2022 C++ Build Tools were not found. Install Desktop development with C++ and a Windows SDK."
    }

    $vsDevCmd = Join-Path $install "Common7\Tools\VsDevCmd.bat"
    if (-not (Test-Path $vsDevCmd)) { throw "VsDevCmd.bat not found: $vsDevCmd" }

    $cmdLine = "`"$vsDevCmd`" -arch=amd64 -host_arch=amd64 >nul && set"
    $envDump = & cmd.exe /s /c $cmdLine
    if ($LASTEXITCODE -ne 0) { throw "Failed to initialize the Visual Studio 2022 developer environment." }

    foreach ($line in $envDump) {
        $idx = $line.IndexOf("=")
        if ($idx -gt 0) {
            [Environment]::SetEnvironmentVariable(
                $line.Substring(0,$idx),
                $line.Substring($idx+1),
                "Process"
            )
        }
    }

    Require-Command cl.exe | Out-Null
}

Write-Host "== NInfer native Windows / RTX 2080 Ti (SM75) production build =="

Require-Command git.exe | Out-Null
Require-Command cmake.exe | Out-Null
Require-Command ninja.exe | Out-Null
Import-Vs2022Environment

if (-not (Get-Command nvcc.exe -ErrorAction SilentlyContinue)) {
    if ($env:CUDA_PATH) {
        $candidate = Join-Path $env:CUDA_PATH "bin\nvcc.exe"
        if (Test-Path $candidate) {
            $env:PATH = (Split-Path $candidate -Parent) + ";" + $env:PATH
        }
    }
}
Require-Command nvcc.exe | Out-Null

$ToolchainAssert = Join-Path $PSScriptRoot "assert-windows-sm75-toolchain.ps1"
if (-not (Test-Path $ToolchainAssert -PathType Leaf)) {
    throw "Toolchain assertion script not found: $ToolchainAssert"
}
& $ToolchainAssert -VcpkgCommit $VcpkgCommit

$NvccVersionText = (& nvcc.exe --version | Out-String)
if ($LASTEXITCODE -ne 0 -or $NvccVersionText -notmatch "release\s+13\.1") {
    throw ("Windows SM75 production build requires CUDA Toolkit 13.1; nvcc reports:" + [Environment]::NewLine + $NvccVersionText)
}

if (-not $VcpkgRoot) {
    $VcpkgRoot = Join-Path $RepoRoot ".deps\vcpkg"
}

if (-not (Test-Path (Join-Path $VcpkgRoot ".git"))) {
    Write-Host "Cloning vcpkg into $VcpkgRoot ..."
    New-Item -ItemType Directory -Force -Path (Split-Path $VcpkgRoot -Parent) | Out-Null
    Invoke-Checked { git.exe clone --filter=blob:none https://github.com/microsoft/vcpkg.git $VcpkgRoot } "vcpkg clone"
}

Write-Host "Pinning vcpkg to $VcpkgCommit ..."
Invoke-Checked { git.exe -C $VcpkgRoot fetch --depth 1 origin $VcpkgCommit } "vcpkg fetch"
Invoke-Checked { git.exe -C $VcpkgRoot checkout --detach $VcpkgCommit } "vcpkg checkout"

$vcpkgExe = Join-Path $VcpkgRoot "vcpkg.exe"
if (-not (Test-Path $vcpkgExe)) {
    Invoke-Checked { & (Join-Path $VcpkgRoot "bootstrap-vcpkg.bat") -disableMetrics } "vcpkg bootstrap"
}

if (-not $SkipDependencies) {
    Write-Host "Installing pinned Windows dependencies ..."
    Invoke-Checked {
        & $vcpkgExe install "ffmpeg[core,avcodec,avformat,swscale]:x64-windows" curl:x64-windows
    } "vcpkg dependency installation"
}

$Installed = Join-Path $VcpkgRoot "installed\x64-windows"
if (-not (Test-Path $Installed)) {
    throw "vcpkg x64-windows installation tree was not found at $Installed."
}

if ($Clean) {
    if (Test-Path $BuildPath) { Remove-Item -Recurse -Force $BuildPath }
    if (Test-Path $InstallPath) { Remove-Item -Recurse -Force $InstallPath }
}

$Toolchain = Join-Path $VcpkgRoot "scripts\buildsystems\vcpkg.cmake"
$CmakeArgs = @(
    "-S", $RepoRoot,
    "-B", $BuildPath,
    "-G", "Ninja",
    "-DCMAKE_BUILD_TYPE=$Config",
    "-DCMAKE_CUDA_ARCHITECTURES=75",
    "-DCMAKE_TOOLCHAIN_FILE=$Toolchain",
    "-DVCPKG_TARGET_TRIPLET=x64-windows",
    "-DNINFER_BUILD_APPS=ON",
    "-DNINFER_QWEN38_ONLY=ON",
    "-DBUILD_TESTING=OFF",
    "-DNINFER_BUILD_BENCHMARKS=OFF"
)

Write-Host "Configuring native SM75 build ..."
Invoke-Checked { cmake.exe @CmakeArgs } "CMake configure"

Write-Host "Compiling Qwen3.8-only SM75 profile with $BuildJobs parallel job(s) ..."
Invoke-Checked { cmake.exe --build $BuildPath --parallel $BuildJobs } "CMake build"

Write-Host "Installing staged runtime ..."
New-Item -ItemType Directory -Force -Path $InstallPath | Out-Null
Invoke-Checked { cmake.exe --install $BuildPath --prefix $InstallPath --config $Config } "CMake install"

& $ToolchainAssert -VcpkgCommit $VcpkgCommit -OutputPath (Join-Path $InstallPath "BUILD-TOOLCHAIN.json")

$BinDir = Join-Path $InstallPath "bin"
$Expected = @("ninfer.exe","ninfer-serve.exe")
foreach ($name in $Expected) {
    if (-not (Test-Path (Join-Path $BinDir $name))) {
        throw "Expected installed executable was not found: $(Join-Path $BinDir $name)"
    }
}

$RuntimeDir = Join-Path $Installed "bin"
if (Test-Path $RuntimeDir) {
    Get-ChildItem $RuntimeDir -Filter *.dll -File | ForEach-Object {
        Copy-Item $_.FullName $BinDir -Force
    }
}

Write-Host ""
Write-Host "Production staging complete:"
Write-Host "  $InstallPath"
Write-Host ""
Write-Host "Next:"
Write-Host "  .\scripts\verify-windows-sm75.ps1 -InstallDir `"$InstallDir`""
Write-Host "  .\scripts\package-windows-sm75.ps1 -InstallDir `"$InstallDir`""
