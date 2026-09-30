[CmdletBinding()]
param(
    [string]$InstallDir = "out\windows-sm75",
    [string]$DistDir = "dist"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$InstallPath = Join-Path $RepoRoot $InstallDir
$DistPath = Join-Path $RepoRoot $DistDir
if (-not (Test-Path $InstallPath)) { throw "Install tree not found: $InstallPath" }

$gitSha = (& git.exe -C $RepoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or -not $gitSha) { throw "Unable to resolve git commit." }
$shortSha = $gitSha.Substring(0,12)
$PackageName = "ninfer-windows-sm75-$shortSha"
$StagePath = Join-Path $DistPath $PackageName
$ZipPath = Join-Path $DistPath "$PackageName.zip"

if (Test-Path $StagePath) { Remove-Item -Recurse -Force $StagePath }
if (Test-Path $ZipPath) { Remove-Item -Force $ZipPath }
New-Item -ItemType Directory -Force -Path $DistPath | Out-Null
Copy-Item $InstallPath $StagePath -Recurse -Force

$DocsDir = Join-Path $StagePath "docs"
New-Item -ItemType Directory -Force -Path $DocsDir | Out-Null
Copy-Item (Join-Path $RepoRoot "README.md") (Join-Path $StagePath "README.md") -Force
Copy-Item (Join-Path $RepoRoot "LICENSE") (Join-Path $StagePath "LICENSE") -Force
Copy-Item (Join-Path $RepoRoot "docs\windows-sm75.md") (Join-Path $DocsDir "windows-sm75.md") -Force

$cudaVersion = $null
$nvcc = Get-Command nvcc.exe -ErrorAction SilentlyContinue
if ($nvcc) {
    $versionOutput = (& $nvcc.Source --version | Out-String)
    if ($LASTEXITCODE -eq 0 -and $versionOutput -match "release\s+([0-9]+\.[0-9]+)") {
        $cudaVersion = $Matches[1]
    }
}

$manifest = [ordered]@{
    artifact_type = "ninfer-windows-sm75-runtime"
    schema_version = 1
    git_sha = $gitSha
    cuda_arch = "sm_75"
    target_gpu = "NVIDIA RTX 2080 Ti / Turing TU102"
    configuration = "Release"
    cuda_toolkit = $cudaVersion
    created_utc = [DateTime]::UtcNow.ToString("o")
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $StagePath "BUILD-MANIFEST.json") -Encoding UTF8

$checksumPath = Join-Path $StagePath "SHA256SUMS.txt"
$entries = Get-ChildItem $StagePath -Recurse -File |
    Where-Object { $_.FullName -ne $checksumPath } |
    Sort-Object FullName |
    ForEach-Object {
        $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $relative = [IO.Path]::GetRelativePath($StagePath, $_.FullName).Replace("\","/")
        "$hash  $relative"
    }
$entries | Set-Content $checksumPath -Encoding ASCII

Compress-Archive -Path $StagePath -DestinationPath $ZipPath -CompressionLevel Optimal
$zipHash = (Get-FileHash $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content "$ZipPath.sha256" "$zipHash  $([IO.Path]::GetFileName($ZipPath))" -Encoding ASCII

Write-Host "Package created:"
Write-Host "  $ZipPath"
Write-Host "  $ZipPath.sha256"
