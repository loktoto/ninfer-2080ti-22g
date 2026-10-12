$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Installer = Join-Path $PSScriptRoot '..\install\install-ninfer-sm75.ps1'
$Tokens = $null
$ParseErrors = $null
$Ast = [Management.Automation.Language.Parser]::ParseFile($Installer, [ref]$Tokens, [ref]$ParseErrors)
if ($ParseErrors.Count) { throw 'Installer parse failed.' }
$Function = $Ast.Find({ param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Assert-ProductionGpu' }, $true)
if (-not $Function) { throw 'Production GPU preflight function not found.' }
. ([scriptblock]::Create($Function.Extent.Text))

# Exercise the actual preflight against inventory fixtures. These are host-only
# tests and do not provide physical GPU or inference qualification evidence.
function Resolve-NvidiaSmi { return 'Invoke-InventoryFixture' }
function Invoke-InventoryFixture {
    $global:LASTEXITCODE = $script:InventoryExit
    return $script:InventoryRows
}
$Cases = @(
    @{ Name='compatible target'; Rows=@('0, NVIDIA GeForce RTX 2080 Ti, 22528, 7.5, 616.56'); Indices=@(0) },
    @{ Name='mixed inventory'; Rows=@('0, NVIDIA GeForce RTX 3070, 8192, 8.6, 616.56','1, NVIDIA GeForce RTX 2080 Ti, 22528, 7.5, 616.56'); Indices=@(1) },
    @{ Name='multiple targets'; Rows=@('0, NVIDIA GeForce RTX 2080 Ti, 22528, 7.5, 616.56','1, NVIDIA GeForce RTX 2080 Ti, 22528, 7.5, 616.56'); Indices=@(0,1) },
    @{ Name='stock VRAM rejected'; Rows=@('0, NVIDIA GeForce RTX 2080 Ti, 11264, 7.5, 616.56'); Indices=@() },
    @{ Name='wrong architecture rejected'; Rows=@('0, NVIDIA GeForce RTX 2080 Ti, 22528, 8.6, 616.56'); Indices=@() },
    @{ Name='wrong model rejected'; Rows=@('0, NVIDIA GeForce RTX 3080, 24576, 7.5, 616.56'); Indices=@() },
    @{ Name='old driver rejected'; Rows=@('0, NVIDIA GeForce RTX 2080 Ti, 22528, 7.5, 579.99'); Indices=@() }
)
foreach ($Case in $Cases) {
    $script:InventoryRows = $Case.Rows
    $script:InventoryExit = 0
    if ($Case.Indices.Count -eq 0) {
        $Rejected = $false
        try { Assert-ProductionGpu | Out-Null } catch {
            if ($_.Exception.Message -notlike 'No compatible target*') { throw }
            $Rejected = $true
        }
        if (-not $Rejected) { throw "Expected rejection: $($Case.Name)" }
    } else {
        $Actual = @(Assert-ProductionGpu)
        if (($Actual.Index -join ',') -ne ($Case.Indices -join ',')) { throw "Incorrect target selection: $($Case.Name)" }
    }
    Write-Host "PASS GPU preflight fixture: $($Case.Name)"
}
$script:InventoryRows = @('0, NVIDIA GeForce RTX 2080 Ti, 22528, 7.5, 616.56')
$script:InventoryExit = 1
$Rejected = $false
try { Assert-ProductionGpu | Out-Null } catch {
    if ($_.Exception.Message -ne 'nvidia-smi GPU query failed.') { throw }
    $Rejected = $true
}
if (-not $Rejected) { throw 'Failed inventory query was accepted.' }
Write-Host 'PASS GPU preflight fixture: failed query rejected'
