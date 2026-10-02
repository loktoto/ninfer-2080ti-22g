[CmdletBinding()]
param(
    [switch]$Fast,
    [switch]$Full,
    [switch]$PackageOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Failures = New-Object System.Collections.Generic.List[string]
$Warnings = New-Object System.Collections.Generic.List[string]

function Pass([string]$Message) { Write-Host "[PASS] $Message" }
function Fail([string]$Message) { $Failures.Add($Message); Write-Host "[FAIL] $Message" }
function Warn([string]$Message) { $Warnings.Add($Message); Write-Host "[WARN] $Message" }

Write-Host "== NInfer SM75 installation verification =="

$Required = @(
    "bin\ninfer.exe",
    "bin\ninfer-serve.exe",
    "config\windows-sm75-artifacts.json",
    "config\production-defaults.json",
    "scripts\download-qwen38-windows-sm75.ps1",
    "scripts\healthcheck-windows-sm75.ps1",
    "scripts\manage-installed-server.ps1",
    "launchers\Start-NInfer.bat",
    "launchers\Start-NInfer-MTP.bat",
    "launchers\Stop-NInfer.bat",
    "install\first-run-wizard.ps1"
)
foreach ($Rel in $Required) {
    if (Test-Path (Join-Path $Root $Rel) -PathType Leaf) { Pass $Rel }
    else { Fail "Missing $Rel" }
}

$SumsPath = Join-Path $Root "SHA256SUMS.txt"
$Listed = @{}
if (Test-Path $SumsPath -PathType Leaf) {
    Write-Host "Checking installed package hashes..."
    foreach ($Line in Get-Content $SumsPath) {
        if ([string]::IsNullOrWhiteSpace($Line)) { continue }
        if ($Line -notmatch "^([0-9a-fA-F]{64})\s{2}(.+)$") { Fail "Malformed SHA256SUMS line"; continue }
        $Expected = $Matches[1].ToLowerInvariant()
        $RelativeUnix = $Matches[2].Replace("\","/")
        if ([IO.Path]::IsPathRooted($RelativeUnix) -or $RelativeUnix -match "(^|/)\.\.(/|$)") {
            Fail "Unsafe SHA256SUMS path: $RelativeUnix"
            continue
        }
        $Key = $RelativeUnix.ToLowerInvariant()
        if ($Listed.ContainsKey($Key)) {
            Fail "Duplicate SHA256SUMS path: $RelativeUnix"
            continue
        }
        $Listed[$Key] = $true

        $Relative = $RelativeUnix.Replace("/",[IO.Path]::DirectorySeparatorChar)
        $RootPrefix = [IO.Path]::GetFullPath($Root).TrimEnd("\") + "\"
        $Path = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
        if (-not $Path.StartsWith($RootPrefix,[StringComparison]::OrdinalIgnoreCase)) {
            Fail "Checksummed path escaped install root: $RelativeUnix"
            continue
        }
        if (-not (Test-Path $Path -PathType Leaf)) { Fail "Checksummed file missing: $Relative"; continue }
        $Actual = (Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($Actual -ne $Expected) { Fail "Package hash mismatch: $Relative" }
    }
    if ($Failures.Count -eq 0) { Pass "Installed package SHA-256 set" }
    $ImmutableRoots = @("bin","scripts","docs","install","launchers")
    foreach ($Dir in $ImmutableRoots) {
        $DirPath = Join-Path $Root $Dir
        if (-not (Test-Path $DirPath -PathType Container)) { continue }
        Get-ChildItem $DirPath -Recurse -File | ForEach-Object {
            $RootPrefix = [IO.Path]::GetFullPath($Root).TrimEnd("\") + "\"
            $Relative = $_.FullName.Substring($RootPrefix.Length).Replace("\","/").ToLowerInvariant()
            if (-not $Listed.ContainsKey($Relative)) { Fail "Unexpected file in immutable runtime tree: $Relative" }
        }
    }
    $ConfigPath = Join-Path $Root "config"
    if (Test-Path $ConfigPath -PathType Container) {
        Get-ChildItem $ConfigPath -File | ForEach-Object {
            if ($_.Name -ne "user-settings.json") {
                $RootPrefix = [IO.Path]::GetFullPath($Root).TrimEnd("\") + "\"
                $Relative = $_.FullName.Substring($RootPrefix.Length).Replace("\","/").ToLowerInvariant()
                if (-not $Listed.ContainsKey($Relative)) { Fail "Unexpected file in immutable config tree: $Relative" }
            }
        }
    }
} else {
    Warn "SHA256SUMS.txt absent; package-level integrity cannot be rechecked"
}

$ManifestPath = Join-Path $Root "BUILD-MANIFEST.json"
if (Test-Path $ManifestPath -PathType Leaf) {
    try {
        $Manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
        if ($Manifest.build_profile -ne "qwen3.8-27b-sm75") { Fail "Unexpected build profile: $($Manifest.build_profile)" }
        else { Pass "Build profile qwen3.8-27b-sm75" }
        if ($Manifest.cuda_arch -ne "sm_75") { Fail "Unexpected CUDA arch: $($Manifest.cuda_arch)" }
        else { Pass "CUDA target sm_75" }
        if ($Manifest.cuda_runtime_linkage -and $Manifest.cuda_runtime_linkage -ne "static") {
            Fail "Windows release is not marked as static CUDA runtime linkage."
        } elseif ($Manifest.cuda_runtime_linkage -eq "static") {
            Pass "CUDA runtime statically linked"
        }
    } catch { Fail "BUILD-MANIFEST.json is invalid: $($_.Exception.Message)" }
} else {
    Warn "BUILD-MANIFEST.json missing (development staging tree?)"
}

if (-not $PackageOnly) {
    $RuntimeDll = Join-Path $env:WINDIR "System32\vcruntime140.dll"
    if (Test-Path $RuntimeDll -PathType Leaf) { Pass "Microsoft VC++ x64 runtime present" }
    else { Fail "Microsoft VC++ x64 runtime missing" }
    
    $Nvidia = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if (-not $Nvidia) { $Nvidia = Get-Command nvidia-smi -ErrorAction SilentlyContinue }
    if (-not $Nvidia) {
        Fail "nvidia-smi not found"
    } else {
        $Rows = @(& $Nvidia.Source --query-gpu=index,name,memory.total,compute_cap,driver_version --format=csv,noheader,nounits)
        $Target = $null
        foreach ($Row in $Rows) {
            $P = @($Row -split "," | ForEach-Object { $_.Trim() })
            if ($P.Count -ge 5 -and $P[1] -match "2080\s*Ti" -and $P[3] -eq "7.5" -and [int]$P[2] -ge 20000 -and [int](($P[4] -split "\.")[0]) -ge 580) {
                $Target = $P
                break
            }
        }
        if ($Target) { Pass "RTX 2080 Ti 20GB+ / CC 7.5 detected ($($Target[2]) MiB)" }
        else { Fail "No production-target RTX 2080 Ti 20GB+ / CC 7.5 / R580+ driver detected" }
    }
    
    $SettingsPath = Join-Path $Root "config\user-settings.json"
    $Settings = $null
    if (Test-Path $SettingsPath -PathType Leaf) {
        try {
            $Settings = Get-Content $SettingsPath -Raw | ConvertFrom-Json
            Pass "user-settings.json parsed"
            if (-not (Test-Path ([string]$Settings.model_path) -PathType Leaf)) { Fail "Configured model file missing" }
            else {
                $Lock = Get-Content (Join-Path $Root "config\windows-sm75-artifacts.json") -Raw | ConvertFrom-Json
                $ExpectedBytes = [int64]$Lock.artifacts.qwen3_8_27b.bytes
                $ActualBytes = (Get-Item ([string]$Settings.model_path)).Length
                if ($ActualBytes -eq $ExpectedBytes) { Pass "Model byte size matches pinned artifact" }
                else { Fail "Model byte size mismatch: $ActualBytes vs $ExpectedBytes" }
            }
            if (-not (Test-Path ([string]$Settings.api_key_file) -PathType Leaf)) { Fail "API key file missing" }
            elseif ([string]::IsNullOrWhiteSpace((Get-Content ([string]$Settings.api_key_file) -Raw))) { Fail "API key file empty" }
            else { Pass "Local API key present" }
        } catch { Fail "User configuration invalid: $($_.Exception.Message)" }
    } else {
        Fail "user-settings.json missing; run Configure-NInfer.bat"
    }
    
    foreach ($ExeName in @("ninfer.exe","ninfer-serve.exe")) {
        $Exe = Join-Path $Root "bin\$ExeName"
        if (Test-Path $Exe -PathType Leaf) {
            $Output = @(& $Exe --help 2>&1)
            if ($LASTEXITCODE -eq 0) { Pass "$ExeName startup / dependency load" }
            else { Fail "$ExeName --help exited $LASTEXITCODE : $($Output -join ' ')" }
        }
    }
    
    if ($Full -and $Settings) {
        Write-Host "Running full pinned-model hash verification..."
        try {
            & (Join-Path $Root "scripts\download-qwen38-windows-sm75.ps1") -ModelDir ([string]$Settings.model_dir) -VerifyOnly
            Pass "Pinned model SHA-256 + container verified"
        } catch { Fail "Pinned model verification failed: $($_.Exception.Message)" }
    
        if ($Failures.Count -eq 0) {
            Write-Host "Running physical 8K GPU smoke test..."
            try {
                & (Join-Path $Root "scripts\smoke-test-windows-sm75.ps1") -Model ([string]$Settings.model_path) -Device ([int]$Settings.device) -Context 8192 -MaxNew 16
                Pass "8K physical GPU smoke test"
            } catch { Fail "8K GPU smoke test failed: $($_.Exception.Message)" }
        }
    }
}

Write-Host ""
Write-Host "Verification summary: $($Failures.Count) failure(s), $($Warnings.Count) warning(s)."
if ($Failures.Count -gt 0) {
    $Failures | ForEach-Object { Write-Host "  - $_" }
    throw "NInfer SM75 installation verification failed with $($Failures.Count) failure(s)."
}
Write-Host "NInfer SM75 installation verification passed."
return