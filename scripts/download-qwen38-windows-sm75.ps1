[CmdletBinding()]
param(
    [string]$ModelDir = "models",
    [switch]$VerifyOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$LockPath = Join-Path $RepoRoot "config\windows-sm75-artifacts.json"
if (-not (Test-Path $LockPath -PathType Leaf)) {
    throw "Artifact lock file not found: $LockPath"
}

$Lock = Get-Content $LockPath -Raw | ConvertFrom-Json
if ($Lock.schema_version -ne 1) {
    throw "Unsupported artifact lock schema: $($Lock.schema_version)"
}
$Artifact = $Lock.artifacts.qwen3_8_27b
if (-not $Artifact) { throw "qwen3_8_27b is missing from the artifact lock." }

if ([IO.Path]::IsPathRooted($ModelDir)) {
    $ResolvedModelDir = $ModelDir
} else {
    $ResolvedModelDir = Join-Path $RepoRoot $ModelDir
}
New-Item -ItemType Directory -Force -Path $ResolvedModelDir | Out-Null
$ModelPath = Join-Path $ResolvedModelDir $Artifact.filename

if (-not $VerifyOnly) {
    $Hf = Get-Command hf.exe -ErrorAction SilentlyContinue
    if (-not $Hf) { $Hf = Get-Command hf -ErrorAction SilentlyContinue }
    if (-not $Hf) {
        throw "Hugging Face CLI 'hf' was not found. Install it with: py -m pip install -U huggingface_hub"
    }

    Write-Host "Downloading pinned Qwen3.8 artifact..."
    Write-Host "  Repository: $($Artifact.repository)"
    Write-Host "  Revision:   $($Artifact.revision)"
    Write-Host "  File:       $($Artifact.filename)"

    $HfArgs = @(
        "download",
        [string]$Artifact.repository,
        [string]$Artifact.filename,
        "--revision",
        [string]$Artifact.revision,
        "--local-dir",
        $ResolvedModelDir
    )
    & $Hf.Source @HfArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Pinned Qwen3.8 artifact download failed with exit code $LASTEXITCODE."
    }
}

if (-not (Test-Path $ModelPath -PathType Leaf)) {
    throw "Pinned artifact not found: $ModelPath"
}

$Length = (Get-Item $ModelPath).Length
if ([int64]$Length -ne [int64]$Artifact.bytes) {
    throw "Artifact size mismatch. Expected $($Artifact.bytes) bytes, got $Length. Delete the file and download the pinned revision again."
}

$Hash = (Get-FileHash $ModelPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($Hash -ne $Artifact.sha256.ToLowerInvariant()) {
    throw "Artifact SHA-256 mismatch. Expected $($Artifact.sha256), got $Hash."
}

$Stream = [IO.File]::Open($ModelPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    $Header = New-Object byte[] 8
    if ($Stream.Read($Header, 0, $Header.Length) -ne $Header.Length) {
        throw "Artifact is shorter than the NInfer magic header."
    }
} finally {
    $Stream.Dispose()
}

$ExpectedMagic = [byte[]](78,73,78,70,69,82,0,[int]$Artifact.container_version)
for ($i = 0; $i -lt $ExpectedMagic.Length; $i++) {
    if ($Header[$i] -ne $ExpectedMagic[$i]) {
        $ObservedVersion = $Header[7]
        throw "Artifact container mismatch. Production channel requires v$($Artifact.container_version); observed header version $ObservedVersion."
    }
}

Write-Host "Pinned Qwen3.8 artifact verified."
Write-Host "  Path:      $ModelPath"
Write-Host "  Bytes:     $Length"
Write-Host "  SHA-256:   $Hash"
Write-Host "  Container: v$($Artifact.container_version)"

