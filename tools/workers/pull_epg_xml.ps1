<#
.SYNOPSIS
  Pull XMLTV EPG file to local ingest export path.

.CONTRACT-MARKERS
  Write-JobLog
  Emit-Signal
  Emit-Heartbeat
  Test-KillSwitch
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [string]$Provider = "default",
    [string]$SourceUrl = "",
    [string]$OutputXmlPath = "C:\miratv_ingest\export\epg.xml",
    [int]$TimeoutSec = 900,
    [int]$MinBytes = 1000000,
    [int]$MaxAttempts = 3,
    [int]$RetrySleepSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "pull_epg_xml"
$Component = "epg_xml_pull"
$KillSwitchName = "ENABLE_EPG_XML_PULL"

$RepoRoot = (Resolve-Path ".").Path
$StartedAt = Get-Date
$Stamp = $StartedAt.ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$RunId = "$WorkerName-$Stamp"

$ReportDir = Join-Path $RepoRoot "runtime\reports\epg_xml_pull"
$LogDir = Join-Path $RepoRoot "runtime\logs\epg_xml_pull"

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$SummaryPath = Join-Path $ReportDir "epg_xml_pull_summary_$Stamp.json"
$LogPath = Join-Path $LogDir "$WorkerName-$($StartedAt.ToUniversalTime().ToString('yyyyMMdd')).jsonl"

function Get-DurationMs {
    param([datetime]$Start)
    return [int][Math]::Round(((Get-Date) - $Start).TotalMilliseconds)
}

function Write-JobLog {
    param(
        [string]$EventName,
        [string]$Status,
        [object]$Data = $null
    )

    $record = [ordered]@{
        event_ts = (Get-Date).ToUniversalTime().ToString("o")
        event_name = $EventName
        job_name = $WorkerName
        run_id = $RunId
        worker_name = $WorkerName
        component = $Component
        environment = $Environment
        provider = $Provider
        status = $Status
        data = $Data
    }

    Add-Content -Path $LogPath -Value ($record | ConvertTo-Json -Depth 12 -Compress) -Encoding UTF8
}

function Emit-Signal {
    param(
        [string]$SignalName,
        [object]$SignalValue,
        [object]$Payload = $null
    )

    Write-JobLog -EventName "signal_emitted" -Status "ok" -Data ([ordered]@{
        signal_name = $SignalName
        signal_value = $SignalValue
        payload = $Payload
    })
}

function Emit-Heartbeat {
    param([string]$Status = "ok")

    Write-JobLog -EventName "heartbeat" -Status $Status -Data ([ordered]@{})
}

function Test-KillSwitch {
    $raw = [Environment]::GetEnvironmentVariable($KillSwitchName)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $true
    }

    $normalized = $raw.Trim().ToLowerInvariant()
    return ($normalized -notin @("0", "false", "no", "off", "disabled"))
}

try {
    if (-not (Test-KillSwitch)) {
        throw "Worker disabled by $KillSwitchName."
    }

    if ([string]::IsNullOrWhiteSpace($SourceUrl)) {
        $SourceUrl = [Environment]::GetEnvironmentVariable("MIRATV_EPG_XMLTV_URL")
    }

    if ([string]::IsNullOrWhiteSpace($SourceUrl)) {
        throw "SourceUrl missing. Set MIRATV_EPG_XMLTV_URL or pass -SourceUrl."
    }

    $OutputDir = Split-Path -Parent $OutputXmlPath
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

    $TempPath = "$OutputXmlPath.download"

    Write-JobLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        source_url_present = $true
        output_xml_path = $OutputXmlPath
        timeout_sec = $TimeoutSec
        min_bytes = $MinBytes
        max_attempts = $MaxAttempts
        provider_calls = $true
        db_writes = $false
    })

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $headers = @{
        "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/125 Safari/537.36"
        "Accept" = "application/xml,text/xml,*/*"
        "Accept-Language" = "en-US,en;q=0.9"
    }

    $success = $false
    $bytes = 0
    $lastError = ""
    $attemptsUsed = 0

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $attemptsUsed = $attempt
        Emit-Heartbeat -Status "attempt_$attempt"

        try {
            if (Test-Path -LiteralPath $TempPath) {
                Remove-Item -LiteralPath $TempPath -Force
            }

            Invoke-WebRequest `
                -Uri $SourceUrl `
                -OutFile $TempPath `
                -Headers $headers `
                -TimeoutSec $TimeoutSec `
                -UseBasicParsing

            if (-not (Test-Path -LiteralPath $TempPath)) {
                throw "Temporary download file was not created."
            }

            $bytes = (Get-Item -LiteralPath $TempPath).Length

            if ($bytes -lt $MinBytes) {
                throw "Downloaded EPG XML too small. bytes=$bytes min=$MinBytes"
            }

            Move-Item -LiteralPath $TempPath -Destination $OutputXmlPath -Force

            $success = $true
            break
        }
        catch {
            $lastError = $_.Exception.Message

            Write-JobLog -EventName "attempt_failed" -Status "warning" -Data ([ordered]@{
                attempt = $attempt
                error_message = $lastError
            })

            if ($attempt -lt $MaxAttempts) {
                Start-Sleep -Seconds $RetrySleepSeconds
            }
        }
    }

    $summary = [pscustomobject][ordered]@{
        run_id = $RunId
        worker_name = $WorkerName
        provider = $Provider
        output_xml_path = $OutputXmlPath
        output_bytes = $bytes
        attempts_used = $attemptsUsed
        success = $success
        last_error = $lastError
        provider_calls = $true
        db_writes = $false
        duration_ms = Get-DurationMs -Start $StartedAt
        status = if ($success) { "pass" } else { "failed" }
    }

    $summary | ConvertTo-Json -Depth 8 | Set-Content -Path $SummaryPath -Encoding UTF8

    Emit-Signal -SignalName "epg_xml_pull_completed" -SignalValue $summary.status -Payload $summary

    Write-JobLog -EventName "job_completed" -Status $summary.status -Data ([ordered]@{
        output_bytes = $bytes
        attempts_used = $attemptsUsed
        summary_path = $SummaryPath
        duration_ms = $summary.duration_ms
    })

    if (-not $success) {
        throw "EPG XML pull failed after $MaxAttempts attempts. Last error: $lastError"
    }

    Write-Output "OK: EPG XML pull completed. bytes=$bytes path=$OutputXmlPath summary=$SummaryPath"
}
catch {
    $errorSummary = [pscustomobject][ordered]@{
        run_id = $RunId
        worker_name = $WorkerName
        provider = $Provider
        output_xml_path = $OutputXmlPath
        output_bytes = 0
        attempts_used = 0
        success = $false
        last_error = $_.Exception.Message
        provider_calls = $true
        db_writes = $false
        duration_ms = Get-DurationMs -Start $StartedAt
        status = "failed"
    }

    $errorSummary | ConvertTo-Json -Depth 8 | Set-Content -Path $SummaryPath -Encoding UTF8
    Emit-Signal -SignalName "epg_xml_pull_completed" -SignalValue "failed" -Payload $errorSummary
    Write-JobLog -EventName "job_failed" -Status "failed" -Data $errorSummary

    throw
}
