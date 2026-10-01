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

$Dumpbin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
if ($Dumpbin) {
    foreach ($ExeName in @("ninfer.exe","ninfer-serve.exe")) {
        $ExePath = Join-Path $BinDir $ExeName
        $Dependencies = (& $Dumpbin.Source /DEPENDENTS $ExePath | Out-String)
        if ($LASTEXITCODE -ne 0) { throw "dumpbin dependency audit failed for $ExeName." }
        if ($Dependencies -match "cudart64_[0-9]+\.dll") {
            throw "$ExeName has a dynamic CUDA runtime dependency; Windows production package requires static cudart."
        }
    }
    Write-Host "CUDA runtime dependency audit passed (no dynamic cudart DLL import)."
}

Write-Host "Binary startup verification passed."
