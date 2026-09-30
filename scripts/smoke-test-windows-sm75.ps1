[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Model,
    [string]$InstallDir = "out\windows-sm75",
    [ValidateRange(0,15)]
    [int]$Device = 0,
    [ValidateRange(1024,262144)]
    [int]$Context = 8192,
    [ValidateRange(1,512)]
    [int]$MaxNew = 32,
    [ValidateRange(1024,131072)]
    [int]$MinVramMiB = 20000
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$PackagedExe = Join-Path $RepoRoot "bin\ninfer.exe"
if (Test-Path $PackagedExe) {
    $Exe = $PackagedExe
} else {
    $Exe = Join-Path $RepoRoot "$InstallDir\bin\ninfer.exe"
}
if (-not (Test-Path $Exe)) { throw "ninfer.exe not found: $Exe" }
$ModelPath = (Resolve-Path $Model -ErrorAction Stop).Path

$NvidiaSmi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
if (-not $NvidiaSmi) { $NvidiaSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue }
if (-not $NvidiaSmi) { throw "nvidia-smi was not found. Install a supported NVIDIA driver." }

$Rows = @(& $NvidiaSmi.Source --query-gpu=index,name,memory.total,compute_cap,driver_version --format=csv,noheader,nounits)
if ($LASTEXITCODE -ne 0 -or $Rows.Count -eq 0) { throw "nvidia-smi GPU query failed." }

$Selected = $null
foreach ($Row in $Rows) {
    $Parts = @($Row -split "," | ForEach-Object { $_.Trim() })
    if ($Parts.Count -lt 5) { continue }
    if ([int]$Parts[0] -eq $Device) {
        $Selected = [pscustomobject]@{
            Index = [int]$Parts[0]
            Name = $Parts[1]
            VramMiB = [int]$Parts[2]
            ComputeCapability = $Parts[3]
            Driver = $Parts[4]
        }
        break
    }
}
if (-not $Selected) { throw "GPU index $Device was not reported by nvidia-smi." }
if ($Selected.ComputeCapability -ne "7.5") {
    throw "Production SM75 acceptance requires compute capability 7.5; GPU $Device reports $($Selected.ComputeCapability)."
}
if ($Selected.VramMiB -lt $MinVramMiB) {
    throw "GPU $Device reports $($Selected.VramMiB) MiB VRAM; production Qwen3.8-27B acceptance requires at least $MinVramMiB MiB."
}

Write-Host "GPU preflight passed:"
Write-Host "  Device:  $($Selected.Index)"
Write-Host "  Name:    $($Selected.Name)"
Write-Host "  VRAM:    $($Selected.VramMiB) MiB"
Write-Host "  CC:      $($Selected.ComputeCapability)"
Write-Host "  Driver:  $($Selected.Driver)"
Write-Host "  Context: $Context"

$PreviousVisibleDevices = $env:CUDA_VISIBLE_DEVICES
try {
    $env:CUDA_VISIBLE_DEVICES = $Device.ToString()
    Write-Host "Running deterministic Qwen3.8 SM75 smoke test..."
    $Output = @(& $Exe $ModelPath --prompt "Reply with exactly: SM75 OK" --max-context $Context --max-new $MaxNew --kv-dtype int8 --greedy 2>&1)
    $ExitCode = $LASTEXITCODE
    $Output | ForEach-Object { Write-Host $_ }
    if ($ExitCode -ne 0) { throw "NInfer smoke test failed with exit code $ExitCode." }
    if ([string]::IsNullOrWhiteSpace(($Output -join "`n"))) { throw "NInfer returned no observable output." }
} finally {
    if ($null -eq $PreviousVisibleDevices) {
        Remove-Item Env:CUDA_VISIBLE_DEVICES -ErrorAction SilentlyContinue
    } else {
        $env:CUDA_VISIBLE_DEVICES = $PreviousVisibleDevices
    }
}

Write-Host "Hardware smoke test passed."
