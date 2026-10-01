[CmdletBinding()]
param(
    [string]$InstallDir = "out\windows-sm75",
    [switch]$RequireDependencyAudit
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
if (-not (Test-Path $BinDir -PathType Container)) {
    throw "Runtime bin directory not found: $BinDir"
}
$BinDir = (Resolve-Path $BinDir).Path

function Get-PeDependencies([string]$FilePath, [string]$DumpbinPath) {
    $Output = & $DumpbinPath /NOLOGO /DEPENDENTS $FilePath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "dumpbin dependency inspection failed for $FilePath with exit code $LASTEXITCODE."
    }

    $Dependencies = @()
    foreach ($Line in $Output) {
        $Text = [string]$Line
        if ($Text -match "^\s+([A-Za-z0-9_.+\-]+\.dll)\s*$") {
            $Dependencies += $Matches[1]
        }
    }
    return @($Dependencies | Sort-Object -Unique)
}

function Test-SystemDependency([string]$Name) {
    if ($Name -match "^(?i:api-ms-win-|ext-ms-win-)") { return $true }
    if ($Name -ieq "nvcuda.dll") { return $true }

    $System32 = Join-Path $env:SystemRoot "System32"
    if (Test-Path (Join-Path $System32 $Name) -PathType Leaf) { return $true }

    if ($Name -match "^(?i:msvcp[0-9].*\.dll|vcruntime[0-9].*\.dll|concrt[0-9].*\.dll|ucrtbase\.dll)$") {
        return $true
    }
    return $false
}

function Invoke-DependencyAudit {
    $Dumpbin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
    if (-not $Dumpbin) {
        if ($RequireDependencyAudit) {
            throw "dumpbin.exe was not found; dependency audit is required for this verification."
        }
        Write-Warning "dumpbin.exe not found; skipping PE dependency audit."
        return
    }

    $PeFiles = @(Get-ChildItem $BinDir -File | Where-Object {
        $_.Extension -ieq ".exe" -or $_.Extension -ieq ".dll"
    })
    if ($PeFiles.Count -eq 0) { throw "No PE runtime files found in $BinDir." }

    $Packaged = @{}
    foreach ($File in $PeFiles) { $Packaged[$File.Name.ToLowerInvariant()] = $true }

    $Missing = New-Object System.Collections.Generic.List[string]
    $CudaToolkitRuntime = New-Object System.Collections.Generic.List[string]
    foreach ($File in $PeFiles) {
        foreach ($Dependency in (Get-PeDependencies $File.FullName $Dumpbin.Source)) {
            $Lower = $Dependency.ToLowerInvariant()
            if ($Lower -match "^cudart64_.*\.dll$") {
                $CudaToolkitRuntime.Add("$($File.Name) -> $Dependency")
            }
            if ($Packaged.ContainsKey($Lower)) { continue }
            if (Test-SystemDependency $Dependency) { continue }
            $Missing.Add("$($File.Name) -> $Dependency")
        }
    }

    if ($CudaToolkitRuntime.Count -ne 0) {
        throw "Static CUDA runtime policy violated; CUDA Toolkit runtime DLL dependencies found: $($CudaToolkitRuntime -join '; ')"
    }
    if ($Missing.Count -ne 0) {
        throw "Unclosed package dependencies found: $($Missing -join '; ')"
    }
    Write-Host "PE dependency closure verification passed."
}

function Invoke-HelpCheck([string]$ExePath) {
    if (-not (Test-Path $ExePath -PathType Leaf)) { throw "Missing executable: $ExePath" }
    Write-Host "Launching $([IO.Path]::GetFileName($ExePath)) --help with isolated PATH ..."
    & $ExePath --help | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "$ExePath --help failed with exit code $LASTEXITCODE. This usually indicates a missing DLL or startup regression."
    }
}

Invoke-DependencyAudit

$PreviousPath = $env:PATH
try {
    $System32 = Join-Path $env:SystemRoot "System32"
    $env:PATH = "$BinDir;$System32;$env:SystemRoot"

    Invoke-HelpCheck (Join-Path $BinDir "ninfer.exe")
    Invoke-HelpCheck (Join-Path $BinDir "ninfer-serve.exe")
} finally {
    $env:PATH = $PreviousPath
}

Write-Host "Binary startup and runtime dependency verification passed."
