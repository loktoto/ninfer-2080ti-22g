[CmdletBinding()]
param(
    [string]$InstallDir = "out\windows-sm75",
    [string]$DistDir = "dist"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Get-PackageRelativePath([string]$BasePath, [string]$FilePath) {
    $BaseFull = [IO.Path]::GetFullPath($BasePath).TrimEnd([char[]]"\/")
    $FileFull = [IO.Path]::GetFullPath($FilePath)
    $Prefix = $BaseFull + [IO.Path]::DirectorySeparatorChar
    if (-not $FileFull.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Package file is outside the staging root: $FilePath"
    }
    return $FileFull.Substring($Prefix.Length).Replace("\","/")
}

$InstallPath = Join-Path $RepoRoot $InstallDir
$DistPath = Join-Path $RepoRoot $DistDir
if (-not (Test-Path $InstallPath)) { throw "Install tree not found: $InstallPath" }

$gitSha = (& git.exe -C $RepoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or -not $gitSha) { throw "Unable to resolve git commit." }
$shortSha = $gitSha.Substring(0,12)
$PackageName = "ninfer-windows-sm75-$shortSha"
$StagePath = Join-Path $DistPath $PackageName
$ZipPath = Join-Path $DistPath "$PackageName.zip"

if (Test-Path $StagePath) { Remove-Item -Recurse -Force $StagePath }
if (Test-Path $ZipPath) { Remove-Item -Force $ZipPath }
if (Test-Path "$ZipPath.sha256") { Remove-Item -Force "$ZipPath.sha256" }
New-Item -ItemType Directory -Force -Path $DistPath | Out-Null
Copy-Item $InstallPath $StagePath -Recurse -Force

$DocsDir = Join-Path $StagePath "docs"
New-Item -ItemType Directory -Force -Path $DocsDir | Out-Null
Copy-Item (Join-Path $RepoRoot "README.md") (Join-Path $StagePath "README.md") -Force
Copy-Item (Join-Path $RepoRoot "LICENSE") (Join-Path $StagePath "LICENSE") -Force
Copy-Item (Join-Path $RepoRoot "docs\windows-sm75.md") (Join-Path $DocsDir "windows-sm75.md") -Force
Copy-Item (Join-Path $RepoRoot "docs\INSTALL-WINDOWS-SM75.md") (Join-Path $DocsDir "INSTALL-WINDOWS-SM75.md") -Force

$ConfigDir = Join-Path $StagePath "config"
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
Copy-Item (Join-Path $RepoRoot "config\windows-sm75-artifacts.json") (Join-Path $ConfigDir "windows-sm75-artifacts.json") -Force
Copy-Item (Join-Path $RepoRoot "config\production-defaults.json") (Join-Path $ConfigDir "production-defaults.json") -Force

$RuntimeScriptsDir = Join-Path $StagePath "scripts"
New-Item -ItemType Directory -Force -Path $RuntimeScriptsDir | Out-Null
@(
    "run-server-windows-sm75.ps1",
    "healthcheck-windows-sm75.ps1",
    "smoke-test-windows-sm75.ps1",
    "acceptance-windows-sm75.ps1",
    "download-qwen38-windows-sm75.ps1",
    "manage-installed-server.ps1",
    "verify-acceptance-evidence.ps1",
    "verify-windows-sm75.ps1"
) | ForEach-Object {
    Copy-Item (Join-Path $RepoRoot "scripts\$_") (Join-Path $RuntimeScriptsDir $_) -Force
}

$InstallerDir = Join-Path $StagePath "install"
New-Item -ItemType Directory -Force -Path $InstallerDir | Out-Null
@(
    "START-HERE.bat",
    "README-FIRST.txt",
    "install-ninfer-sm75.ps1",
    "install-ninfer-sm75.bat",
    "first-run-wizard.ps1",
    "verify-installation.ps1",
    "repair-ninfer-sm75.ps1",
    "uninstall-ninfer-sm75.ps1"
) | ForEach-Object {
    Copy-Item (Join-Path $RepoRoot "install\$_") (Join-Path $InstallerDir $_) -Force
}

$LaunchersDir = Join-Path $StagePath "launchers"
New-Item -ItemType Directory -Force -Path $LaunchersDir | Out-Null
Get-ChildItem (Join-Path $RepoRoot "launchers") -Filter *.bat -File | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $LaunchersDir $_.Name) -Force
}

Copy-Item (Join-Path $RepoRoot "install\START-HERE.bat") (Join-Path $StagePath "START-HERE.bat") -Force
Copy-Item (Join-Path $RepoRoot "install\README-FIRST.txt") (Join-Path $StagePath "README-FIRST.txt") -Force

$cudaVersion = $null
$nvcc = Get-Command nvcc.exe -ErrorAction SilentlyContinue
if ($nvcc) {
    $versionOutput = (& $nvcc.Source --version | Out-String)
    if ($LASTEXITCODE -eq 0 -and $versionOutput -match "release\s+([0-9]+\.[0-9]+)") {
        $cudaVersion = $Matches[1]
    }
}

$vcpkgCommit = $null
$vcpkgRoot = Join-Path $RepoRoot ".deps\vcpkg"
if (Test-Path (Join-Path $vcpkgRoot ".git")) {
    $candidate = (& git.exe -C $vcpkgRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -eq 0 -and $candidate) { $vcpkgCommit = $candidate }
}

$cmakeVersion = ((& cmake.exe --version | Select-Object -First 1) -replace "^cmake version\s+","").Trim()
if ($LASTEXITCODE -ne 0 -or -not $cmakeVersion) { throw "Unable to resolve CMake version." }

$ArtifactLockPath = Join-Path $RepoRoot "config\windows-sm75-artifacts.json"
if (-not (Test-Path $ArtifactLockPath -PathType Leaf)) {
    throw "Artifact lock file not found: $ArtifactLockPath"
}
$ArtifactLock = Get-Content $ArtifactLockPath -Raw | ConvertFrom-Json
$ArtifactLockHash = (Get-FileHash $ArtifactLockPath -Algorithm SHA256).Hash.ToLowerInvariant()
$ArtifactChannel = [string]$ArtifactLock.channel
if ([string]::IsNullOrWhiteSpace($ArtifactChannel)) {
    throw "Artifact lock channel is missing."
}

$vcRedistVersion = $null
foreach ($RegistryPath in @(
    "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64",
    "HKLM:\SOFTWARE\Wow6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64"
)) {
    if (-not (Test-Path $RegistryPath)) { continue }
    $Runtime = Get-ItemProperty $RegistryPath -ErrorAction SilentlyContinue
    if ($Runtime -and [int]$Runtime.Installed -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$Runtime.Version)) {
        $vcRedistVersion = ([string]$Runtime.Version).TrimStart([char[]]"vV")
        break
    }
}
if ([string]::IsNullOrWhiteSpace($vcRedistVersion)) {
    throw "Unable to resolve installed Microsoft Visual C++ x64 Redistributable version."
}
try { $vcRedistVersionObject = [Version]$vcRedistVersion }
catch { throw "Installed Microsoft Visual C++ x64 Redistributable version is invalid: $vcRedistVersion" }
$vcRedistFloor = [Version]"14.44.35211.0"
if ($vcRedistVersionObject -lt $vcRedistFloor) {
    $vcRedistVersion = $vcRedistFloor.ToString()
}

$manifest = [ordered]@{
    artifact_type = "ninfer-windows-sm75-runtime"
    schema_version = 2
    git_sha = $gitSha
    cuda_arch = "sm_75"
    target_gpu = "NVIDIA RTX 2080 Ti / Turing TU102"
    configuration = "Release"
    build_profile = "qwen3.8-27b-sm75"
    cuda_runtime_linkage = "static"
    minimum_nvidia_driver_branch = 580
    minimum_vc_redist_version = $vcRedistVersion
    installer_schema = 1
    artifact_channel = $ArtifactChannel
    artifact_lock_sha256 = $ArtifactLockHash
    cuda_toolkit = $cudaVersion
    vcpkg_commit = $vcpkgCommit
    msvc_toolset = $env:VCToolsVersion
    cmake = $cmakeVersion
    powershell = $PSVersionTable.PSVersion.ToString()
    windows = [Environment]::OSVersion.VersionString
    created_utc = [DateTime]::UtcNow.ToString("o")
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $StagePath "BUILD-MANIFEST.json") -Encoding UTF8

$checksumPath = Join-Path $StagePath "SHA256SUMS.txt"
$entries = Get-ChildItem $StagePath -Recurse -File |
    Where-Object { $_.FullName -ne $checksumPath } |
    Sort-Object FullName |
    ForEach-Object {
        $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $relative = Get-PackageRelativePath $StagePath $_.FullName
        "$hash  $relative"
    }
$entries | Set-Content $checksumPath -Encoding ASCII

Compress-Archive -Path $StagePath -DestinationPath $ZipPath -CompressionLevel Optimal
$zipHash = (Get-FileHash $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content "$ZipPath.sha256" "$zipHash  $([IO.Path]::GetFileName($ZipPath))" -Encoding ASCII

Write-Host "Package created:"
Write-Host "  $ZipPath"
Write-Host "  $ZipPath.sha256"
Write-Host "  Manifest schema: $($manifest.schema_version)"
