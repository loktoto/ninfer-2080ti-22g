[CmdletBinding()]
param(
    [string]$InstallDir = "",
    [string]$ModelDir = "",
    [ValidateRange(1,65535)]
    [int]$Port = 8080,
    [ValidateRange(1024,262144)]
    [int]$MaxContext = 16384,
    [ValidateRange(-1,15)]
    [int]$Device = -1,
    [switch]$SkipModelDownload,
    [switch]$SkipPrerequisites,
    [switch]$NoShortcuts,
    [switch]$NoStart
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$PackageRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Get-DefaultInstallDir {
    if (Test-Path "D:\") { return "D:\AI\NInfer-SM75" }
    return (Join-Path $env:LOCALAPPDATA "NInfer-SM75")
}

function Get-DefaultModelDir([string]$ResolvedInstallDir) {
    if (Test-Path "D:\") { return "D:\AI\models\qwen" }
    return (Join-Path $ResolvedInstallDir "models")
}

function Resolve-NvidiaSmi {
    $Cmd = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if (-not $Cmd) { $Cmd = Get-Command nvidia-smi -ErrorAction SilentlyContinue }
    if ($Cmd) { return $Cmd.Source }
    $Fallback = Join-Path $env:ProgramFiles "NVIDIA Corporation\NVSMI\nvidia-smi.exe"
    if (Test-Path $Fallback -PathType Leaf) { return $Fallback }
    return $null
}

function Assert-ProductionGpu {
    $Smi = Resolve-NvidiaSmi
    if (-not $Smi) {
        throw "NVIDIA driver tools were not found. Install a current NVIDIA GeForce driver, reboot if required, then run START-HERE.bat again."
    }
    $Rows = @(& $Smi --query-gpu=index,name,memory.total,compute_cap,driver_version --format=csv,noheader,nounits)
    if ($LASTEXITCODE -ne 0 -or $Rows.Count -eq 0) { throw "nvidia-smi GPU query failed." }

    $Matches = @()
    foreach ($Row in $Rows) {
        $P = @($Row -split "," | ForEach-Object { $_.Trim() })
        if ($P.Count -lt 5) { continue }
        $Gpu = [pscustomobject]@{
            Index = [int]$P[0]
            Name = $P[1]
            VramMiB = [int]$P[2]
            ComputeCapability = $P[3]
            Driver = $P[4]
        }
        $DriverMajor = 0
        try { $DriverMajor = [int](($Gpu.Driver -split "\.")[0]) } catch {}
        if ($Gpu.Name -match "2080\s*Ti" -and $Gpu.ComputeCapability -eq "7.5" -and $Gpu.VramMiB -ge 20000 -and $DriverMajor -ge 580) {
            $Matches += $Gpu
        }
    }
    if ($Matches.Count -eq 0) {
        throw "No compatible target was detected. Required: RTX 2080 Ti, 20GB+ VRAM, compute capability 7.5, NVIDIA driver branch R580 or newer."
    }
    return $Matches
}

function Test-SourceChecksums {
    $Sums = Join-Path $PackageRoot "SHA256SUMS.txt"
    if (-not (Test-Path $Sums -PathType Leaf)) {
        throw "SHA256SUMS.txt is missing. Use an official packaged release, not a loose staging tree."
    }
    Write-Host "Verifying extracted package integrity..."
    $Listed = @{}
    $RootPrefix = [IO.Path]::GetFullPath($PackageRoot).TrimEnd("\") + "\"
    foreach ($Line in Get-Content $Sums) {
        if ([string]::IsNullOrWhiteSpace($Line)) { continue }
        if ($Line -notmatch "^([0-9a-fA-F]{64})\s{2}(.+)$") { throw "Malformed checksum line: $Line" }
        $Expected = $Matches[1].ToLowerInvariant()
        $RelativeUnix = $Matches[2].Replace("\","/")
        if ([IO.Path]::IsPathRooted($RelativeUnix) -or $RelativeUnix -match "(^|/)\.\.(/|$)") {
            throw "Unsafe checksum path: $RelativeUnix"
        }
        $Key = $RelativeUnix.ToLowerInvariant()
        if ($Listed.ContainsKey($Key)) { throw "Duplicate checksum path: $RelativeUnix" }
        $Listed[$Key] = $true

        $Relative = $RelativeUnix.Replace("/",[IO.Path]::DirectorySeparatorChar)
        $Path = [IO.Path]::GetFullPath((Join-Path $PackageRoot $Relative))
        if (-not $Path.StartsWith($RootPrefix,[StringComparison]::OrdinalIgnoreCase)) {
            throw "Checksum path escaped package root: $RelativeUnix"
        }
        if (-not (Test-Path $Path -PathType Leaf)) { throw "Package file is missing: $RelativeUnix" }
        $Actual = (Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($Actual -ne $Expected) { throw "Package integrity check failed: $RelativeUnix" }
    }

    $ActualFiles = @(Get-ChildItem $PackageRoot -Recurse -File | Where-Object {
        $_.FullName -ne $Sums
    } | ForEach-Object {
        $_.FullName.Substring($RootPrefix.Length).Replace("\","/").ToLowerInvariant()
    })
    foreach ($Relative in $ActualFiles) {
        if (-not $Listed.ContainsKey($Relative)) { throw "Unchecksummed file found in extracted package: $Relative" }
    }
    if ($Listed.Count -ne $ActualFiles.Count) {
        throw "Package checksum coverage mismatch: listed=$($Listed.Count), actual=$($ActualFiles.Count)."
    }
    Write-Host "Extracted package integrity passed."
}

function Ensure-VcRuntime {
    $RuntimeDll = Join-Path $env:WINDIR "System32\vcruntime140.dll"
    if (Test-Path $RuntimeDll -PathType Leaf) { return }
    if ($SkipPrerequisites) {
        throw "Microsoft Visual C++ 2015-2022 x64 runtime is missing and -SkipPrerequisites was requested."
    }
    $Winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $Winget) {
        throw "Microsoft Visual C++ 2015-2022 x64 runtime is missing and winget is unavailable. Install Microsoft.VCRedist.2015+.x64, then re-run."
    }
    Write-Host "Installing Microsoft Visual C++ 2015-2022 Redistributable (x64)..."
    & $Winget.Source install --id Microsoft.VCRedist.2015+.x64 --exact --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "VC++ Redistributable installation failed with exit code $LASTEXITCODE." }
    if (-not (Test-Path $RuntimeDll -PathType Leaf)) {
        throw "VC++ runtime installer completed but vcruntime140.dll is still unavailable. A reboot may be required."
    }
}

function Copy-PackageAtomically([string]$Destination) {
    $SourceFull = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
    $DestFull = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
    if ($SourceFull -eq $DestFull) {
        Write-Host "Portable/in-place installation selected."
        return $DestFull
    }

    $Parent = Split-Path $DestFull -Parent
    New-Item -ItemType Directory -Force -Path $Parent | Out-Null
    $Stage = "$DestFull.__new_$PID"
    $Backup = "$DestFull.__backup_$PID"
    $Preserve = Join-Path ([IO.Path]::GetTempPath()) ("ninfer-preserve-" + [guid]::NewGuid().ToString("N"))

    Remove-Item $Stage -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $Backup -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $Stage | Out-Null

    try {
        foreach ($Dir in @("bin","scripts","config","docs","install","launchers")) {
            $Src = Join-Path $PackageRoot $Dir
            if (-not (Test-Path $Src -PathType Container)) { throw "Required package directory is missing: $Dir" }
            Copy-Item $Src (Join-Path $Stage $Dir) -Recurse -Force
        }
        foreach ($File in @("README.md","LICENSE","BUILD-MANIFEST.json","SHA256SUMS.txt","README-FIRST.txt","START-HERE.bat")) {
            $Src = Join-Path $PackageRoot $File
            if (Test-Path $Src -PathType Leaf) { Copy-Item $Src (Join-Path $Stage $File) -Force }
        }

        if (Test-Path $DestFull -PathType Container) {
            $OldManager = Join-Path $DestFull "scripts\manage-installed-server.ps1"
            if (Test-Path $OldManager -PathType Leaf) {
                try { & $OldManager -Action Stop } catch { Write-Warning "Old server stop failed: $($_.Exception.Message)" }
            }
            New-Item -ItemType Directory -Force -Path $Preserve | Out-Null
            foreach ($Rel in @("config\user-settings.json","secrets\api-key.txt")) {
                $Old = Join-Path $DestFull $Rel
                if (Test-Path $Old -PathType Leaf) {
                    $Save = Join-Path $Preserve $Rel
                    New-Item -ItemType Directory -Force -Path (Split-Path $Save -Parent) | Out-Null
                    Copy-Item $Old $Save -Force
                }
            }
            Move-Item $DestFull $Backup
        }

        Move-Item $Stage $DestFull

        if (Test-Path $Preserve -PathType Container) {
            Get-ChildItem $Preserve -Recurse -File | ForEach-Object {
                $Rel = $_.FullName.Substring($Preserve.Length).TrimStart('\')
                $Target = Join-Path $DestFull $Rel
                New-Item -ItemType Directory -Force -Path (Split-Path $Target -Parent) | Out-Null
                Copy-Item $_.FullName $Target -Force
            }
        }

        Remove-Item $Backup -Recurse -Force -ErrorAction SilentlyContinue
        return $DestFull
    } catch {
        Remove-Item $Stage -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $DestFull) -and (Test-Path $Backup)) { Move-Item $Backup $DestFull }
        throw
    } finally {
        Remove-Item $Preserve -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function New-Shortcut([string]$Path,[string]$Target,[string]$WorkingDirectory,[string]$Description) {
    $Shell = New-Object -ComObject WScript.Shell
    $Shortcut = $Shell.CreateShortcut($Path)
    $Shortcut.TargetPath = $Target
    $Shortcut.WorkingDirectory = $WorkingDirectory
    $Shortcut.Description = $Description
    $Shortcut.Save()
}

if (-not [Environment]::Is64BitOperatingSystem) { throw "NInfer SM75 requires 64-bit Windows." }
if (Test-Path (Join-Path $PackageRoot "INSTALL-STATE.json") -PathType Leaf) {
    throw "START-HERE must be run from a clean extracted release package. This directory is already an installed runtime; use launchers\Repair-NInfer.bat instead."
}
if (-not (Test-Path (Join-Path $PackageRoot "bin\ninfer.exe") -PathType Leaf)) {
    throw "This installer must be run from an extracted NInfer Windows SM75 release package."
}
if (-not (Test-Path (Join-Path $PackageRoot "bin\ninfer-serve.exe") -PathType Leaf)) {
    throw "Package is incomplete: bin\ninfer-serve.exe is missing."
}

$BuildManifestPath = Join-Path $PackageRoot "BUILD-MANIFEST.json"
if (-not (Test-Path $BuildManifestPath -PathType Leaf)) {
    throw "BUILD-MANIFEST.json is missing. Use an official packaged release."
}
$BuildManifest = Get-Content $BuildManifestPath -Raw | ConvertFrom-Json
if ($BuildManifest.artifact_type -ne "ninfer-windows-sm75-runtime" -or
    $BuildManifest.build_profile -ne "qwen3.8-27b-sm75" -or
    $BuildManifest.cuda_arch -ne "sm_75" -or
    $BuildManifest.cuda_runtime_linkage -ne "static" -or
    [int]$BuildManifest.minimum_nvidia_driver_branch -lt 580) {
    throw "BUILD-MANIFEST.json does not describe the supported Qwen3.8 / SM75 static-runtime product."
}
$EmbeddedLock = Join-Path $PackageRoot "config\windows-sm75-artifacts.json"
$EmbeddedLockHash = (Get-FileHash $EmbeddedLock -Algorithm SHA256).Hash.ToLowerInvariant()
if ($EmbeddedLockHash -ne ([string]$BuildManifest.artifact_lock_sha256).ToLowerInvariant()) {
    throw "Embedded model lock hash does not match BUILD-MANIFEST.json."
}

Write-Host "============================================================"
Write-Host " NInfer Qwen3.8-27B / RTX 2080 Ti 22GB - One-click installer"
Write-Host "============================================================"
Write-Host ""

Test-SourceChecksums
$Gpus = Assert-ProductionGpu
Ensure-VcRuntime

if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = Get-DefaultInstallDir }
$InstallDir = [IO.Path]::GetFullPath($InstallDir)
if ([string]::IsNullOrWhiteSpace($ModelDir)) { $ModelDir = Get-DefaultModelDir $InstallDir }
$ModelDir = [IO.Path]::GetFullPath($ModelDir)

Write-Host ""
Write-Host "Target:"
Write-Host "  Runtime: $InstallDir"
Write-Host "  Model:   $ModelDir"
Write-Host "  API:     http://127.0.0.1:$Port/v1"
Write-Host ""

if (-not $SkipModelDownload) {
    $ExpectedModelBytes = [int64](Get-Content (Join-Path $PackageRoot "config\windows-sm75-artifacts.json") -Raw | ConvertFrom-Json).artifacts.qwen3_8_27b.bytes
    $PartialModel = Join-Path $ModelDir "qwen3_8_27b.ninfer.partial"
    $RemainingModelBytes = $ExpectedModelBytes
    if (Test-Path $PartialModel -PathType Leaf) {
        $PartialBytes = (Get-Item $PartialModel).Length
        if ($PartialBytes -gt 0 -and $PartialBytes -lt $ExpectedModelBytes) {
            $RemainingModelBytes = $ExpectedModelBytes - $PartialBytes
        }
    }
    $SafetyBytes = [int64](2GB)
    $ModelRoot = [IO.Path]::GetPathRoot($ModelDir)
    if (-not [string]::IsNullOrWhiteSpace($ModelRoot)) {
        try {
            $Drive = New-Object -TypeName System.IO.DriveInfo -ArgumentList $ModelRoot
            $RequiredFree = $RemainingModelBytes + $SafetyBytes
            if ($Drive.AvailableFreeSpace -lt $RequiredFree) {
                throw "Insufficient free space on $ModelRoot. Need at least $([Math]::Ceiling($RequiredFree / 1GB)) GiB free for the pinned model plus safety margin; available $([Math]::Round($Drive.AvailableFreeSpace / 1GB,2)) GiB."
            }
            Write-Host "  Free space: $([Math]::Round($Drive.AvailableFreeSpace / 1GB,2)) GiB (preflight passed)"
        } catch {
            if ($_.Exception.Message -like "Insufficient free space*") { throw }
            Write-Warning "Could not determine model-drive free space: $($_.Exception.Message)"
        }
    }
}

$InstalledRoot = Copy-PackageAtomically $InstallDir
[Environment]::SetEnvironmentVariable("NINFER_SM75_HOME",$InstalledRoot,"User")

$Downloader = Join-Path $InstalledRoot "scripts\download-qwen38-windows-sm75.ps1"
$Wizard = Join-Path $InstalledRoot "install\first-run-wizard.ps1"
if (-not $SkipModelDownload) {
    & $Downloader -ModelDir $ModelDir
    & $Wizard -ModelDir $ModelDir -Port $Port -MaxContext $MaxContext -Device $Device -NoModelHash
} else {
    & $Wizard -ModelDir $ModelDir -Port $Port -MaxContext $MaxContext -Device $Device
}

$Manifest = $null
$ManifestPath = Join-Path $InstalledRoot "BUILD-MANIFEST.json"
if (Test-Path $ManifestPath -PathType Leaf) {
    try { $Manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json } catch {}
}
$SourceGitSha = "development-staging"
if ($Manifest -and -not [string]::IsNullOrWhiteSpace([string]$Manifest.git_sha)) {
    $SourceGitSha = [string]$Manifest.git_sha
}
$State = [ordered]@{
    schema_version = 1
    installed_utc = [DateTime]::UtcNow.ToString("o")
    install_root = $InstalledRoot
    model_dir = $ModelDir
    source_git_sha = $SourceGitSha
    profile = "qwen3.8-27b-sm75"
}
$State | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $InstalledRoot "INSTALL-STATE.json") -Encoding UTF8

if (-not $NoShortcuts) {
    $Desktop = [Environment]::GetFolderPath("Desktop")
    $StartMenu = Join-Path ([Environment]::GetFolderPath("Programs")) "NInfer SM75"
    New-Item -ItemType Directory -Force -Path $StartMenu | Out-Null

    New-Shortcut (Join-Path $Desktop "NInfer SM75.lnk") (Join-Path $InstalledRoot "launchers\Start-NInfer.bat") $InstalledRoot "Start NInfer Qwen3.8-27B"
    New-Shortcut (Join-Path $StartMenu "Start NInfer.lnk") (Join-Path $InstalledRoot "launchers\Start-NInfer.bat") $InstalledRoot "Start conservative NInfer server"
    New-Shortcut (Join-Path $StartMenu "Start NInfer MTP.lnk") (Join-Path $InstalledRoot "launchers\Start-NInfer-MTP.bat") $InstalledRoot "Start NInfer with MTP3"
    New-Shortcut (Join-Path $StartMenu "Start NInfer Vision.lnk") (Join-Path $InstalledRoot "launchers\Start-NInfer-Vision.bat") $InstalledRoot "Start NInfer with Vision"
    New-Shortcut (Join-Path $StartMenu "Start NInfer MTP + Vision.lnk") (Join-Path $InstalledRoot "launchers\Start-NInfer-MTP-Vision.bat") $InstalledRoot "Start NInfer with MTP3 and Vision"
    New-Shortcut (Join-Path $StartMenu "Configure NInfer.lnk") (Join-Path $InstalledRoot "launchers\Configure-NInfer.bat") $InstalledRoot "Configure NInfer"
    New-Shortcut (Join-Path $StartMenu "Check NInfer.lnk") (Join-Path $InstalledRoot "launchers\Check-NInfer.bat") $InstalledRoot "Verify NInfer installation"
    New-Shortcut (Join-Path $StartMenu "Open NInfer Logs.lnk") (Join-Path $InstalledRoot "launchers\Open-NInfer-Logs.bat") $InstalledRoot "Open NInfer logs"
    New-Shortcut (Join-Path $StartMenu "Repair NInfer.lnk") (Join-Path $InstalledRoot "launchers\Repair-NInfer.bat") $InstalledRoot "Repair NInfer installation"
    New-Shortcut (Join-Path $StartMenu "Stop NInfer.lnk") (Join-Path $InstalledRoot "launchers\Stop-NInfer.bat") $InstalledRoot "Stop NInfer"
    New-Shortcut (Join-Path $StartMenu "Uninstall NInfer.lnk") (Join-Path $InstalledRoot "launchers\Uninstall-NInfer.bat") $InstalledRoot "Uninstall NInfer runtime"
}

$Verifier = Join-Path $InstalledRoot "install\verify-installation.ps1"
if (Test-Path $Verifier -PathType Leaf) { & $Verifier -Fast }

if (-not $NoStart) {
    & (Join-Path $InstalledRoot "scripts\manage-installed-server.ps1") -Action Start -Mode Base
}

Write-Host ""
Write-Host "============================================================"
Write-Host " Installation complete"
Write-Host "============================================================"
Write-Host "Runtime: $InstalledRoot"
Write-Host "Model:   $ModelDir"
Write-Host "API:     http://127.0.0.1:$Port/v1"
Write-Host ""
Write-Host "Daily use:"
Write-Host "  Start:     $InstalledRoot\launchers\Start-NInfer.bat"
Write-Host "  MTP:       $InstalledRoot\launchers\Start-NInfer-MTP.bat"
Write-Host "  Vision:    $InstalledRoot\launchers\Start-NInfer-Vision.bat"
Write-Host "  Stop:      $InstalledRoot\launchers\Stop-NInfer.bat"
Write-Host "  Configure: $InstalledRoot\launchers\Configure-NInfer.bat"
