[CmdletBinding()]
param(
    [string]$DistDir = "dist"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$DistPath = Join-Path $RepoRoot $DistDir
if (-not (Test-Path $DistPath)) { throw "Distribution directory not found: $DistPath" }

$Zip = Get-ChildItem $DistPath -Filter "ninfer-windows-sm75-*.zip" -File |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
if (-not $Zip) { throw "No Windows SM75 ZIP found in $DistPath." }

$OuterChecksum = "$($Zip.FullName).sha256"
if (-not (Test-Path $OuterChecksum)) { throw "Missing ZIP checksum: $OuterChecksum" }
$ExpectedOuter = ((Get-Content $OuterChecksum -Raw).Trim() -split "\s+")[0].ToLowerInvariant()
$ActualOuter = (Get-FileHash $Zip.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
if ($ActualOuter -ne $ExpectedOuter) {
    throw "ZIP SHA-256 mismatch. Expected $ExpectedOuter, got $ActualOuter."
}

$ExternalSbom = "$($Zip.FullName).sbom.cdx.json"
if (-not (Test-Path $ExternalSbom -PathType Leaf)) {
    throw "Missing external CycloneDX SBOM: $ExternalSbom"
}

$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("ninfer-sm75-verify-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null
try {
    Expand-Archive -Path $Zip.FullName -DestinationPath $TempRoot -Force
    $TopEntries = @(Get-ChildItem $TempRoot -Force)
    if ($TopEntries.Count -ne 1 -or -not $TopEntries[0].PSIsContainer) {
        throw "ZIP must contain exactly one top-level package directory."
    }
    $Stage = $TopEntries[0]

    $ManifestPath = Join-Path $Stage.FullName "BUILD-MANIFEST.json"
    $SumsPath = Join-Path $Stage.FullName "SHA256SUMS.txt"
    if (-not (Test-Path $ManifestPath)) { throw "BUILD-MANIFEST.json missing from package." }
    if (-not (Test-Path $SumsPath)) { throw "SHA256SUMS.txt missing from package." }

    $Manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
    if ($Manifest.schema_version -ne 3) { throw "Unsupported manifest schema: $($Manifest.schema_version)" }
    if ($Manifest.cuda_arch -ne "sm_75") { throw "Unexpected CUDA architecture: $($Manifest.cuda_arch)" }
    if ($Manifest.artifact_type -ne "ninfer-windows-sm75-runtime") { throw "Unexpected artifact type." }
    if ($Manifest.build_profile -ne "qwen3.8-27b-sm75") { throw "Unexpected build profile: $($Manifest.build_profile)" }
    if ($Manifest.cuda_runtime_linkage -ne "static") { throw "Windows production package must use static CUDA runtime linkage." }
    if ([int]$Manifest.minimum_nvidia_driver_branch -lt 580) { throw "Manifest NVIDIA driver floor is below R580." }
    try {
        $RequiredVc = [Version](([string]$Manifest.minimum_vc_redist_version).TrimStart([char[]]"vV"))
    } catch {
        throw "Manifest minimum_vc_redist_version is missing or invalid."
    }
    if ($RequiredVc.Major -lt 14) { throw "Manifest VC++ runtime floor is invalid: $RequiredVc" }
    if ($Manifest.installer_schema -ne 1) { throw "Unexpected installer schema: $($Manifest.installer_schema)" }
    if ([string]::IsNullOrWhiteSpace([string]$Manifest.artifact_channel)) {
        throw "Build manifest is missing artifact_channel."
    }
    if ([string]::IsNullOrWhiteSpace([string]$Manifest.artifact_lock_sha256)) {
        throw "Build manifest is missing artifact_lock_sha256."
    }

    if ([string]::IsNullOrWhiteSpace([string]$Manifest.toolchain_lock_sha256)) {
        throw "Build manifest is missing toolchain_lock_sha256."
    }
    if ([string]::IsNullOrWhiteSpace([string]$Manifest.distribution_contract_sha256)) {
        throw "Build manifest is missing distribution_contract_sha256."
    }

    $DistributionContractPath = Join-Path $Stage.FullName "config\windows-sm75-distribution-contract.json"
    if (-not (Test-Path $DistributionContractPath -PathType Leaf)) {
        throw "Embedded distribution contract is missing."
    }
    $DistributionContract = Get-Content $DistributionContractPath -Raw | ConvertFrom-Json
    if ($DistributionContract.schema_version -ne 1 -or $DistributionContract.profile -ne "qwen3.8-27b-sm75") {
        throw "Embedded distribution contract is invalid."
    }
    $EmbeddedDistributionHash = (Get-FileHash $DistributionContractPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($EmbeddedDistributionHash -ne ([string]$Manifest.distribution_contract_sha256).ToLowerInvariant()) {
        throw "Embedded distribution contract hash does not match BUILD-MANIFEST.json."
    }
    $SourceDistributionPath = Join-Path $RepoRoot "config\windows-sm75-distribution-contract.json"
    if (-not (Test-Path $SourceDistributionPath -PathType Leaf)) {
        throw "Source distribution contract is missing."
    }
    $SourceDistributionHash = (Get-FileHash $SourceDistributionPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($SourceDistributionHash -ne $EmbeddedDistributionHash) {
        throw "Packaged distribution contract does not match checked-out source."
    }

    $EmbeddedToolchainLockPath = Join-Path $Stage.FullName "config\windows-sm75-toolchain.json"
    if (-not (Test-Path $EmbeddedToolchainLockPath -PathType Leaf)) {
        throw "Embedded production toolchain lock is missing."
    }
    $ToolchainLock = Get-Content $EmbeddedToolchainLockPath -Raw | ConvertFrom-Json
    if ($ToolchainLock.schema_version -ne 1 -or $ToolchainLock.profile -ne "qwen3.8-27b-sm75") {
        throw "Embedded production toolchain lock contract is invalid."
    }
    $EmbeddedToolchainLockHash = (Get-FileHash $EmbeddedToolchainLockPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($EmbeddedToolchainLockHash -ne ([string]$Manifest.toolchain_lock_sha256).ToLowerInvariant()) {
        throw "Embedded toolchain lock hash does not match BUILD-MANIFEST.json."
    }

    $SourceToolchainLockPath = Join-Path $RepoRoot "config\windows-sm75-toolchain.json"
    if (-not (Test-Path $SourceToolchainLockPath -PathType Leaf)) {
        throw "Source production toolchain lock is missing."
    }
    $SourceToolchainLockHash = (Get-FileHash $SourceToolchainLockPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($SourceToolchainLockHash -ne $EmbeddedToolchainLockHash) {
        throw "Packaged toolchain lock does not match the checked-out release source."
    }

    $ToolchainRecordPath = Join-Path $Stage.FullName "BUILD-TOOLCHAIN.json"
    if (-not (Test-Path $ToolchainRecordPath -PathType Leaf)) {
        throw "BUILD-TOOLCHAIN.json missing from package."
    }
    $ToolchainRecord = Get-Content $ToolchainRecordPath -Raw | ConvertFrom-Json
    if ($ToolchainRecord.schema_version -ne 1 -or
        $ToolchainRecord.artifact_type -ne "ninfer_windows_sm75_toolchain" -or
        $ToolchainRecord.profile -ne "qwen3.8-27b-sm75") {
        throw "Unexpected BUILD-TOOLCHAIN.json contract."
    }
    if ([string]$ToolchainRecord.toolchain_lock_sha256 -ne $EmbeddedToolchainLockHash) {
        throw "BUILD-TOOLCHAIN.json does not match the production toolchain lock."
    }

    foreach ($Name in @("msvc_toolset","msvc_compiler","windows_sdk","cuda_compiler","cmake","ninja","vcpkg_commit")) {
        $ExpectedValue = [string]$ToolchainLock.$Name
        if ([string]$ToolchainRecord.$Name -ne $ExpectedValue) {
            throw "BUILD-TOOLCHAIN.json drift for $Name."
        }
        if ([string]$Manifest.$Name -ne $ExpectedValue) {
            throw "BUILD-MANIFEST.json drift for $Name."
        }
    }
    $ExpectedCudaToolkit = ([string]$ToolchainLock.cuda_compiler -replace "\.[0-9]+$","")
    if ([string]$Manifest.cuda_toolkit -ne $ExpectedCudaToolkit) {
        throw "BUILD-MANIFEST.json CUDA toolkit version does not match the production toolchain lock."
    }

    $SbomPath = Join-Path $Stage.FullName "SBOM.cdx.json"
    if (-not (Test-Path $SbomPath -PathType Leaf)) { throw "SBOM.cdx.json missing from package." }
    $Sbom = Get-Content $SbomPath -Raw | ConvertFrom-Json
    if ($Sbom.bomFormat -ne "CycloneDX" -or $Sbom.specVersion -ne "1.5") {
        throw "Unexpected SBOM format/version."
    }
    if ($Sbom.metadata.component.name -ne "ninfer-windows-sm75") {
        throw "Unexpected SBOM root component: $($Sbom.metadata.component.name)"
    }
    if ([string]$Sbom.metadata.component.version -ne [string]$Manifest.git_sha) {
        throw "SBOM root version does not match BUILD-MANIFEST git_sha."
    }
    $CudaComponents = @($Sbom.components | Where-Object { $_.name -eq "NVIDIA CUDA Runtime" })
    if ($CudaComponents.Count -ne 1) { throw "SBOM must contain exactly one NVIDIA CUDA Runtime component." }
    $StaticLink = @($CudaComponents[0].properties | Where-Object {
        $_.name -eq "ninfer:linkage" -and $_.value -eq "static"
    })
    if ($StaticLink.Count -ne 1) { throw "SBOM does not record static CUDA runtime linkage." }
    $InternalSbomHash = (Get-FileHash $SbomPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $ExternalSbomHash = (Get-FileHash $ExternalSbom -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($InternalSbomHash -ne $ExternalSbomHash) {
        throw "External SBOM does not match the SBOM embedded in the release ZIP."
    }

    $LockPath = Join-Path $Stage.FullName "config\windows-sm75-artifacts.json"
    if (-not (Test-Path $LockPath -PathType Leaf)) {
        throw "Pinned artifact lock is missing from the package."
    }
    $ActualLockHash = (Get-FileHash $LockPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ActualLockHash -ne ([string]$Manifest.artifact_lock_sha256).ToLowerInvariant()) {
        throw "Pinned artifact lock hash does not match BUILD-MANIFEST.json."
    }

    $Listed = @{}
    foreach ($Line in Get-Content $SumsPath) {
        if ([string]::IsNullOrWhiteSpace($Line)) { continue }
        if ($Line -notmatch "^([0-9a-fA-F]{64})\s{2}(.+)$") { throw "Malformed checksum line: $Line" }
        $Expected = $Matches[1].ToLowerInvariant()
        $RelativeUnix = $Matches[2].Replace("\","/")
        if ([IO.Path]::IsPathRooted($RelativeUnix) -or $RelativeUnix -match "(^|/)\.\.(/|$)") {
            throw "Unsafe checksum path: $RelativeUnix"
        }
        $Key = $RelativeUnix.ToLowerInvariant()
        if ($Listed.ContainsKey($Key)) { throw "Duplicate checksum path: $RelativeUnix" }
        $Listed[$Key] = $true

        $Relative = $RelativeUnix.Replace("/", [IO.Path]::DirectorySeparatorChar)
        $FilePath = Join-Path $Stage.FullName $Relative
        $FullFile = [IO.Path]::GetFullPath($FilePath)
        $StagePrefix = [IO.Path]::GetFullPath($Stage.FullName).TrimEnd("\") + "\"
        if (-not $FullFile.StartsWith($StagePrefix,[StringComparison]::OrdinalIgnoreCase)) {
            throw "Checksum path escaped package root: $RelativeUnix"
        }
        if (-not (Test-Path $FullFile -PathType Leaf)) { throw "Checksummed file is missing: $RelativeUnix" }
        $Actual = (Get-FileHash $FullFile -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($Actual -ne $Expected) { throw "SHA-256 mismatch for $RelativeUnix." }
    }

    $StagePrefix = [IO.Path]::GetFullPath($Stage.FullName).TrimEnd("\") + "\"
    $ActualFiles = @(Get-ChildItem $Stage.FullName -Recurse -File | Where-Object {
        $_.FullName -ne $SumsPath
    } | ForEach-Object {
        $_.FullName.Substring($StagePrefix.Length).Replace("\","/").ToLowerInvariant()
    })
    foreach ($Relative in $ActualFiles) {
        if (-not $Listed.ContainsKey($Relative)) { throw "Package file is not covered by SHA256SUMS.txt: $Relative" }
    }
    if ($Listed.Count -ne $ActualFiles.Count) {
        throw "SHA256SUMS.txt coverage count mismatch: listed=$($Listed.Count), actual=$($ActualFiles.Count)."
    }

    $DefaultsPath = Join-Path $Stage.FullName "config\production-defaults.json"
    $Defaults = Get-Content $DefaultsPath -Raw | ConvertFrom-Json
    if ($Defaults.schema_version -ne 1 -or $Defaults.profile -ne "qwen3.8-27b-sm75") {
        throw "Production defaults contract is invalid."
    }
    if ([int]$Defaults.runtime_requirements.minimum_nvidia_driver_branch -lt 580) {
        throw "Production defaults driver floor is below R580."
    }
    if ($Defaults.runtime_requirements.cuda_toolkit_required_for_runtime -ne $false) {
        throw "Runtime defaults unexpectedly require a CUDA Toolkit."
    }

    $RequiredSeen = @{}
    foreach ($RequiredUnix in @($DistributionContract.required_package_files)) {
        $RequiredUnix = ([string]$RequiredUnix).Replace("\","/")
        if ([IO.Path]::IsPathRooted($RequiredUnix) -or $RequiredUnix -match "(^|/)\.\.(/|$)") {
            throw "Unsafe required-package path in distribution contract: $RequiredUnix"
        }
        $RequiredKey = $RequiredUnix.ToLowerInvariant()
        if ($RequiredSeen.ContainsKey($RequiredKey)) {
            throw "Duplicate required-package path in distribution contract: $RequiredUnix"
        }
        $RequiredSeen[$RequiredKey] = $true
        $RequiredPath = Join-Path $Stage.FullName ($RequiredUnix.Replace("/",[IO.Path]::DirectorySeparatorChar))
        if (-not (Test-Path $RequiredPath -PathType Leaf)) {
            throw "Required production package file is missing: $RequiredUnix"
        }
    }

    Write-Host "Running packaged end-user verifier in package-only mode..."
    & (Join-Path $Stage.FullName "install\verify-installation.ps1") -PackageOnly

    $RuntimeVerifier = Join-Path $Stage.FullName "scripts\verify-windows-sm75.ps1"
    & $RuntimeVerifier -RequireDependencyAudit
    if ($LASTEXITCODE -ne 0) {
        throw "Extracted runtime dependency/startup verification failed with exit code $LASTEXITCODE."
    }

    Write-Host "Release package integrity verification passed."
    Write-Host "  ZIP:      $($Zip.Name)"
    Write-Host "  SHA-256:  $ActualOuter"
    Write-Host "  Git SHA:  $($Manifest.git_sha)"
    Write-Host "  CUDA:     $($Manifest.cuda_toolkit) / $($Manifest.cuda_arch)"
} finally {
    Remove-Item $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
