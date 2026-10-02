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
    if ($Manifest.schema_version -ne 2) { throw "Unsupported manifest schema: $($Manifest.schema_version)" }
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

    foreach ($Required in @(
        "bin\ninfer.exe",
        "bin\ninfer-serve.exe",
        "scripts\run-server-windows-sm75.ps1",
        "scripts\healthcheck-windows-sm75.ps1",
        "scripts\smoke-test-windows-sm75.ps1",
        "scripts\acceptance-windows-sm75.ps1",
        "scripts\download-qwen38-windows-sm75.ps1",
        "scripts\manage-installed-server.ps1",
        "scripts\verify-acceptance-evidence.ps1",
        "scripts\verify-windows-sm75.ps1",
        "config\windows-sm75-artifacts.json",
        "config\production-defaults.json",
        "SBOM.cdx.json",
        "docs\INSTALL-WINDOWS-SM75.md",
        "install\install-ninfer-sm75.ps1",
        "install\install-ninfer-sm75.bat",
        "install\first-run-wizard.ps1",
        "install\verify-installation.ps1",
        "install\repair-ninfer-sm75.ps1",
        "install\uninstall-ninfer-sm75.ps1",
        "launchers\Start-NInfer.bat",
        "launchers\Start-NInfer-MTP.bat",
        "launchers\Start-NInfer-Vision.bat",
        "launchers\Start-NInfer-MTP-Vision.bat",
        "launchers\Stop-NInfer.bat",
        "launchers\Status-NInfer.bat",
        "launchers\Configure-NInfer.bat",
        "launchers\Check-NInfer.bat",
        "launchers\Repair-NInfer.bat",
        "launchers\Uninstall-NInfer.bat",
        "launchers\Open-NInfer-Logs.bat",
        "install\START-HERE.bat",
        "install\README-FIRST.txt",
        "START-HERE.bat",
        "README-FIRST.txt"
    )) {
        if (-not (Test-Path (Join-Path $Stage.FullName $Required) -PathType Leaf)) {
            throw "Required production package file is missing: $Required"
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
