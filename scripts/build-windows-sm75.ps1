[CmdletBinding()]
param(
    [string]$BuildDir = "build-windows-sm75",
    [ValidateSet("Release","RelWithDebInfo","Debug")]
    [string]$Config = "Release",
    [string]$VcpkgRoot = "",
    [switch]$SkipDependencies,
    [switch]$Clean
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$BuildPath = Join-Path $RepoRoot $BuildDir

function Require-Command([string]$Name) {
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "Required command '$Name' was not found in PATH." }
    return $cmd.Source
}

function Import-VsDevEnvironment {
    if (Get-Command cl.exe -ErrorAction SilentlyContinue) { return }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        throw "MSVC cl.exe was not found. Install Visual Studio 2022 Build Tools with Desktop development with C++ and the Windows SDK."
    }

    $install = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $install) { throw "Visual Studio 2022 C++ Build Tools were not found." }

    $vsDevCmd = Join-Path $install "Common7\Tools\VsDevCmd.bat"
    if (-not (Test-Path $vsDevCmd)) { throw "VsDevCmd.bat not found: $vsDevCmd" }

    $cmdLine = "`"$vsDevCmd`" -arch=amd64 -host_arch=amd64 >nul && set"
    $envDump = & cmd.exe /s /c $cmdLine
    foreach ($line in $envDump) {
        $idx = $line.IndexOf("=")
        if ($idx -gt 0) {
            [Environment]::SetEnvironmentVariable($line.Substring(0,$idx), $line.Substring($idx+1), "Process")
        }
    }
    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
        throw "MSVC environment initialization failed."
    }
}

Write-Host "== NInfer native Windows / RTX 2080 Ti (SM75) build =="

Require-Command git.exe | Out-Null
Require-Command cmake.exe | Out-Null
Require-Command ninja.exe | Out-Null
Import-VsDevEnvironment
Require-Command cl.exe | Out-Null

if (-not (Get-Command nvcc.exe -ErrorAction SilentlyContinue)) {
    if ($env:CUDA_PATH -and (Test-Path (Join-Path $env:CUDA_PATH "bin\nvcc.exe"))) {
        $env:PATH = (Join-Path $env:CUDA_PATH "bin") + ";" + $env:PATH
    }
}
Require-Command nvcc.exe | Out-Null

if (-not $VcpkgRoot) {
    # Do not implicitly trust VCPKG_ROOT from a Visual Studio developer shell:
    # newer VS images expose an integrated vcpkg tree that may be manifest-only
    # and is not a writable classic-mode checkout.
    $VcpkgRoot = Join-Path $RepoRoot ".deps\vcpkg"
}
if (-not (Test-Path (Join-Path $VcpkgRoot ".git"))) {
    Write-Host "Bootstrapping vcpkg at $VcpkgRoot ..."
    New-Item -ItemType Directory -Force -Path (Split-Path $VcpkgRoot -Parent) | Out-Null
    & git.exe clone --depth 1 https://github.com/microsoft/vcpkg.git $VcpkgRoot
}

$vcpkgExe = Join-Path $VcpkgRoot "vcpkg.exe"
if (-not (Test-Path $vcpkgExe)) {
    & (Join-Path $VcpkgRoot "bootstrap-vcpkg.bat") -disableMetrics
}

if (-not $SkipDependencies) {
    Write-Host "Installing Windows dependencies (ffmpeg, curl, pkgconf) ..."
    & $vcpkgExe install "ffmpeg[avcodec,avformat,swscale]:x64-windows" curl:x64-windows pkgconf:x64-windows
}

$Installed = Join-Path $VcpkgRoot "installed\x64-windows"
$PkgConf = Join-Path $Installed "tools\pkgconf\pkgconf.exe"
if (-not (Test-Path $PkgConf)) {
    throw "pkgconf.exe was not found at $PkgConf. Run once without -SkipDependencies."
}

$env:PKG_CONFIG_PATH = @(
    (Join-Path $Installed "lib\pkgconfig"),
    (Join-Path $Installed "share\pkgconfig")
) -join ";"

if ($Clean -and (Test-Path $BuildPath)) { Remove-Item -Recurse -Force $BuildPath }

$Toolchain = Join-Path $VcpkgRoot "scripts\buildsystems\vcpkg.cmake"

Write-Host "Configuring native SM75 build ..."
$CmakeArgs = @(
    "-S", $RepoRoot,
    "-B", $BuildPath,
    "-G", "Ninja",
    "-DCMAKE_BUILD_TYPE=$Config",
    "-DCMAKE_CUDA_ARCHITECTURES=75",
    "-DCMAKE_TOOLCHAIN_FILE=$Toolchain",
    "-DVCPKG_TARGET_TRIPLET=x64-windows",
    "-DPKG_CONFIG_EXECUTABLE=$PkgConf",
    "-DNINFER_BUILD_APPS=ON",
    "-DBUILD_TESTING=OFF",
    "-DNINFER_BUILD_BENCHMARKS=OFF"
)
& cmake.exe @CmakeArgs
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed with exit code $LASTEXITCODE." }

& cmake.exe --build $BuildPath --parallel
if ($LASTEXITCODE -ne 0) { throw "Build failed with exit code $LASTEXITCODE." }

$Executables = @(Get-ChildItem $BuildPath -Recurse -File | Where-Object { $_.Name -in @("ninfer.exe","ninfer-serve.exe") })
if ($Executables.Count -eq 0) { throw "Build completed but ninfer.exe/ninfer-serve.exe were not found." }

$RuntimeDir = Join-Path $Installed "bin"
if (Test-Path $RuntimeDir) {
    $RuntimeDlls = @(Get-ChildItem $RuntimeDir -Filter *.dll -File)
    foreach ($exe in $Executables) {
        foreach ($dll in $RuntimeDlls) { Copy-Item $dll.FullName $exe.Directory.FullName -Force }
    }
}

Write-Host ""
Write-Host "Build complete:"
$Executables | ForEach-Object { Write-Host "  $($_.FullName)" }
Write-Host ""
Write-Host "Smoke test example:"
Write-Host "  .\build-windows-sm75\apps\ninfer.exe <model.ninfer> --prompt `"Reply with exactly: SM75 OK`" --max-context 8192 --max-new 32 --kv-dtype int8"
