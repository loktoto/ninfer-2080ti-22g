[CmdletBinding()]
param(
    [string]$PackageRoot = "",
    [switch]$DownloadModel,
    [switch]$Restart
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

if (-not [string]::IsNullOrWhiteSpace($PackageRoot)) {
    $PackageRoot = (Resolve-Path $PackageRoot -ErrorAction Stop).Path
    $Installer = Join-Path $PackageRoot "install\install-ninfer-sm75.ps1"
    if (-not (Test-Path $Installer -PathType Leaf)) { throw "Installer not found under package root: $Installer" }
    $Settings = $null
    $SettingsPath = Join-Path $Root "config\user-settings.json"
    if (Test-Path $SettingsPath -PathType Leaf) { $Settings = Get-Content $SettingsPath -Raw | ConvertFrom-Json }
    $Args = @("-InstallDir",$Root,"-NoStart")
    if ($Settings) {
        $Args += @("-ModelDir",[string]$Settings.model_dir,"-Port",([int]$Settings.port).ToString(),"-MaxContext",([int]$Settings.max_context).ToString(),"-Device",([int]$Settings.device).ToString())
    }
    if (-not $DownloadModel) { $Args += "-SkipModelDownload" }
    & $Installer @Args
} else {
    $SettingsPath = Join-Path $Root "config\user-settings.json"
    if (Test-Path $SettingsPath -PathType Leaf) {
        $S = Get-Content $SettingsPath -Raw | ConvertFrom-Json
        $WizardArgs = @("-ModelDir",[string]$S.model_dir,"-Port",([int]$S.port).ToString(),"-MaxContext",([int]$S.max_context).ToString(),"-Device",([int]$S.device).ToString())
        if ($DownloadModel) { $WizardArgs += "-DownloadModel" }
        & (Join-Path $Root "install\first-run-wizard.ps1") @WizardArgs
    } else {
        & (Join-Path $Root "install\first-run-wizard.ps1") -DownloadModel:$DownloadModel
    }
}

& (Join-Path $Root "install\verify-installation.ps1") -Full
if ($Restart) {
    & (Join-Path $Root "scripts\manage-installed-server.ps1") -Action Restart -Mode Base
}
Write-Host "Repair completed."
