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
if (Test-Path "$ZipPath.sbom.cdx.json") { Remove-Item -Force "$ZipPath.sbom.cdx.json" }
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
Copy-Item (Join-Path $RepoRoot "config\windows-sm75-toolchain.json") (Join-Path $ConfigDir "windows-sm75-toolchain.json") -Force
Copy-Item (Join-Path $RepoRoot "config\windows-sm75-distribution-contract.json") (Join-Path $ConfigDir "windows-sm75-distribution-contract.json") -Force
Copy-Item (Join-Path $RepoRoot "config\windows-sm75-distribution-contract.json") (Join-Path $ConfigDir "windows-sm75-distribution-contract.json") -Force

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

$ToolchainRecordPath = Join-Path $StagePath "BUILD-TOOLCHAIN.json"
if (-not (Test-Path $ToolchainRecordPath -PathType Leaf)) {
    throw "BUILD-TOOLCHAIN.json is missing from the staged runtime. Rebuild with build-windows-sm75.ps1."
}
$ToolchainRecord = Get-Content $ToolchainRecordPath -Raw | ConvertFrom-Json
if ($ToolchainRecord.schema_version -ne 1 -or
    $ToolchainRecord.artifact_type -ne "ninfer_windows_sm75_toolchain" -or
    $ToolchainRecord.profile -ne "qwen3.8-27b-sm75") {
    throw "Unexpected BUILD-TOOLCHAIN.json contract."
}

$ToolchainLockPath = Join-Path $ConfigDir "windows-sm75-toolchain.json"
$ToolchainLock = Get-Content $ToolchainLockPath -Raw | ConvertFrom-Json
$ToolchainLockHash = (Get-FileHash $ToolchainLockPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($ToolchainLock.schema_version -ne 1 -or $ToolchainLock.profile -ne "qwen3.8-27b-sm75") {
    throw "Unexpected Windows SM75 toolchain lock contract."
}
if ([string]$ToolchainRecord.toolchain_lock_sha256 -ne $ToolchainLockHash) {
    throw "BUILD-TOOLCHAIN.json does not match the embedded production toolchain lock."
}

$DistributionContractPath = Join-Path $ConfigDir "windows-sm75-distribution-contract.json"
$DistributionContract = Get-Content $DistributionContractPath -Raw | ConvertFrom-Json
if ($DistributionContract.schema_version -ne 1 -or $DistributionContract.profile -ne "qwen3.8-27b-sm75") {
    throw "Unexpected Windows SM75 distribution contract."
}
$DistributionContractHash = (Get-FileHash $DistributionContractPath -Algorithm SHA256).Hash.ToLowerInvariant()

$cudaVersion = ([string]$ToolchainRecord.cuda_compiler -replace "\.[0-9]+$","")

$vcpkgCommit = $null
$vcpkgRoot = Join-Path $RepoRoot ".deps\vcpkg"
if (Test-Path (Join-Path $vcpkgRoot ".git")) {
    $candidate = (& git.exe -C $vcpkgRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -eq 0 -and $candidate) { $vcpkgCommit = $candidate }
}

if ([string]::IsNullOrWhiteSpace($vcpkgCommit) -or
    $vcpkgCommit -ne [string]$ToolchainRecord.vcpkg_commit -or
    $vcpkgCommit -ne [string]$ToolchainLock.vcpkg_commit) {
    throw "vcpkg checkout does not match the recorded production toolchain."
}

$cmakeVersion = ((& cmake.exe --version | Select-Object -First 1) -replace "^cmake version\s+","").Trim()
if ($LASTEXITCODE -ne 0 -or -not $cmakeVersion) { throw "Unable to resolve CMake version." }

$DistributionContractPath = Join-Path $ConfigDir "windows-sm75-distribution-contract.json"
$DistributionContract = Get-Content $DistributionContractPath -Raw | ConvertFrom-Json
if ($DistributionContract.schema_version -ne 1 -or $DistributionContract.profile -ne "qwen3.8-27b-sm75") {
    throw "Unexpected Windows SM75 distribution contract."
}
$DistributionContractHash = (Get-FileHash $DistributionContractPath -Algorithm SHA256).Hash.ToLowerInvariant()

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
    schema_version = 3
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
    toolchain_lock_sha256 = $ToolchainLockHash
    distribution_contract_sha256 = $DistributionContractHash
    distribution_contract_sha256 = $DistributionContractHash
    cuda_toolkit = $cudaVersion
    cuda_compiler = [string]$ToolchainRecord.cuda_compiler
    vcpkg_commit = [string]$ToolchainRecord.vcpkg_commit
    msvc_toolset = [string]$ToolchainRecord.msvc_toolset
    msvc_compiler = [string]$ToolchainRecord.msvc_compiler
    windows_sdk = [string]$ToolchainRecord.windows_sdk
    cmake = [string]$ToolchainRecord.cmake
    ninja = [string]$ToolchainRecord.ninja
    powershell = $PSVersionTable.PSVersion.ToString()
    windows = [Environment]::OSVersion.VersionString
    created_utc = [DateTime]::UtcNow.ToString("o")
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $StagePath "BUILD-MANIFEST.json") -Encoding UTF8

$SbomScript = Join-Path $RepoRoot "scripts\generate-windows-sm75-sbom.ps1"
if (-not (Test-Path $SbomScript -PathType Leaf)) { throw "SBOM generator not found: $SbomScript" }
$SbomPath = Join-Path $StagePath "SBOM.cdx.json"
& $SbomScript -OutputPath $SbomPath -VcpkgRoot $vcpkgRoot -GitSha $gitSha -CudaVersion ([string]$ToolchainRecord.cuda_compiler)
if (-not (Test-Path $SbomPath -PathType Leaf)) {
    throw "CycloneDX SBOM generator returned without producing the expected output file."
}

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
Copy-Item $SbomPath "$ZipPath.sbom.cdx.json" -Force

Write-Host "Package created:"
Write-Host "  $ZipPath"
Write-Host "  $ZipPath.sha256"
Write-Host "  $ZipPath.sbom.cdx.json"
Write-Host "  Manifest schema: $($manifest.schema_version)"
