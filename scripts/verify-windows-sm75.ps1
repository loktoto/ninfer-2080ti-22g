[CmdletBinding()]
param(
    [string]$InstallDir = "out\windows-sm75"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$PackagedBin = Join-Path $RepoRoot "bin"
if (Test-Path (Join-Path $PackagedBin "ninfer.exe")) {
    $BinDir = $PackagedBin
} else {
    $InstallPath = Join-Path $RepoRoot $InstallDir
    $BinDir = Join-Path $InstallPath "bin"
}

function Invoke-HelpCheck([string]$ExePath) {
    if (-not (Test-Path $ExePath)) { throw "Missing executable: $ExePath" }
    Write-Host "Launching $([IO.Path]::GetFileName($ExePath)) --help ..."
    & $ExePath --help | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "$ExePath --help failed with exit code $LASTEXITCODE. This usually indicates a missing DLL or startup regression."
    }
}

Invoke-HelpCheck (Join-Path $BinDir "ninfer.exe")
Invoke-HelpCheck (Join-Path $BinDir "ninfer-serve.exe")

Write-Host "Binary startup verification passed."
