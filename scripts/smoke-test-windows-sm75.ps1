[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Model,
    [string]$BuildDir = "build-windows-sm75",
    [int]$Context = 8192
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Exe = Join-Path $RepoRoot "$BuildDir\apps\ninfer.exe"
if (-not (Test-Path $Exe)) { throw "ninfer.exe not found: $Exe" }
if (-not (Test-Path $Model)) { throw "Model artifact not found: $Model" }

& nvidia-smi --query-gpu=name,memory.total,compute_cap --format=csv,noheader
if ($LASTEXITCODE -ne 0) { throw "nvidia-smi failed." }

Write-Host "Running Qwen3.8 SM75 smoke test..."
& $Exe $Model --prompt "Reply with exactly: SM75 OK" --max-context $Context --max-new 32 --kv-dtype int8 --greedy
if ($LASTEXITCODE -ne 0) { throw "NInfer smoke test failed with exit code $LASTEXITCODE." }
