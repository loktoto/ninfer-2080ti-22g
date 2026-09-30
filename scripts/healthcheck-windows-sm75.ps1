[CmdletBinding()]
param(
    [string]$BaseUrl = "http://127.0.0.1:8080",
    [string]$ApiKey = $env:NINFER_API_KEY,
    [ValidateRange(1,120)]
    [int]$TimeoutSeconds = 5,
    [ValidateRange(1,120)]
    [int]$Retries = 30,
    [ValidateRange(1,30)]
    [int]$RetryDelaySeconds = 2
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Headers = @{}
if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
    $Headers["Authorization"] = "Bearer $ApiKey"
}

$LastError = $null
for ($Attempt = 1; $Attempt -le $Retries; $Attempt++) {
    try {
        $health = Invoke-RestMethod -Method Get -Uri "$BaseUrl/health" -TimeoutSec $TimeoutSeconds
        if ($health.status -ne "ok") { throw "Unexpected /health response." }

        $models = Invoke-RestMethod -Method Get -Uri "$BaseUrl/v1/models" -Headers $Headers -TimeoutSec $TimeoutSeconds
        if (-not $models.data -or $models.data.Count -lt 1) { throw "/v1/models returned no model." }

        Write-Host "Readiness check passed."
        Write-Host "  Health: $($health.status)"
        Write-Host "  Model:  $($models.data[0].id)"
        exit 0
    } catch {
        $LastError = $_
        if ($Attempt -lt $Retries) {
            Write-Host "Server not ready yet ($Attempt/$Retries): $($_.Exception.Message)"
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
}

throw "Server did not become ready after $Retries attempts. Last error: $($LastError.Exception.Message)"
