[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Exercise the real installer copy function using small, disposable fixtures.
# The test does not require CUDA, a model download, elevation or a physical GPU.
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$InstallerPath = Join-Path $RepoRoot 'install\install-ninfer-sm75.ps1'
$Tokens = $null
$ParseErrors = $null
$Ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $InstallerPath, [ref]$Tokens, [ref]$ParseErrors
)
if ($ParseErrors.Count -ne 0) { throw "Installer has PowerShell parse errors." }
$Functions = @($Ast.FindAll({
    param($Node)
    $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $Node.Name -eq 'Copy-PackageAtomically'
}, $true))
if ($Functions.Count -ne 1) {
    throw "Expected exactly one Copy-PackageAtomically definition."
}
. ([scriptblock]::Create($Functions[0].Extent.Text))

function Write-FixtureFile([string]$Path, [string]$Value) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
    [System.IO.File]::WriteAllText($Path, $Value)
}
function Assert-FixtureFile([string]$Path, [string]$Expected) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing test file: $Path"
    }
    $Actual = [System.IO.File]::ReadAllText($Path)
    if ($Actual -cne $Expected) {
        throw "Test file contents changed unexpectedly: $Path"
    }
}
function Set-UpFixture([string]$Case, [bool]$Conflict) {
    $CaseRoot = Join-Path $TestRoot $Case
    $script:PackageRoot = Join-Path $CaseRoot 'package'
    $Destination = Join-Path $CaseRoot 'runtime'
    Write-FixtureFile (Join-Path $PackageRoot 'bin\ninfer.exe') 'new executable'
    Write-FixtureFile (Join-Path $PackageRoot 'config\production-defaults.json') 'new config'
    Write-FixtureFile (Join-Path $PackageRoot 'scripts\run-server.ps1') 'new runtime'
    Write-FixtureFile (Join-Path $PackageRoot 'README-FIRST.txt') 'new readme'
    Write-FixtureFile (Join-Path $Destination 'bin\ninfer.exe') 'old executable'
    Write-FixtureFile (Join-Path $Destination 'models\qwen3_8_27b.ninfer') 'existing pinned model fixture'
    Write-FixtureFile (Join-Path $Destination 'config\user-settings.json') 'user settings'
    Write-FixtureFile (Join-Path $Destination 'secrets\api-key.txt') 'protected key fixture'
    $Dirs = @('bin', 'config', 'scripts')
    if ($Conflict) {
        Write-FixtureFile (Join-Path $PackageRoot 'models\collision.txt') 'conflicting package model'
        $Dirs += 'models'
    }
    $script:DistributionContract = [pscustomobject]@{
        installer_copy_directories = $Dirs
        installer_root_files = @('README-FIRST.txt')
    }
    return $Destination
}

$TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('ninfer-sm75-upgrade-test-' +
    [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $TestRoot | Out-Null
try {
    $Success = Set-UpFixture 'success' $false
    $Result = Copy-PackageAtomically $Success
    if ([IO.Path]::GetFullPath($Result) -ne [IO.Path]::GetFullPath($Success)) {
        throw 'Unexpected installed runtime location.'
    }
    Assert-FixtureFile (Join-Path $Success 'bin\ninfer.exe') 'new executable'
    Assert-FixtureFile (Join-Path $Success 'models\qwen3_8_27b.ninfer') 'existing pinned model fixture'
    Assert-FixtureFile (Join-Path $Success 'config\user-settings.json') 'user settings'
    Assert-FixtureFile (Join-Path $Success 'secrets\api-key.txt') 'protected key fixture'
    if (@(Get-ChildItem (Split-Path $Success -Parent) -Directory |
        Where-Object { $_.Name -like 'runtime.__backup_*' }).Count -ne 0) {
        throw 'Successful upgrade left the old runtime backup behind.'
    }
    Write-Host '[PASS] Upgrade retained the local model, settings, and key.'

    $Failure = Set-UpFixture 'rollback' $true
    $FailedAsExpected = $false
    try {
        [void](Copy-PackageAtomically $Failure)
    } catch {
        if ($_.Exception.Message -notlike '*refusing to overwrite the installed model*') {
            throw
        }
        $FailedAsExpected = $true
    }
    if (-not $FailedAsExpected) {
        throw 'Expected a model-path collision to fail closed.'
    }
    Assert-FixtureFile (Join-Path $Failure 'bin\ninfer.exe') 'old executable'
    Assert-FixtureFile (Join-Path $Failure 'models\qwen3_8_27b.ninfer') 'existing pinned model fixture'
    Assert-FixtureFile (Join-Path $Failure 'config\user-settings.json') 'user settings'
    Assert-FixtureFile (Join-Path $Failure 'secrets\api-key.txt') 'protected key fixture'
    if (@(Get-ChildItem (Split-Path $Failure -Parent) -Directory |
        Where-Object { $_.Name -like 'runtime.__backup_*' -or
                        $_.Name -like 'runtime.__new_*' }).Count -ne 0) {
        throw 'Failed upgrade left staging or backup directories behind.'
    }
    Write-Host '[PASS] Failed upgrade restored the entire original runtime.'
} finally {
    Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
}
