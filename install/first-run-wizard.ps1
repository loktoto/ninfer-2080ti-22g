[CmdletBinding()]
param(
    [string]$ModelDir = "",
    [ValidateRange(1,65535)]
    [int]$Port = 8080,
    [ValidateRange(1024,262144)]
    [int]$MaxContext = 16384,
    [ValidateRange(-1,15)]
    [int]$Device = -1,
    [string]$ApiKey = "",
    [switch]$DownloadModel,
    [switch]$NoModelHash
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$DefaultsPath = Join-Path $Root "config\production-defaults.json"
$LockPath = Join-Path $Root "config\windows-sm75-artifacts.json"
$SettingsPath = Join-Path $Root "config\user-settings.json"
$SecretsDir = Join-Path $Root "secrets"
$KeyPath = Join-Path $SecretsDir "api-key.txt"
if (-not (Test-Path $DefaultsPath -PathType Leaf)) { throw "Missing production defaults: $DefaultsPath" }
if (-not (Test-Path $LockPath -PathType Leaf)) { throw "Missing artifact lock: $LockPath" }
$Defaults = Get-Content $DefaultsPath -Raw | ConvertFrom-Json
$Lock = Get-Content $LockPath -Raw | ConvertFrom-Json
$Artifact = $Lock.artifacts.qwen3_8_27b

$Existing = $null
if (Test-Path $SettingsPath -PathType Leaf) {
    try { $Existing = Get-Content $SettingsPath -Raw | ConvertFrom-Json } catch { Write-Warning "Existing settings are invalid and will be rebuilt." }
}

if (-not $PSBoundParameters.ContainsKey("ModelDir") -or [string]::IsNullOrWhiteSpace($ModelDir)) {
    if ($Existing -and -not [string]::IsNullOrWhiteSpace([string]$Existing.model_dir)) {
        $ModelDir = [string]$Existing.model_dir
    } elseif (Test-Path "D:\") {
        $ModelDir = "D:\AI\models\qwen"
    } else {
        $ModelDir = Join-Path $Root "models"
    }
}
if (-not [IO.Path]::IsPathRooted($ModelDir)) { $ModelDir = [IO.Path]::GetFullPath((Join-Path $Root $ModelDir)) }
else { $ModelDir = [IO.Path]::GetFullPath($ModelDir) }
New-Item -ItemType Directory -Force -Path $ModelDir | Out-Null

if (-not $PSBoundParameters.ContainsKey("Port") -and $Existing) { $Port = [int]$Existing.port }
if (-not $PSBoundParameters.ContainsKey("MaxContext") -and $Existing) { $MaxContext = [int]$Existing.max_context }

$Nvidia = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
if (-not $Nvidia) { $Nvidia = Get-Command nvidia-smi -ErrorAction SilentlyContinue }
if (-not $Nvidia) { throw "nvidia-smi was not found. Install a current NVIDIA driver first." }
$Rows = @(& $Nvidia.Source --query-gpu=index,name,memory.total,compute_cap,driver_version --format=csv,noheader,nounits)
if ($LASTEXITCODE -ne 0 -or $Rows.Count -eq 0) { throw "nvidia-smi GPU query failed." }
$Gpus = @()
foreach ($Row in $Rows) {
    $P = @($Row -split "," | ForEach-Object { $_.Trim() })
    if ($P.Count -ge 5) {
        $Gpus += [pscustomobject]@{ Index=[int]$P[0]; Name=$P[1]; VramMiB=[int]$P[2]; ComputeCapability=$P[3]; Driver=$P[4] }
    }
}
if ($Device -lt 0) {
    if ($Existing -and -not $PSBoundParameters.ContainsKey("Device")) {
        $Candidate = @($Gpus | Where-Object { $_.Index -eq [int]$Existing.device }) | Select-Object -First 1
    } else { $Candidate = $null }
    if (-not $Candidate) {
        $Candidate = @($Gpus | Where-Object { $_.ComputeCapability -eq "7.5" -and $_.VramMiB -ge 20000 -and $_.Name -match "2080\s*Ti" -and [int](($_.Driver -split "\.")[0]) -ge 580 }) | Select-Object -First 1
    }
    if (-not $Candidate) { throw "No RTX 2080 Ti 20GB+ / compute capability 7.5 GPU was found." }
    $Device = [int]$Candidate.Index
}
$Selected = @($Gpus | Where-Object { $_.Index -eq $Device }) | Select-Object -First 1
if (-not $Selected) { throw "GPU index $Device was not reported by nvidia-smi." }
if ($Selected.ComputeCapability -ne "7.5" -or $Selected.VramMiB -lt 20000 -or $Selected.Name -notmatch "2080\s*Ti") {
    throw "GPU $Device is not the production target: $($Selected.Name), CC $($Selected.ComputeCapability), $($Selected.VramMiB) MiB."
}

$Downloader = Join-Path $Root "scripts\download-qwen38-windows-sm75.ps1"
if ($DownloadModel) { & $Downloader -ModelDir $ModelDir }
$ModelPath = Join-Path $ModelDir ([string]$Artifact.filename)
if (-not (Test-Path $ModelPath -PathType Leaf)) {
    throw "Pinned model is missing: $ModelPath. Re-run with -DownloadModel or use the installer."
}
if (-not $NoModelHash) { & $Downloader -ModelDir $ModelDir -VerifyOnly }

New-Item -ItemType Directory -Force -Path $SecretsDir | Out-Null
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    if (Test-Path $KeyPath -PathType Leaf) { $ApiKey = (Get-Content $KeyPath -Raw).Trim() }
    else { $ApiKey = ([guid]::NewGuid().ToString("N") + [guid]::NewGuid().ToString("N")) }
}
if ([string]::IsNullOrWhiteSpace($ApiKey)) { throw "API key generation failed." }
Set-Content -Path $KeyPath -Value $ApiKey -Encoding ASCII -NoNewline
try {
    $Identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $Acl = Get-Acl $KeyPath
    $Acl.SetAccessRuleProtection($true,$false)
    foreach ($Rule in @($Acl.Access)) { [void]$Acl.RemoveAccessRuleSpecific($Rule) }
    $UserRule = New-Object System.Security.AccessControl.FileSystemAccessRule($Identity,"FullControl","Allow")
    $SystemRule = New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM","FullControl","Allow")
    $Acl.AddAccessRule($UserRule)
    $Acl.AddAccessRule($SystemRule)
    Set-Acl -Path $KeyPath -AclObject $Acl
} catch {
    Write-Warning "Could not tighten API-key ACL automatically: $($_.Exception.Message)"
}

$Settings = [ordered]@{
    schema_version = 1
    profile = "qwen3.8-27b-sm75"
    model_dir = $ModelDir
    model_path = $ModelPath
    device = $Device
    host = "127.0.0.1"
    port = $Port
    max_context = $MaxContext
    max_concurrency = 1
    kv_dtype = "int8"
    kv_capacity = "auto"
    default_mode = "Base"
    draft_tokens = 3
    api_key_file = $KeyPath
    configured_utc = [DateTime]::UtcNow.ToString("o")
}
$Temp = "$SettingsPath.tmp"
$Settings | ConvertTo-Json -Depth 5 | Set-Content $Temp -Encoding UTF8
Move-Item $Temp $SettingsPath -Force

Write-Host ""
Write-Host "NInfer first-run configuration completed."
Write-Host "  Install root: $Root"
Write-Host "  GPU:          $($Selected.Name) / $($Selected.VramMiB) MiB / CC $($Selected.ComputeCapability)"
Write-Host "  Model:        $ModelPath"
Write-Host "  API:          http://127.0.0.1`:$Port/v1"
Write-Host "  Context:      $MaxContext"
Write-Host "  KV:           int8 / auto"
Write-Host "  API key:      stored in protected local key file (not printed)"
