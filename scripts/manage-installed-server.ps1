[CmdletBinding()]
param(
    [ValidateSet("Start","Stop","Status","Restart")]
    [string]$Action = "Status",
    [ValidateSet("Base","Mtp","Vision","MtpVision")]
    [string]$Mode = "Base",
    [ValidateRange(5,180)]
    [int]$ReadyTimeoutSeconds = 90
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$SettingsPath = Join-Path $Root "config\user-settings.json"
$RuntimeDir = Join-Path $Root "runtime"
$LogsDir = Join-Path $Root "logs"
$StatePath = Join-Path $RuntimeDir "server-state.json"
$Exe = Join-Path $Root "bin\ninfer-serve.exe"
$HealthScript = Join-Path $Root "scripts\healthcheck-windows-sm75.ps1"

function Get-Settings {
    if (-not (Test-Path $SettingsPath -PathType Leaf)) {
        throw "NInfer is not configured. Run launchers\Configure-NInfer.bat first."
    }
    $S = Get-Content $SettingsPath -Raw | ConvertFrom-Json
    if ($S.schema_version -ne 1) { throw "Unsupported user-settings schema: $($S.schema_version)" }
    return $S
}

function Get-ApiKey($Settings) {
    $KeyFile = [string]$Settings.api_key_file
    if ([string]::IsNullOrWhiteSpace($KeyFile) -or -not (Test-Path $KeyFile -PathType Leaf)) {
        throw "Local API key file is missing. Run Configure-NInfer.bat to repair it."
    }
    $Key = (Get-Content $KeyFile -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($Key)) { throw "Local API key file is empty." }
    return $Key
}

function Get-TrackedProcess {
    if (-not (Test-Path $StatePath -PathType Leaf)) { return $null }
    try { $State = Get-Content $StatePath -Raw | ConvertFrom-Json } catch {
        Remove-Item $StatePath -Force -ErrorAction SilentlyContinue
        return $null
    }
    try { $P = Get-Process -Id ([int]$State.pid) -ErrorAction Stop } catch {
        Remove-Item $StatePath -Force -ErrorAction SilentlyContinue
        return $null
    }
    try { $Path = $P.Path } catch { $Path = $null }
    if (-not $Path) {
        Write-Warning "Could not validate the tracked process executable; treating the PID file as stale."
        Remove-Item $StatePath -Force -ErrorAction SilentlyContinue
        return $null
    }
    if ([IO.Path]::GetFullPath($Path) -ne [IO.Path]::GetFullPath($Exe)) {
        Write-Warning "PID file pointed to another executable; refusing to manage that process."
        Remove-Item $StatePath -Force -ErrorAction SilentlyContinue
        return $null
    }
    try {
        $ExpectedStart = ([DateTime]$State.started_utc).ToUniversalTime()
        $ActualStart = $P.StartTime.ToUniversalTime()
        if ([Math]::Abs(($ActualStart - $ExpectedStart).TotalSeconds) -gt 60) {
            Write-Warning "Tracked PID appears to have been reused; refusing to manage it."
            Remove-Item $StatePath -Force -ErrorAction SilentlyContinue
            return $null
        }
    } catch {
        Write-Warning "Could not validate tracked process start time; treating state as stale."
        Remove-Item $StatePath -Force -ErrorAction SilentlyContinue
        return $null
    }
    return $P
}

function Test-PortInUse([int]$Port) {
    $Client = New-Object Net.Sockets.TcpClient
    try {
        $Async = $Client.BeginConnect("127.0.0.1",$Port,$null,$null)
        if (-not $Async.AsyncWaitHandle.WaitOne(500)) { return $false }
        try { $Client.EndConnect($Async); return $true } catch { return $false }
    } finally { $Client.Close() }
}

function Stop-Tracked {
    $P = Get-TrackedProcess
    if (-not $P) {
        Write-Host "NInfer server is not running (no valid tracked PID)."
        return
    }
    Write-Host "Stopping NInfer server PID $($P.Id)..."
    Stop-Process -Id $P.Id -Force -ErrorAction Stop
    try { $P.WaitForExit(10000) | Out-Null } catch {}
    Remove-Item $StatePath -Force -ErrorAction SilentlyContinue
    Write-Host "NInfer server stopped."
}

function Start-Tracked([string]$RequestedMode) {
    if (-not (Test-Path $Exe -PathType Leaf)) { throw "ninfer-serve.exe is missing: $Exe" }
    $ExistingProcess = Get-TrackedProcess
    if ($ExistingProcess) {
        $ExistingMode = $null
        try { $ExistingMode = [string](Get-Content $StatePath -Raw | ConvertFrom-Json).mode } catch {}
        if ($ExistingMode -eq $RequestedMode) {
            Write-Host "NInfer is already running in $RequestedMode mode as PID $($ExistingProcess.Id)."
            return
        }
        $ModeLabel = if ([string]::IsNullOrWhiteSpace($ExistingMode)) { "unknown" } else { $ExistingMode }
        Write-Host "NInfer is running in $ModeLabel mode; switching to $RequestedMode..."
        Stop-Tracked
        Start-Sleep -Milliseconds 500
    }

    $Settings = Get-Settings
    $Key = Get-ApiKey $Settings
    $ModelPath = [string]$Settings.model_path
    if (-not (Test-Path $ModelPath -PathType Leaf)) { throw "Configured model is missing: $ModelPath" }

    $Port = [int]$Settings.port
    if (Test-PortInUse $Port) { throw "TCP port $Port is already in use. Change it with Configure-NInfer.bat." }

    New-Item -ItemType Directory -Force -Path $RuntimeDir,$LogsDir | Out-Null
    $Stamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
    $Stdout = Join-Path $LogsDir "server-$Stamp.stdout.log"
    $Stderr = Join-Path $LogsDir "server-$Stamp.stderr.log"
    $RequestLog = Join-Path $LogsDir "requests.jsonl"

    $Args = @(
        ('"' + $ModelPath + '"'),
        "--host","127.0.0.1",
        "--port",$Port.ToString(),
        "--max-context",([int]$Settings.max_context).ToString(),
        "--kv-capacity","auto",
        "--max-concurrency",([int]$Settings.max_concurrency).ToString(),
        "--kv-dtype","int8",
        "--device",([int]$Settings.device).ToString(),
        "--request-log-jsonl",('"' + $RequestLog + '"'),
        "--log-stats-interval-ms","5000"
    )

    switch ($RequestedMode) {
        "Mtp"       { $Args += @("--spec","mtp","--draft-tokens",([int]$Settings.draft_tokens).ToString(),"--lm-head-draft") }
        "Vision"    { $Args += "--vision" }
        "MtpVision" { $Args += @("--spec","mtp","--draft-tokens",([int]$Settings.draft_tokens).ToString(),"--lm-head-draft","--vision") }
    }

    $PreviousKey = $env:NINFER_API_KEY
    try {
        $env:NINFER_API_KEY = $Key
        $Process = Start-Process -FilePath $Exe -ArgumentList $Args -WorkingDirectory $Root -PassThru -WindowStyle Hidden -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
    } finally {
        if ($null -eq $PreviousKey) { Remove-Item Env:NINFER_API_KEY -ErrorAction SilentlyContinue }
        else { $env:NINFER_API_KEY = $PreviousKey }
    }

    $State = [ordered]@{
        schema_version = 1
        pid = $Process.Id
        mode = $RequestedMode
        port = $Port
        executable = $Exe
        model_path = $ModelPath
        stdout = $Stdout
        stderr = $Stderr
        started_utc = [DateTime]::UtcNow.ToString("o")
    }
    $State | ConvertTo-Json -Depth 4 | Set-Content $StatePath -Encoding UTF8

    $Retries = [Math]::Max(3,[int][Math]::Ceiling($ReadyTimeoutSeconds / 2.0))
    try {
        & $HealthScript -BaseUrl "http://127.0.0.1:$Port" -ApiKey $Key -Retries $Retries -RetryDelaySeconds 2 -TimeoutSeconds 3
    } catch {
        try { Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue } catch {}
        Remove-Item $StatePath -Force -ErrorAction SilentlyContinue
        throw "NInfer failed to become ready. See $Stderr. $($_.Exception.Message)"
    }

    Write-Host ""
    Write-Host "NInfer is ready."
    Write-Host "  Mode:    $RequestedMode"
    Write-Host "  PID:     $($Process.Id)"
    Write-Host "  API:     http://127.0.0.1:$Port/v1"
    Write-Host "  Logs:    $LogsDir"
    Write-Host "  API key: stored locally; not printed"
}

switch ($Action) {
    "Start"   { Start-Tracked $Mode }
    "Stop"    { Stop-Tracked }
    "Restart" { Stop-Tracked; Start-Sleep -Milliseconds 500; Start-Tracked $Mode }
    "Status"  {
        $P = Get-TrackedProcess
        if (-not $P) { Write-Host "NInfer status: STOPPED"; return }
        $Settings = Get-Settings
        $Key = Get-ApiKey $Settings
        Write-Host "NInfer status: RUNNING (PID $($P.Id))"
        try {
            & $HealthScript -BaseUrl "http://127.0.0.1:$([int]$Settings.port)" -ApiKey $Key -Retries 1 -TimeoutSeconds 3
        } catch {
            throw "Process exists but health check failed: $($_.Exception.Message)"
        }
    }
}
