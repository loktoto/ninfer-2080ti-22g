[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$OutputPath,
    [Parameter(Mandatory=$true)]
    [string]$VcpkgRoot,
    [Parameter(Mandatory=$true)]
    [string]$GitSha,
    [string]$CudaVersion = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$StatusPath = Join-Path $VcpkgRoot "installed\vcpkg\status"
if (-not (Test-Path $StatusPath -PathType Leaf)) {
    throw "vcpkg status database not found: $StatusPath"
}

function Convert-ParagraphToMap([string[]]$Lines) {
    $Map = @{}
    foreach ($Line in $Lines) {
        if ($Line -match "^([^:]+):\s*(.*)$") {
            $Map[$Matches[1]] = $Matches[2]
        }
    }
    return $Map
}

$Raw = Get-Content $StatusPath
$Paragraphs = New-Object System.Collections.Generic.List[object]
$Current = New-Object System.Collections.Generic.List[string]
foreach ($Line in $Raw) {
    if ([string]::IsNullOrWhiteSpace($Line)) {
        if ($Current.Count -gt 0) {
            $Paragraphs.Add((Convert-ParagraphToMap $Current.ToArray()))
            $Current.Clear()
        }
    } else {
        $Current.Add([string]$Line)
    }
}
if ($Current.Count -gt 0) {
    $Paragraphs.Add((Convert-ParagraphToMap $Current.ToArray()))
}

$Seen = @{}
$Components = New-Object System.Collections.Generic.List[object]
foreach ($Entry in $Paragraphs) {
    if (-not $Entry.ContainsKey("Package") -or -not $Entry.ContainsKey("Version")) { continue }
    if ($Entry.ContainsKey("Status") -and $Entry["Status"] -notmatch "install ok installed") { continue }

    $Name = [string]$Entry["Package"]
    $Version = [string]$Entry["Version"]
    $Feature = if ($Entry.ContainsKey("Feature")) { [string]$Entry["Feature"] } else { "core" }
    $Arch = if ($Entry.ContainsKey("Architecture")) { [string]$Entry["Architecture"] } else { "unknown" }
    $Key = "$Name|$Version|$Feature|$Arch"
    if ($Seen.ContainsKey($Key)) { continue }
    $Seen[$Key] = $true

    $BomRef = "pkg:vcpkg/$Name@$Version?feature=$Feature&triplet=$Arch"
    $Components.Add([ordered]@{
        type = "library"
        name = $Name
        version = $Version
        "bom-ref" = $BomRef
        properties = @(
            [ordered]@{ name = "ninfer:vcpkg:feature"; value = $Feature },
            [ordered]@{ name = "ninfer:vcpkg:triplet"; value = $Arch }
        )
    })
}

if (-not [string]::IsNullOrWhiteSpace($CudaVersion)) {
    $Components.Add([ordered]@{
        type = "library"
        name = "NVIDIA CUDA Runtime"
        version = $CudaVersion
        "bom-ref" = "ninfer:cuda-runtime:$CudaVersion:sm75:static"
        properties = @(
            [ordered]@{ name = "ninfer:linkage"; value = "static" },
            [ordered]@{ name = "ninfer:target_arch"; value = "sm_75" }
        )
    })
}

$Bom = [ordered]@{
    bomFormat = "CycloneDX"
    specVersion = "1.5"
    version = 1
    metadata = [ordered]@{
        timestamp = [DateTime]::UtcNow.ToString("o")
        component = [ordered]@{
            type = "application"
            name = "ninfer-windows-sm75"
            version = $GitSha
            "bom-ref" = "ninfer:windows-sm75:$GitSha"
            properties = @(
                [ordered]@{ name = "ninfer:cuda_arch"; value = "sm_75" },
                [ordered]@{ name = "ninfer:cuda_runtime_linkage"; value = "static" },
                [ordered]@{ name = "ninfer:build_profile"; value = "qwen3.8-27b-sm75" }
            )
        }
    }
    components = @($Components)
}

$Parent = Split-Path $OutputPath -Parent
if ($Parent) { New-Item -ItemType Directory -Force -Path $Parent | Out-Null }
$Bom | ConvertTo-Json -Depth 12 | Set-Content $OutputPath -Encoding UTF8

Write-Host "CycloneDX SBOM written: $OutputPath"
Write-Host "  Components: $($Components.Count)"
