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

$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("ninfer-sm75-verify-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null
try {
    Expand-Archive -Path $Zip.FullName -DestinationPath $TempRoot -Force
    $Stage = Get-ChildItem $TempRoot -Directory | Select-Object -First 1
    if (-not $Stage) { throw "ZIP did not contain the expected top-level package directory." }

    $ManifestPath = Join-Path $Stage.FullName "BUILD-MANIFEST.json"
    $SumsPath = Join-Path $Stage.FullName "SHA256SUMS.txt"
    if (-not (Test-Path $ManifestPath)) { throw "BUILD-MANIFEST.json missing from package." }
    if (-not (Test-Path $SumsPath)) { throw "SHA256SUMS.txt missing from package." }

    $Manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
    if ($Manifest.schema_version -ne 2) { throw "Unsupported manifest schema: $($Manifest.schema_version)" }
    if ($Manifest.cuda_arch -ne "sm_75") { throw "Unexpected CUDA architecture: $($Manifest.cuda_arch)" }
    if ($Manifest.artifact_type -ne "ninfer-windows-sm75-runtime") { throw "Unexpected artifact type." }
    if ($Manifest.build_profile -ne "qwen3.8-27b-sm75") { throw "Unexpected build profile: $($Manifest.build_profile)" }
    if ([string]::IsNullOrWhiteSpace([string]$Manifest.artifact_channel)) {
        throw "Build manifest is missing artifact_channel."
    }
    if ([string]::IsNullOrWhiteSpace([string]$Manifest.artifact_lock_sha256)) {
        throw "Build manifest is missing artifact_lock_sha256."
    }

    $LockPath = Join-Path $Stage.FullName "config\windows-sm75-artifacts.json"
    if (-not (Test-Path $LockPath -PathType Leaf)) {
        throw "Pinned artifact lock is missing from the package."
    }
    $ActualLockHash = (Get-FileHash $LockPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ActualLockHash -ne ([string]$Manifest.artifact_lock_sha256).ToLowerInvariant()) {
        throw "Pinned artifact lock hash does not match BUILD-MANIFEST.json."
    }

    foreach ($Line in Get-Content $SumsPath) {
        if ([string]::IsNullOrWhiteSpace($Line)) { continue }
        if ($Line -notmatch "^([0-9a-fA-F]{64})\s{2}(.+)$") { throw "Malformed checksum line: $Line" }
        $Expected = $Matches[1].ToLowerInvariant()
        $Relative = $Matches[2].Replace("/", [IO.Path]::DirectorySeparatorChar)
        $FilePath = Join-Path $Stage.FullName $Relative
        if (-not (Test-Path $FilePath -PathType Leaf)) { throw "Checksummed file is missing: $Relative" }
        $Actual = (Get-FileHash $FilePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($Actual -ne $Expected) { throw "SHA-256 mismatch for $Relative." }
    }

    foreach ($Required in @(
        "bin\ninfer.exe",
        "bin\ninfer-serve.exe",
        "scripts\run-server-windows-sm75.ps1",
        "scripts\healthcheck-windows-sm75.ps1",
        "scripts\smoke-test-windows-sm75.ps1",
        "scripts\acceptance-windows-sm75.ps1",
        "scripts\download-qwen38-windows-sm75.ps1",
        "scripts\verify-acceptance-evidence.ps1",
        "scripts\verify-windows-sm75.ps1",
        "config\windows-sm75-artifacts.json"
    )) {
        if (-not (Test-Path (Join-Path $Stage.FullName $Required) -PathType Leaf)) {
            throw "Required production package file is missing: $Required"
        }
    }

    Write-Host "Release package integrity verification passed."
    Write-Host "  ZIP:      $($Zip.Name)"
    Write-Host "  SHA-256:  $ActualOuter"
    Write-Host "  Git SHA:  $($Manifest.git_sha)"
    Write-Host "  CUDA:     $($Manifest.cuda_toolkit) / $($Manifest.cuda_arch)"
} finally {
    Remove-Item $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
