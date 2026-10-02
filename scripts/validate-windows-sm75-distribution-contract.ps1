[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$ContractPath = Join-Path $RepoRoot "config\windows-sm75-distribution-contract.json"
if (-not (Test-Path $ContractPath -PathType Leaf)) {
    throw "Distribution contract not found: $ContractPath"
}
$Contract = Get-Content $ContractPath -Raw | ConvertFrom-Json
if ($Contract.schema_version -ne 1 -or $Contract.profile -ne "qwen3.8-27b-sm75") {
    throw "Unexpected Windows SM75 distribution contract."
}

function Assert-SafeRelativePath([string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative)) { throw "Distribution contract contains an empty path." }
    $Unix = $Relative.Replace("\","/")
    if ([IO.Path]::IsPathRooted($Unix) -or $Unix -match "(^|/)\.\.(/|$)") {
        throw "Unsafe distribution-contract path: $Relative"
    }
    return $Unix
}

function Assert-UniqueList($Values,[string]$Label) {
    $Seen = @{}
    foreach ($Value in @($Values)) {
        $Unix = Assert-SafeRelativePath ([string]$Value)
        $Key = $Unix.ToLowerInvariant()
        if ($Seen.ContainsKey($Key)) { throw "$Label contains duplicate path: $Unix" }
        $Seen[$Key] = $true
    }
}

foreach ($Field in @("config_files","runtime_scripts","installer_files","launcher_files","docs_files","required_package_files")) {
    Assert-UniqueList $Contract.$Field $Field
}

$RequiredSet = @{}
foreach ($Required in @($Contract.required_package_files)) {
    $Unix = Assert-SafeRelativePath ([string]$Required)
    $RequiredSet[$Unix.ToLowerInvariant()] = $true
}

function Assert-RequiredMembership($Values,[string]$Prefix,[string]$Label) {
    foreach ($Value in @($Values)) {
        $Leaf = Assert-SafeRelativePath ([string]$Value)
        $Relative = if ([string]::IsNullOrWhiteSpace($Prefix)) { $Leaf } else { "$Prefix/$Leaf" }
        if (-not $RequiredSet.ContainsKey($Relative.ToLowerInvariant())) {
            throw "$Label entry is not present in required_package_files: $Relative"
        }
    }
}

Assert-RequiredMembership $Contract.config_files "config" "config_files"
Assert-RequiredMembership $Contract.runtime_scripts "scripts" "runtime_scripts"
Assert-RequiredMembership $Contract.installer_files "install" "installer_files"
Assert-RequiredMembership $Contract.launcher_files "launchers" "launcher_files"
Assert-RequiredMembership $Contract.docs_files "docs" "docs_files"
Assert-RequiredMembership $Contract.installer_root_files "" "installer_root_files"

$GeneratedPackage = @(
    "bin/ninfer.exe",
    "bin/ninfer-serve.exe",
    "BUILD-MANIFEST.json",
    "BUILD-TOOLCHAIN.json",
    "SBOM.cdx.json",
    "SHA256SUMS.txt"
)
$SourceAliases = @{
    "START-HERE.bat" = "install/START-HERE.bat"
    "README-FIRST.txt" = "install/README-FIRST.txt"
}
foreach ($Required in @($Contract.required_package_files)) {
    $Unix = Assert-SafeRelativePath ([string]$Required)
    if ($GeneratedPackage -contains $Unix) { continue }
    $SourceRelative = if ($SourceAliases.ContainsKey($Unix)) { $SourceAliases[$Unix] } else { $Unix }
    $SourcePath = Join-Path $RepoRoot ($SourceRelative.Replace("/",[IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path $SourcePath -PathType Leaf)) {
        throw "Distribution contract references missing source file: $SourceRelative"
    }
}

$ExpectedLaunchers = @($Contract.launcher_files | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object)
$ActualLaunchers = @(Get-ChildItem (Join-Path $RepoRoot "launchers") -Filter *.bat -File |
    ForEach-Object { $_.Name.ToLowerInvariant() } | Sort-Object)
if (($ExpectedLaunchers -join [Environment]::NewLine) -ne ($ActualLaunchers -join [Environment]::NewLine)) {
    throw "launcher_files does not exactly match repository launchers. Expected: $($ExpectedLaunchers -join ', '); Actual: $($ActualLaunchers -join ', ')"
}

foreach ($Rule in @($Contract.launcher_contracts)) {
    $Relative = Assert-SafeRelativePath ([string]$Rule.file)
    $Path = Join-Path $RepoRoot ($Relative.Replace("/",[IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path $Path -PathType Leaf)) { throw "Launcher contract file is missing: $Relative" }
    $Text = Get-Content $Path -Raw
    foreach ($Needle in @($Rule.contains)) {
        if ($Text.IndexOf([string]$Needle,[StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw "Launcher contract failed: $Relative does not contain '$Needle'."
        }
    }
}

foreach ($Directory in @("scripts","install")) {
    Get-ChildItem (Join-Path $RepoRoot $Directory) -Filter *.ps1 -File | ForEach-Object {
        $Tokens = $null
        $Errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$Tokens,[ref]$Errors)
        if ($Errors.Count -gt 0) {
            $Messages = $Errors | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" }
            throw "PowerShell syntax errors in $($_.FullName): $($Messages -join '; ')"
        }
    }
}

$Defaults = Get-Content (Join-Path $RepoRoot "config\production-defaults.json") -Raw | ConvertFrom-Json
if ($Defaults.schema_version -ne 1 -or $Defaults.profile -ne $Contract.profile -or $Defaults.model_key -ne "qwen3_8_27b") {
    throw "production-defaults.json is inconsistent with the distribution contract."
}
$ArtifactLock = Get-Content (Join-Path $RepoRoot "config\windows-sm75-artifacts.json") -Raw | ConvertFrom-Json
$Artifact = $ArtifactLock.artifacts.qwen3_8_27b
if (-not $Artifact -or $Artifact.filename -ne "qwen3_8_27b.ninfer" -or [string]$Artifact.sha256 -notmatch "^[0-9a-f]{64}$") {
    throw "windows-sm75-artifacts.json is inconsistent with the distribution contract."
}
$ToolchainLock = Get-Content (Join-Path $RepoRoot "config\windows-sm75-toolchain.json") -Raw | ConvertFrom-Json
if ($ToolchainLock.schema_version -ne 1 -or $ToolchainLock.profile -ne $Contract.profile) {
    throw "windows-sm75-toolchain.json is inconsistent with the distribution contract."
}

Write-Host "Windows SM75 distribution source contract passed."
Write-Host "  Required package files: $(@($Contract.required_package_files).Count)"
Write-Host "  Launchers:              $(@($Contract.launcher_files).Count)"
Write-Host "  PowerShell source:      syntax-valid"
