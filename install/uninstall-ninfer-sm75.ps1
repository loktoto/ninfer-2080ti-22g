[CmdletBinding()]
param(
    [switch]$RemoveModel,
    [switch]$KeepShortcuts
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$SettingsPath = Join-Path $Root "config\user-settings.json"
$ModelPath = $null
if (Test-Path $SettingsPath -PathType Leaf) {
    try { $ModelPath = [string](Get-Content $SettingsPath -Raw | ConvertFrom-Json).model_path } catch {}
}

$Manager = Join-Path $Root "scripts\manage-installed-server.ps1"
if (Test-Path $Manager -PathType Leaf) {
    try { & $Manager -Action Stop } catch { Write-Warning "Server stop failed: $($_.Exception.Message)" }
}

if (-not $KeepShortcuts) {
    $DesktopLink = Join-Path ([Environment]::GetFolderPath("Desktop")) "NInfer SM75.lnk"
    $StartMenu = Join-Path ([Environment]::GetFolderPath("Programs")) "NInfer SM75"
    Remove-Item $DesktopLink -Force -ErrorAction SilentlyContinue
    Remove-Item $StartMenu -Recurse -Force -ErrorAction SilentlyContinue
}

$Home = [Environment]::GetEnvironmentVariable("NINFER_SM75_HOME","User")
if ($Home -and ([IO.Path]::GetFullPath($Home).TrimEnd('\') -eq [IO.Path]::GetFullPath($Root).TrimEnd('\'))) {
    [Environment]::SetEnvironmentVariable("NINFER_SM75_HOME",$null,"User")
}

if ($RemoveModel -and $ModelPath -and (Test-Path $ModelPath -PathType Leaf)) {
    Write-Host "Removing model: $ModelPath"
    Remove-Item $ModelPath -Force
} elseif ($ModelPath) {
    Write-Host "Keeping model: $ModelPath"
}

Write-Host "Scheduling removal of runtime: $Root"
$Cmd = 'timeout /t 2 /nobreak >nul & rmdir /s /q "' + $Root + '"'
Start-Process -FilePath "cmd.exe" -ArgumentList "/d","/c",$Cmd -WindowStyle Hidden
Write-Host "Uninstall scheduled. This window can close."
