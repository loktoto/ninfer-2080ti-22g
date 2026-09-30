[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Model,
    [string]$InstallDir = "out\windows-sm75",
    [string]$HostAddress = "127.0.0.1",
    [ValidateRange(1,65535)]
    [int]$Port = 8080,
    [ValidateRange(1024,262144)]
    [int]$MaxContext = 16384,
    [ValidateRange(1,8)]
    [int]$MaxConcurrency = 1,
    [string]$ApiKey = $env:NINFER_API_KEY,
    [switch]$EnableMtp,
    [ValidateRange(1,8)]
    [int]$DraftTokens = 3,
    [switch]$Vision
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Exe = Join-Path $RepoRoot "$InstallDir\bin\ninfer-serve.exe"
if (-not (Test-Path $Exe)) { throw "ninfer-serve.exe not found: $Exe" }
$ModelPath = (Resolve-Path $Model -ErrorAction Stop).Path

$Loopback = @("127.0.0.1","localhost","::1")
if ($Loopback -notcontains $HostAddress -and [string]::IsNullOrWhiteSpace($ApiKey)) {
    throw "Refusing non-loopback bind without an API key. Set NINFER_API_KEY or pass -ApiKey."
}

$LogDir = Join-Path $RepoRoot "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$RequestLog = Join-Path $LogDir "ninfer-requests.jsonl"

$Args = @(
    $ModelPath,
    "--host", $HostAddress,
    "--port", $Port.ToString(),
    "--max-context", $MaxContext.ToString(),
    "--kv-capacity", "auto",
    "--max-concurrency", $MaxConcurrency.ToString(),
    "--kv-dtype", "int8",
    "--request-log-jsonl", $RequestLog,
    "--log-stats-interval-ms", "5000"
)

if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
    $Args += @("--api-key", $ApiKey)
}
if ($EnableMtp) {
    $Args += @("--spec", "mtp", "--draft-tokens", $DraftTokens.ToString(), "--lm-head-draft")
}
if ($Vision) { $Args += "--vision" }

Write-Host "Starting NInfer SM75 server..."
Write-Host "  Model:       $ModelPath"
Write-Host "  Listen:      http://$HostAddress`:$Port"
Write-Host "  Context:     $MaxContext"
Write-Host "  KV cache:    int8 / auto capacity"
Write-Host "  Concurrency: $MaxConcurrency"
Write-Host "  MTP:         $($EnableMtp.IsPresent)"
Write-Host "  Vision:      $($Vision.IsPresent)"
Write-Host "  Request log: $RequestLog"

& $Exe @Args
exit $LASTEXITCODE
