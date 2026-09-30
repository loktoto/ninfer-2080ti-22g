[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Model,
    [string]$InstallDir = "out\windows-sm75",
    [ValidateRange(0,15)]
    [int]$Device = 0,
    [ValidateRange(1,65535)]
    [int]$Port = 18080,
    [string]$ApiKey = "",
    [int[]]$ContextTargets = @(8192,32768,65536),
    [ValidateRange(1,300)]
    [int]$StartupRetries = 90,
    [switch]$SkipMtpParity,
    [switch]$SkipToolCall
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$ModelPath = (Resolve-Path $Model -ErrorAction Stop).Path

$ArtifactVerifier = Join-Path $PSScriptRoot "download-qwen38-windows-sm75.ps1"
if (-not (Test-Path $ArtifactVerifier -PathType Leaf)) {
    throw "Pinned artifact verifier not found: $ArtifactVerifier"
}
if ((Split-Path $ModelPath -Leaf) -ne "qwen3_8_27b.ninfer") {
    throw "Production acceptance is locked to qwen3_8_27b.ninfer; got $(Split-Path $ModelPath -Leaf)."
}
& $ArtifactVerifier -ModelDir (Split-Path $ModelPath -Parent) -VerifyOnly

function Resolve-RuntimeBinary([string]$Name) {
    $Packaged = Join-Path $RepoRoot "bin\$Name"
    if (Test-Path $Packaged -PathType Leaf) { return $Packaged }
    $Staged = Join-Path $RepoRoot "$InstallDir\bin\$Name"
    if (Test-Path $Staged -PathType Leaf) { return $Staged }
    throw "$Name was not found in the packaged or staged runtime."
}

function Invoke-NInferJson([string]$Method, [string]$Uri, $Body = $null) {
    $Headers = @{}
    if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
        $Headers["Authorization"] = "Bearer $ApiKey"
    }
    $Request = @{
        Method = $Method
        Uri = $Uri
        Headers = $Headers
        TimeoutSec = 120
    }
    if ($null -ne $Body) {
        $Request["ContentType"] = "application/json"
        $Request["Body"] = ($Body | ConvertTo-Json -Depth 20 -Compress)
    }
    return Invoke-RestMethod @Request
}

function New-FillerText([int]$Units) {
    $Builder = New-Object System.Text.StringBuilder ([Math]::Max(64, $Units * 11))
    for ($i = 0; $i -lt $Units; $i++) {
        [void]$Builder.Append(" acceptance")
    }
    return $Builder.ToString()
}

function Find-ContextPrompt([string]$ModelId, [int]$ContextLimit) {
    $Goal = [Math]::Max(512, $ContextLimit - 256)
    $Low = 1
    $High = [Math]::Max(1024, $Goal * 2)
    $BestText = ""
    $BestTokens = 0

    for ($Iteration = 0; $Iteration -lt 20 -and $Low -le $High; $Iteration++) {
        $Mid = [int][Math]::Floor(($Low + $High) / 2)
        $Text = New-FillerText $Mid
        $CountBody = @{
            model = $ModelId
            messages = @(@{ role = "user"; content = $Text })
        }
        $Count = Invoke-NInferJson "POST" "http://127.0.0.1:$Port/v1/messages/count_tokens" $CountBody
        $Tokens = [int]$Count.input_tokens
        if ($Tokens -le $Goal) {
            $BestText = $Text
            $BestTokens = $Tokens
            $Low = $Mid + 1
        } else {
            $High = $Mid - 1
        }
    }

    if ($BestTokens -lt [int]($Goal * 0.90)) {
        throw "Could not synthesize a prompt close enough to the $ContextLimit-token acceptance target; best count was $BestTokens."
    }
    return [pscustomobject]@{ Text = $BestText; Tokens = $BestTokens; Limit = $ContextLimit }
}

$CliExe = Resolve-RuntimeBinary "ninfer.exe"
$ServeExe = Resolve-RuntimeBinary "ninfer-serve.exe"
$Smoke = Join-Path $PSScriptRoot "smoke-test-windows-sm75.ps1"
if (-not (Test-Path $Smoke -PathType Leaf)) { throw "Smoke test script not found: $Smoke" }

Write-Host "== Windows SM75 hardware acceptance =="
& $Smoke -Model $ModelPath -InstallDir $InstallDir -Device $Device -Context 8192 -MaxNew 16
if ($LASTEXITCODE -ne 0) { throw "8K hardware smoke test failed." }

$MaxContext = ($ContextTargets | Measure-Object -Maximum).Maximum
if (-not $MaxContext -or $MaxContext -lt 1024) { throw "ContextTargets must contain positive context sizes." }

if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    $ApiKey = [guid]::NewGuid().ToString("N")
}

$EvidenceDir = Join-Path $RepoRoot "acceptance"
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
$Stamp = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
$StdoutPath = Join-Path $EvidenceDir "server-$Stamp.stdout.log"
$StderrPath = Join-Path $EvidenceDir "server-$Stamp.stderr.log"
$EvidencePath = Join-Path $EvidenceDir "windows-sm75-$Stamp.json"

$QuotedModelPath = '"' + $ModelPath + '"'
$ServerArgs = @(
    $QuotedModelPath,
    "--host", "127.0.0.1",
    "--port", $Port.ToString(),
    "--max-context", $MaxContext.ToString(),
    "--kv-capacity", "auto",
    "--max-concurrency", "1",
    "--kv-dtype", "int8",
    "--device", $Device.ToString(),
    "--greedy",
    "--no-thinking",
    "--log-stats-interval-ms", "1000"
)

$PreviousApiKey = $env:NINFER_API_KEY
$Process = $null
$ContextResults = @()
$ToolCallPassed = $null
try {
    $env:NINFER_API_KEY = $ApiKey
    $Process = Start-Process -FilePath $ServeExe -ArgumentList $ServerArgs -PassThru -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath

    $Ready = $false
    for ($Attempt = 1; $Attempt -le $StartupRetries; $Attempt++) {
        if ($Process.HasExited) {
            throw "ninfer-serve exited during startup with code $($Process.ExitCode). See $StderrPath"
        }
        try {
            $Health = Invoke-RestMethod -Method Get -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2
            if ($Health.status -eq "ok") { $Ready = $true; break }
        } catch {}
        Start-Sleep -Seconds 2
    }
    if (-not $Ready) { throw "ninfer-serve did not become ready." }

    $Models = Invoke-NInferJson "GET" "http://127.0.0.1:$Port/v1/models"
    if (-not $Models.data -or $Models.data.Count -lt 1) { throw "Server reported no model." }
    $ModelId = [string]$Models.data[0].id

    foreach ($Limit in ($ContextTargets | Sort-Object -Unique)) {
        Write-Host "Exercising long-context prefill near $Limit tokens..."
        $Prepared = Find-ContextPrompt $ModelId $Limit
        $Body = @{
            model = $ModelId
            messages = @(@{ role = "user"; content = $Prepared.Text })
            max_tokens = 1
            temperature = 0
            stream = $false
        }
        $Watch = [Diagnostics.Stopwatch]::StartNew()
        $Response = Invoke-NInferJson "POST" "http://127.0.0.1:$Port/v1/chat/completions" $Body
        $Watch.Stop()
        if (-not $Response.choices -or $Response.choices.Count -lt 1) {
            throw "No completion choice returned for context target $Limit."
        }
        $ContextResults += [pscustomobject]@{
            context_limit = $Limit
            counted_input_tokens = $Prepared.Tokens
            wall_seconds = [Math]::Round($Watch.Elapsed.TotalSeconds, 3)
            passed = $true
        }
    }

    if (-not $SkipToolCall) {
        Write-Host "Exercising OpenAI tool-call path..."
        $ToolBody = @{
            model = $ModelId
            messages = @(@{
                role = "user"
                content = "Call the get_weather tool for Paris. Do not answer with prose."
            })
            tools = @(@{
                type = "function"
                function = @{
                    name = "get_weather"
                    description = "Get the weather for a city."
                    parameters = @{
                        type = "object"
                        properties = @{ city = @{ type = "string" } }
                        required = @("city")
                        additionalProperties = $false
                    }
                }
            })
            tool_choice = "required"
            max_tokens = 128
            temperature = 0
            stream = $false
        }
        $ToolResponse = Invoke-NInferJson "POST" "http://127.0.0.1:$Port/v1/chat/completions" $ToolBody
        $ToolCalls = $ToolResponse.choices[0].message.tool_calls
        if (-not $ToolCalls -or $ToolCalls.Count -lt 1) {
            throw "Tool-call acceptance failed: the required tool call was not returned."
        }
        $ToolCallPassed = $true
    }
} finally {
    if ($Process -and -not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        try { $Process.WaitForExit(10000) | Out-Null } catch {}
    }
    if ($null -eq $PreviousApiKey) {
        Remove-Item Env:NINFER_API_KEY -ErrorAction SilentlyContinue
    } else {
        $env:NINFER_API_KEY = $PreviousApiKey
    }
}

$MtpParity = $null
if (-not $SkipMtpParity) {
    Write-Host "Checking greedy MTP0/MTP3 token-path parity..."
    $Prompt = "Return exactly one short sentence explaining why deterministic parity matters."
    $Common = @(
        $ModelPath,
        "--prompt", $Prompt,
        "--max-context", "8192",
        "--max-new", "64",
        "--kv-dtype", "int8",
        "--greedy",
        "--no-thinking",
        "--raw-output"
    )
    $BaseErr = Join-Path $EvidenceDir "mtp0-$Stamp.stderr.log"
    $MtpErr = Join-Path $EvidenceDir "mtp3-$Stamp.stderr.log"
    $Mtp0 = (& $CliExe @Common 2>$BaseErr | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "MTP0 parity control failed. See $BaseErr" }
    $Mtp3Args = $Common + @("--spec","mtp","--draft-tokens","3","--lm-head-draft")
    $Mtp3 = (& $CliExe @Mtp3Args 2>$MtpErr | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "MTP3 parity run failed. See $MtpErr" }
    if ($Mtp0 -ne $Mtp3) {
        throw "MTP0/MTP3 greedy output parity failed. Evidence logs are under $EvidenceDir."
    }
    $MtpParity = $true
}

$GpuRows = @(& nvidia-smi --query-gpu=index,name,memory.total,compute_cap,driver_version --format=csv,noheader,nounits)
if ($LASTEXITCODE -ne 0 -or $GpuRows.Count -eq 0) {
    throw "nvidia-smi evidence query failed."
}

$BuildGitSha = $null
if (Test-Path (Join-Path $RepoRoot ".git")) {
    $GitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
    if (-not $GitCommand) { $GitCommand = Get-Command git -ErrorAction SilentlyContinue }
    if ($GitCommand) {
        $CandidateSha = (& $GitCommand.Source -C $RepoRoot rev-parse HEAD).Trim()
        if ($LASTEXITCODE -eq 0 -and $CandidateSha) { $BuildGitSha = $CandidateSha }
    }
}
if ([string]::IsNullOrWhiteSpace($BuildGitSha)) {
    $BuildManifestPath = Join-Path $RepoRoot "BUILD-MANIFEST.json"
    if (Test-Path $BuildManifestPath -PathType Leaf) {
        $BuildManifest = Get-Content $BuildManifestPath -Raw | ConvertFrom-Json
        $BuildGitSha = [string]$BuildManifest.git_sha
    }
}
if ([string]::IsNullOrWhiteSpace($BuildGitSha)) { $BuildGitSha = "unknown" }

$Evidence = [ordered]@{
    schema_version = 1
    artifact_type = "ninfer_windows_sm75_hardware_acceptance"
    created_utc = [DateTime]::UtcNow.ToString("o")
    git_sha = $BuildGitSha
    model_path = $ModelPath
    model_sha256 = (Get-FileHash $ModelPath -Algorithm SHA256).Hash.ToLowerInvariant()
    device = $Device
    gpu_inventory = $GpuRows
    context_results = $ContextResults
    mtp0_mtp3_parity = $MtpParity
    tool_call = $ToolCallPassed
    server_stdout = $StdoutPath
    server_stderr = $StderrPath
}
$Evidence | ConvertTo-Json -Depth 10 | Set-Content $EvidencePath -Encoding UTF8

Write-Host "Hardware acceptance passed."
Write-Host "  Evidence: $EvidencePath"

