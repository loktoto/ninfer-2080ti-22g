[CmdletBinding()]
param(
    [string]$ModelDir = "models",
    [ValidateSet("Auto","Curl","Hf")]
    [string]$Backend = "Auto",
    [switch]$VerifyOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$LockPath = Join-Path $RepoRoot "config\windows-sm75-artifacts.json"
if (-not (Test-Path $LockPath -PathType Leaf)) { throw "Artifact lock file not found: $LockPath" }

$Lock = Get-Content $LockPath -Raw | ConvertFrom-Json
if ($Lock.schema_version -ne 1) { throw "Unsupported artifact lock schema: $($Lock.schema_version)" }
$Artifact = $Lock.artifacts.qwen3_8_27b
if (-not $Artifact) { throw "qwen3_8_27b is missing from the artifact lock." }

if ([IO.Path]::IsPathRooted($ModelDir)) {
    $ResolvedModelDir = [IO.Path]::GetFullPath($ModelDir)
} else {
    $ResolvedModelDir = [IO.Path]::GetFullPath((Join-Path $RepoRoot $ModelDir))
}
New-Item -ItemType Directory -Force -Path $ResolvedModelDir | Out-Null
$ModelPath = Join-Path $ResolvedModelDir ([string]$Artifact.filename)
$PartialPath = "$ModelPath.partial"

function Get-ArtifactVerification([string]$Path,[switch]$ThrowOnFailure) {
    try {
        if (-not (Test-Path $Path -PathType Leaf)) { throw "File does not exist: $Path" }
        $Length = (Get-Item $Path).Length
        if ([int64]$Length -ne [int64]$Artifact.bytes) {
            throw "Size mismatch. Expected $($Artifact.bytes) bytes, got $Length."
        }

        Write-Host "Hashing pinned artifact: $Path"
        $Hash = (Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($Hash -ne ([string]$Artifact.sha256).ToLowerInvariant()) {
            throw "SHA-256 mismatch. Expected $($Artifact.sha256), got $Hash."
        }

        $Stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try {
            $Header = New-Object byte[] 8
            if ($Stream.Read($Header,0,$Header.Length) -ne $Header.Length) {
                throw "Artifact is shorter than the NInfer header."
            }
        } finally { $Stream.Dispose() }

        $ExpectedMagic = [byte[]](78,73,78,70,69,82,0,[int]$Artifact.container_version)
        for ($i=0; $i -lt $ExpectedMagic.Length; $i++) {
            if ($Header[$i] -ne $ExpectedMagic[$i]) {
                throw "NInfer container magic/version mismatch. Required v$($Artifact.container_version)."
            }
        }

        return [pscustomobject]@{ Path=$Path; Length=[int64]$Length; Hash=$Hash }
    } catch {
        if ($ThrowOnFailure) { throw }
        return $null
    }
}

function Write-Verified($Info) {
    Write-Host "Pinned Qwen3.8 artifact verified."
    Write-Host "  Path:      $($Info.Path)"
    Write-Host "  Bytes:     $($Info.Length)"
    Write-Host "  SHA-256:   $($Info.Hash)"
    Write-Host "  Container: v$($Artifact.container_version)"
}

if ($VerifyOnly) {
    $Info = Get-ArtifactVerification $ModelPath -ThrowOnFailure
    Write-Verified $Info
    return
}

if (Test-Path $ModelPath -PathType Leaf) {
    $Info = Get-ArtifactVerification $ModelPath
    if ($Info) {
        Write-Host "Pinned model is already present and valid."
        Write-Verified $Info
        return
    }
    Write-Warning "Removing invalid final artifact before re-download: $ModelPath"
    Remove-Item $ModelPath -Force
}

if (Test-Path $PartialPath -PathType Leaf) {
    $PartialLength = (Get-Item $PartialPath).Length
    if ($PartialLength -gt [int64]$Artifact.bytes) {
        Write-Warning "Partial file is larger than the pinned artifact; deleting it."
        Remove-Item $PartialPath -Force
    } elseif ($PartialLength -eq [int64]$Artifact.bytes) {
        $Info = Get-ArtifactVerification $PartialPath
        if ($Info) {
            Move-Item $PartialPath $ModelPath -Force
            $Info.Path = $ModelPath
            Write-Verified $Info
            return
        }
        Write-Warning "Complete-sized partial file failed integrity verification; deleting it."
        Remove-Item $PartialPath -Force
    }
}

$ResolvedBackend = $Backend
if ($ResolvedBackend -eq "Auto") {
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) { $ResolvedBackend = "Curl" }
    elseif ((Get-Command hf.exe -ErrorAction SilentlyContinue) -or (Get-Command hf -ErrorAction SilentlyContinue)) { $ResolvedBackend = "Hf" }
    else { throw "No download backend is available. Windows 10/11 normally includes curl.exe." }
}

Write-Host "Downloading pinned Qwen3.8-27B artifact..."
Write-Host "  Repository: $($Artifact.repository)"
Write-Host "  Revision:   $($Artifact.revision)"
Write-Host "  File:       $($Artifact.filename)"
Write-Host "  Expected:   $([Math]::Round(([double]$Artifact.bytes / 1GB),2)) GiB"
Write-Host "  Backend:    $ResolvedBackend"

if ($ResolvedBackend -eq "Curl") {
    $Curl = Get-Command curl.exe -ErrorAction Stop
    $Url = "https://huggingface.co/$($Artifact.repository)/resolve/$($Artifact.revision)/$($Artifact.filename)?download=true"
    $CurlArgs = @("--location","--fail","--retry","5","--retry-delay","3")
    if (Test-Path $PartialPath -PathType Leaf) {
        $Existing = (Get-Item $PartialPath).Length
        Write-Host "Resuming partial download at $Existing bytes..."
        $CurlArgs += @("--continue-at","-")
    }
    $CurlArgs += @("--output",$PartialPath,$Url)
    & $Curl.Source @CurlArgs
    if ($LASTEXITCODE -ne 0) { throw "Pinned artifact download failed with curl exit code $LASTEXITCODE." }

    $Info = Get-ArtifactVerification $PartialPath -ThrowOnFailure
    Move-Item $PartialPath $ModelPath -Force
    $Info.Path = $ModelPath
    Write-Verified $Info
    return
}

$Hf = Get-Command hf.exe -ErrorAction SilentlyContinue
if (-not $Hf) { $Hf = Get-Command hf -ErrorAction SilentlyContinue }
if (-not $Hf) { throw "Hugging Face CLI was requested but is not installed." }
& $Hf.Source download ([string]$Artifact.repository) ([string]$Artifact.filename) --revision ([string]$Artifact.revision) --local-dir $ResolvedModelDir
if ($LASTEXITCODE -ne 0) { throw "Pinned artifact download failed with hf exit code $LASTEXITCODE." }

$Info = Get-ArtifactVerification $ModelPath -ThrowOnFailure
Write-Verified $Info
