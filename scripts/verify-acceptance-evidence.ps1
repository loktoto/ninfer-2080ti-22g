[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$EvidencePath,
    [Parameter(Mandatory=$true)]
    [string]$ExpectedGitSha,
    [string]$LockPath = "",
    [int[]]$RequiredContexts = @(8192,32768,65536),
    [ValidateRange(1024,131072)]
    [int]$MinimumVramMiB = 20000
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ResolvedEvidence = (Resolve-Path $EvidencePath -ErrorAction Stop).Path
$Evidence = Get-Content $ResolvedEvidence -Raw | ConvertFrom-Json

if ($Evidence.schema_version -ne 1) {
    throw "Unsupported acceptance evidence schema: $($Evidence.schema_version)"
}
if ($Evidence.artifact_type -ne "ninfer_windows_sm75_hardware_acceptance") {
    throw "Unexpected acceptance artifact type: $($Evidence.artifact_type)"
}
if ([string]::IsNullOrWhiteSpace($Evidence.git_sha) -or $Evidence.git_sha -ne $ExpectedGitSha) {
    throw "Acceptance git SHA '$($Evidence.git_sha)' does not match expected '$ExpectedGitSha'."
}

if ([string]::IsNullOrWhiteSpace($LockPath)) {
    $CandidateRoot = Split-Path (Split-Path $ResolvedEvidence -Parent) -Parent
    $Candidate = Join-Path $CandidateRoot "config\windows-sm75-artifacts.json"
    if (Test-Path $Candidate -PathType Leaf) { $LockPath = $Candidate }
}
if ([string]::IsNullOrWhiteSpace($LockPath) -or -not (Test-Path $LockPath -PathType Leaf)) {
    throw "Artifact lock file was not found. Pass -LockPath explicitly."
}
$Lock = Get-Content $LockPath -Raw | ConvertFrom-Json
$ExpectedModelSha = [string]$Lock.artifacts.qwen3_8_27b.sha256
if ([string]::IsNullOrWhiteSpace($ExpectedModelSha)) { throw "Artifact lock is missing Qwen3.8 SHA-256." }
if ([string]$Evidence.model_sha256 -ne $ExpectedModelSha) {
    throw "Acceptance model SHA-256 does not match the production artifact lock."
}

$Gpu = $Evidence.gpu
if (-not $Gpu) { throw "Acceptance evidence is missing structured GPU metadata." }
if ([string]$Gpu.compute_capability -ne "7.5") {
    throw "Acceptance requires compute capability 7.5; evidence reports '$($Gpu.compute_capability)'."
}
if ([int]$Gpu.memory_total_mib -lt $MinimumVramMiB) {
    throw "Acceptance requires at least $MinimumVramMiB MiB VRAM; evidence reports $($Gpu.memory_total_mib)."
}
if ([string]$Gpu.name -notmatch "2080\s*Ti") {
    throw "Acceptance evidence GPU is not an RTX 2080 Ti: '$($Gpu.name)'."
}

$DriverMajor = 0
try { $DriverMajor = [int](([string]$Gpu.driver_version -split "\.")[0]) } catch {}
if ($DriverMajor -lt 580) {
    throw "Acceptance evidence driver '$($Gpu.driver_version)' is below the CUDA 13.x minimum R580 branch."
}

$Results = @($Evidence.context_results)
foreach ($Context in $RequiredContexts) {
    $Match = @($Results | Where-Object { [int]$_.context_limit -eq $Context }) | Select-Object -First 1
    if (-not $Match) { throw "Acceptance evidence is missing required context target $Context." }
    if ($Match.passed -ne $true) { throw "Context target $Context did not pass." }
    if ($Match.niah_passed -ne $true) { throw "NIAH semantic retrieval did not pass at $Context." }
    if ([int]$Match.counted_input_tokens -lt [int]($Context * 0.85)) {
        throw "Context target $Context was not exercised deeply enough: $($Match.counted_input_tokens) input tokens."
    }
}

if ($Evidence.mtp0_mtp3_token_parity -ne $true) {
    throw "MTP0/MTP3 token-ID parity is not proven."
}
if ([string]::IsNullOrWhiteSpace([string]$Evidence.mtp_generated_token_ids)) {
    throw "MTP parity evidence is missing generated token IDs."
}
if ($Evidence.tool_call -ne $true) {
    throw "OpenAI-compatible tool-call acceptance did not pass."
}

Write-Host "Hardware acceptance evidence verified."
Write-Host "  Evidence:  $ResolvedEvidence"
Write-Host "  Git SHA:   $($Evidence.git_sha)"
Write-Host "  GPU:       $($Gpu.name)"
Write-Host "  VRAM MiB:  $($Gpu.memory_total_mib)"
Write-Host "  Model SHA: $($Evidence.model_sha256)"
Write-Host "  Contexts:  $($RequiredContexts -join ', ')"
Write-Host "  MTP parity: token-identical"
Write-Host "  Tool call: passed"

