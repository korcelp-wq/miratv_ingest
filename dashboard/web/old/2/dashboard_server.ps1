#!/usr/bin/env pwsh
param(
    [string]$ConfigPath = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'dashboard_config.json'),
    [int]$Port = 0
)

$ErrorActionPreference = 'Continue'
$script:DashboardRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Get-DashboardConfig {
    $defaults = [ordered]@{
        Port = 8787
        RefreshSeconds = 5
        LogDir = 'C:\miratv_ingest\logs'
        RuntimeDir = 'C:\miratv_ingest\runtime'
        BgcStatusFile = 'C:\MiraTV\Modules\IMG\BGC\runtime\bgc_watcher_service.status.json'
        OllamaUrl = 'http://localhost:11434'
        OllamaModel = 'llama3.2:latest'
        CviGatewayUrl = 'https://miratv.club/_workers/ai/cvi_gateway.php'
        CviTokenEnvName = 'CVI_GATEWAY_TOKEN'
        CviChecks = @()
    }

    if (Test-Path $ConfigPath) {
        try {
            $cfg = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json -Depth 20
            foreach ($p in $cfg.PSObject.Properties) {
                $defaults[$p.Name] = $p.Value
            }
        }
        catch { }
    }

    if ($Port -gt 0) { $defaults.Port = $Port }
    return [PSCustomObject]$defaults
}

$script:Config = Get-DashboardConfig

function New-StatusObject {
    param([string]$State = 'UNKNOWN', [string]$Message = '', $Data = $null)
    return [PSCustomObject]@{
        state = $State
        message = $Message
        data = $Data
    }
}

function Get-LogFilePath {
    $logDir = [string]$script:Config.LogDir
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logFile = Join-Path $logDir ("master_control_debug_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
    if (-not (Test-Path $logFile)) { New-Item -ItemType File -Path $logFile -Force | Out-Null }
    return $logFile
}

function Get-RecentLogLines {
    param([int]$Tail = 80)
    $logFile = Get-LogFilePath
    $lines = @(Get-Content -Path $logFile -Tail $Tail -ErrorAction SilentlyContinue)
    return @($lines | ForEach-Object {
        $category = 'INFO'
        if ($_ -match '(?i)error|exception|fail|failed|blocked|\[err\]') { $category = 'ERROR' }
        elseif ($_ -match '(?i)warn|warning') { $category = 'WARN' }
        elseif ($_ -match '(?i)\[sql\]|database|query') { $category = 'SQL' }
        elseif ($_ -match '(?i)bgc|governance') { $category = 'BGC' }
        elseif ($_ -match '(?i)ollama|ai') { $category = 'AI' }
        elseif ($_ -match '(?i)cvi|carousel') { $category = 'CVI' }
        [PSCustomObject]@{ category = $category; line = [string]$_ }
    })
}

function Get-ErrorRates {
    $logFile = Get-LogFilePath
    $todayLines = @(Get-Content -Path $logFile -ErrorAction SilentlyContinue)
    $now = Get-Date
    $systems = [ordered]@{
        SQL = @{ today = 0; last_hour = 0 }
        BGC = @{ today = 0; last_hour = 0 }
        OLLAMA = @{ today = 0; last_hour = 0 }
        CVI = @{ today = 0; last_hour = 0 }
        TELEMETRY = @{ today = 0; last_hour = 0 }
        SPOOL = @{ today = 0; last_hour = 0 }
        MASTER = @{ today = 0; last_hour = 0 }
    }

    foreach ($line in $todayLines) {
        $isError = ($line -match '(?i)error|exception|fail|failed|blocked|\[err\]')
        if (-not $isError) { continue }

        $bucket = 'MASTER'
        if ($line -match '(?i)\[SQL\]|SQL|database|query') { $bucket = 'SQL' }
        elseif ($line -match '(?i)BGC|governance') { $bucket = 'BGC' }
        elseif ($line -match '(?i)OLLAMA|AI') { $bucket = 'OLLAMA' }
        elseif ($line -match '(?i)CVI|carousel') { $bucket = 'CVI' }
        elseif ($line -match '(?i)telemetry') { $bucket = 'TELEMETRY' }
        elseif ($line -match '(?i)spool|upload') { $bucket = 'SPOOL' }

        $systems[$bucket].today++

        if ($line -match '^\[(?<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]') {
            try {
                $ts = [datetime]::ParseExact($matches.ts, 'yyyy-MM-dd HH:mm:ss', $null)
                if (($now - $ts).TotalMinutes -le 60) { $systems[$bucket].last_hour++ }
            } catch { }
        }
    }

    return @($systems.Keys | ForEach-Object {
        [PSCustomObject]@{ system = $_; today = $systems[$_].today; last_hour = $systems[$_].last_hour }
    })
}

function Get-ProcessStateByPattern {
    param([string]$Name, [string]$Pattern)
    try {
        $escaped = [regex]::Escape($Pattern)
        $matches = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match '^powershell(\.exe)?$|^pwsh(\.exe)?$|^cmd(\.exe)?$' -and
            $_.CommandLine -match $escaped
        })
        if ($matches.Count -gt 0) {
            return [PSCustomObject]@{ name = $Name; state = 'RUNNING'; count = $matches.Count; pid = ($matches | Select-Object -First 1).ProcessId }
        }
        return [PSCustomObject]@{ name = $Name; state = 'STOPPED'; count = 0; pid = $null }
    }
    catch {
        return [PSCustomObject]@{ name = $Name; state = 'UNKNOWN'; count = 0; pid = $null }
    }
}

function Get-ServiceStates {
    $patterns = @(
        @{ name = 'Spine Scheduler'; group = 'core'; controlled = $true; pattern = 'C:\miratv_ingest\workers\spine\spine_scheduler_total.ps1' },
        @{ name = 'CVI Watcher'; group = 'core'; controlled = $true; pattern = 'C:\miratv_ingest\watcher_cvi.ps1' },
        @{ name = 'Telemetry Watcher'; group = 'core'; controlled = $true; pattern = 'C:\miratv_ingest\workers\telemetry_watcher.ps1' },
        @{ name = 'Spool Uploader'; group = 'core'; controlled = $true; pattern = 'C:\miratv_ingest\spool_uploader.ps1' },
        @{ name = 'AI Learning Loop'; group = 'core'; controlled = $true; pattern = 'C:\miratv_ingest\workers\GovernanceLearner.ps1' },
        @{ name = 'Knowledge Miner'; group = 'learning'; controlled = $true; pattern = 'C:\miratv_ingest\workers\KnowledgeMiner.ps1' },
        @{ name = 'Accessory Upload Loop'; group = 'learning'; controlled = $true; pattern = 'C:\miratv_ingest\MASTER_ACCESSORY_UPLOAD_LOOP.bat' },
        @{ name = 'Runner Loop'; group = 'learning'; controlled = $true; pattern = 'C:\miratv_ingest\master_runner_loop.bat' },
        @{ name = 'Mastery Accessory Loop'; group = 'additional_managed'; controlled = $true; pattern = 'C:\miratv_ingest\master_runner_loop_acc.bat' },
        @{ name = 'Main Series Loop'; group = 'additional_managed'; controlled = $true; pattern = 'C:\miratv_ingest\master_runner_loop.bat' },
        @{ name = 'Master Upload Loop'; group = 'additional_managed'; controlled = $true; pattern = 'C:\miratv_ingest\MASTER_UPLOAD_LOOP.bat' },
        @{ name = 'BGC Watcher Service'; group = 'monitored_external'; controlled = $false; pattern = 'C:\MiraTV\Modules\IMG\BGC\BGC_Runtime_Watcher_Service.ps1' },
        @{ name = 'CVI Web Dashboard'; group = 'monitored_external'; controlled = $false; pattern = 'C:\miratv_ingest\dashboard\web\dashboard_server.ps1' }
    )

    return @($patterns | ForEach-Object {
        $state = Get-ProcessStateByPattern -Name $_.name -Pattern $_.pattern
        $state | Add-Member -NotePropertyName group -NotePropertyValue $_.group -Force
        $state | Add-Member -NotePropertyName controlled -NotePropertyValue $_.controlled -Force
        $state
    })
}

function Get-BgcHeartbeatStatus {
    $path = [string]$script:Config.BgcStatusFile
    if (-not (Test-Path $path)) {
        return [PSCustomObject]@{ state = 'UNKNOWN'; heartbeat = $null; age_seconds = $null; last_action = 'status file missing'; rule_count = $null; path = $path }
    }

    try {
        $json = Get-Content -Path $path -Raw | ConvertFrom-Json -Depth 20
        $heartbeat = $json.heartbeat
        $age = $null
        $state = if ($json.state) { [string]$json.state } else { 'UNKNOWN' }
        if ($heartbeat) {
            try {
                $dt = [datetime]::Parse([string]$heartbeat)
                $age = [math]::Round(((Get-Date) - $dt).TotalSeconds, 0)
                if ($age -le 15) { $state = 'ALIVE' }
                elseif ($age -le 60) { $state = 'STALE' }
                else { $state = 'DEAD' }
            } catch { }
        }
        return [PSCustomObject]@{
            state = $state
            heartbeat = $heartbeat
            age_seconds = $age
            last_action = $json.last_action
            rule_count = $json.rule_count
            path = $path
        }
    }
    catch {
        return [PSCustomObject]@{ state = 'ERROR'; heartbeat = $null; age_seconds = $null; last_action = $_.Exception.Message; rule_count = $null; path = $path }
    }
}

function Get-OllamaStatus {
    $base = ([string]$script:Config.OllamaUrl).TrimEnd('/')
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $tags = Invoke-RestMethod -Uri "$base/api/tags" -TimeoutSec 3 -ErrorAction Stop
        $sw.Stop()
        $models = @($tags.models | ForEach-Object { $_.name })
        return [PSCustomObject]@{ state = 'OK'; response_ms = $sw.ElapsedMilliseconds; models = $models; active_model = [string]$script:Config.OllamaModel; message = 'connected' }
    }
    catch {
        return [PSCustomObject]@{ state = 'OFFLINE'; response_ms = $null; models = @(); active_model = [string]$script:Config.OllamaModel; message = $_.Exception.Message }
    }
}

function Invoke-CviGatewayCheck {
    param($Check)
    $gateway = [string]$script:Config.CviGatewayUrl
    $tokenName = [string]$script:Config.CviTokenEnvName
    $token = [Environment]::GetEnvironmentVariable($tokenName, 'Process')
    if ([string]::IsNullOrWhiteSpace($token)) { $token = [Environment]::GetEnvironmentVariable($tokenName, 'User') }
    if ([string]::IsNullOrWhiteSpace($token)) { $token = [Environment]::GetEnvironmentVariable($tokenName, 'Machine') }

    if ([string]::IsNullOrWhiteSpace($token)) {
        return [PSCustomObject]@{ name = $Check.name; procedure = $Check.procedure; state = 'NOT_CONFIGURED'; row_count = $null; response_ms = $null; message = "Set environment variable $tokenName" }
    }

    try {
        $body = @{ procedure = $Check.procedure; params = $Check.params } | ConvertTo-Json -Depth 20 -Compress
        $headers = @{ 'X-CVI-TOKEN' = $token }
        $uri = $gateway
        if ($uri -notmatch '\?') { $uri = "$uri?token=$token" }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $resp = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 8 -ErrorAction Stop
        $sw.Stop()
        $rowCount = 0
        if ($resp.PSObject.Properties.Name -contains 'row_count') { $rowCount = [int]$resp.row_count }
        elseif ($resp.PSObject.Properties.Name -contains 'rows') { $rowCount = @($resp.rows).Count }
        $ok = ($resp.success -eq $true -or $resp.ok -eq $true -or $rowCount -ge 0)
        return [PSCustomObject]@{ name = $Check.name; procedure = $Check.procedure; state = if ($ok) { 'OK' } else { 'WARN' }; row_count = $rowCount; response_ms = $sw.ElapsedMilliseconds; message = 'gateway responded' }
    }
    catch {
        return [PSCustomObject]@{ name = $Check.name; procedure = $Check.procedure; state = 'ERROR'; row_count = $null; response_ms = $null; message = $_.Exception.Message }
    }
}

function Get-CviStatus {
    $checks = @($script:Config.CviChecks)
    if ($checks.Count -eq 0) { return @() }
    return @($checks | ForEach-Object { Invoke-CviGatewayCheck -Check $_ })
}

function Invoke-RawOllamaPrompt {
    param([string]$Prompt)
    $ollama = Get-OllamaStatus
    if ($ollama.state -ne 'OK') {
        return [PSCustomObject]@{ ok = $false; answer = 'Ollama is offline or unavailable.'; source = 'ollama_status' }
    }

    try {
        $base = ([string]$script:Config.OllamaUrl).TrimEnd('/')
        $body = @{
            model = [string]$script:Config.OllamaModel
            prompt = $Prompt
            stream = $false
            options = @{ temperature = 0.2; num_predict = 500 }
        } | ConvertTo-Json -Depth 10
        $resp = Invoke-RestMethod -Uri "$base/api/generate" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 90 -ErrorAction Stop
        return [PSCustomObject]@{ ok = $true; answer = [string]$resp.response; source = 'raw_local_ollama_probe' }
    }
    catch {
        return [PSCustomObject]@{ ok = $false; answer = $_.Exception.Message; source = 'raw_local_ollama_probe' }
    }
}

function Get-DashboardStatus {
    $now = Get-Date
    return [PSCustomObject]@{
        generated_at = $now.ToString('yyyy-MM-dd HH:mm:ss')
        config = [PSCustomObject]@{
            port = [int]$script:Config.Port
            refresh_seconds = [int]$script:Config.RefreshSeconds
            gateway_url = [string]$script:Config.CviGatewayUrl
            cvi_token_env = [string]$script:Config.CviTokenEnvName
        }
        heartbeat = Get-BgcHeartbeatStatus
        ollama = Get-OllamaStatus
        services = Get-ServiceStates
        cvi = Get-CviStatus
        error_rates = Get-ErrorRates
        recent_log = Get-RecentLogLines -Tail 80
    }
}

function Send-JsonResponse {
    param($Context, $Object, [int]$StatusCode = 200)
    $json = $Object | ConvertTo-Json -Depth 30
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Send-TextResponse {
    param($Context, [string]$Text, [string]$ContentType = 'text/html; charset=utf-8', [int]$StatusCode = 200)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Get-RequestBodyJson {
    param($Request)
    try {
        $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
        $body = $reader.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($body)) { return $null }
        return $body | ConvertFrom-Json -Depth 20
    }
    catch { return $null }
}

$listener = [System.Net.HttpListener]::new()
$prefix = "http://localhost:$([int]$script:Config.Port)/"
$listener.Prefixes.Add($prefix)

try {
    $listener.Start()
}
catch {
    Write-Host "[ERR] Could not start dashboard listener on $prefix" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "Try running PowerShell as Administrator, or add a URLACL for $prefix" -ForegroundColor Yellow
    exit 1
}

Write-Host "[OK] CVI Web Dashboard running at $prefix" -ForegroundColor Green
Write-Host "Press CTRL+C in this window to stop." -ForegroundColor DarkGray

while ($listener.IsListening) {
    try {
        $ctx = $listener.GetContext()
        $path = $ctx.Request.Url.AbsolutePath.TrimEnd('/')
        if ([string]::IsNullOrWhiteSpace($path)) { $path = '/' }

        switch -Regex ($path) {
            '^/$' {
                $indexPath = Join-Path $script:DashboardRoot 'index.html'
                Send-TextResponse -Context $ctx -Text (Get-Content -Path $indexPath -Raw) -ContentType 'text/html; charset=utf-8'
            }
            '^/style.css$' {
                Send-TextResponse -Context $ctx -Text (Get-Content -Path (Join-Path $script:DashboardRoot 'style.css') -Raw) -ContentType 'text/css; charset=utf-8'
            }
            '^/app.js$' {
                Send-TextResponse -Context $ctx -Text (Get-Content -Path (Join-Path $script:DashboardRoot 'app.js') -Raw) -ContentType 'application/javascript; charset=utf-8'
            }
            '^/api/status$' {
                Send-JsonResponse -Context $ctx -Object (Get-DashboardStatus)
            }
            '^/api/ask$' {
                if ($ctx.Request.HttpMethod -ne 'POST') { Send-JsonResponse -Context $ctx -Object @{ ok = $false; error = 'POST required' } -StatusCode 405; break }
                $body = Get-RequestBodyJson -Request $ctx.Request
                $prompt = if ($body -and $body.prompt) { [string]$body.prompt } else { '' }
                if ([string]::IsNullOrWhiteSpace($prompt)) { Send-JsonResponse -Context $ctx -Object @{ ok = $false; error = 'prompt required' } -StatusCode 400; break }
                Send-JsonResponse -Context $ctx -Object (Invoke-RawOllamaPrompt -Prompt $prompt)
            }
            default {
                Send-JsonResponse -Context $ctx -Object @{ ok = $false; error = 'not found'; path = $path } -StatusCode 404
            }
        }
    }
    catch {
        try { Send-JsonResponse -Context $ctx -Object @{ ok = $false; error = $_.Exception.Message } -StatusCode 500 } catch { }
    }
}
