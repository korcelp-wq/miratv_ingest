<#
.SYNOPSIS
  Upload local EPG XML to server via FTP.

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
    [string]$LocalXmlPath = "C:\miratv_ingest\export\epg.xml",
    [string]$FtpHost = "miratv.club",
    [string]$FtpUser = "",
    [string]$FtpPass = "",
    [string]$RemotePath = "epg.xml",
    [int]$MaxAttempts = 3,
    [int]$RetrySleepSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "upload_epg_xml_to_server"
$Component = "epg_xml_upload"
$KillSwitchName = "ENABLE_EPG_XML_UPLOAD"

$RepoRoot = (Resolve-Path ".").Path
$StartedAt = Get-Date
$Stamp = $StartedAt.ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$RunId = "$WorkerName-$Stamp"

$ReportDir = Join-Path $RepoRoot "runtime\reports\epg_xml_upload"
$LogDir = Join-Path $RepoRoot "runtime\logs\epg_xml_upload"

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$SummaryPath = Join-Path $ReportDir "epg_xml_upload_summary_$Stamp.json"
$LogPath = Join-Path $LogDir "$WorkerName-$($StartedAt.ToUniversalTime().ToString('yyyyMMdd')).jsonl"

function Get-DurationMs {
    param([datetime]$Start)
    return [int][Math]::Round(((Get-Date) - $Start).TotalMilliseconds)
}

function Write-JobLog {
    param([string]$EventName, [string]$Status, [object]$Data = $null)

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
    param([string]$SignalName, [object]$SignalValue, [object]$Payload = $null)

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
    if ([string]::IsNullOrWhiteSpace($raw)) { return $true }
    return ($raw.Trim().ToLowerInvariant() -notin @("0","false","no","off","disabled"))
}

try {
    if (-not (Test-KillSwitch)) {
        throw "Worker disabled by $KillSwitchName."
    }

    if ([string]::IsNullOrWhiteSpace($FtpUser)) { $FtpUser = [Environment]::GetEnvironmentVariable("EPG_FTP_USER") }
    if ([string]::IsNullOrWhiteSpace($FtpPass)) { $FtpPass = [Environment]::GetEnvironmentVariable("EPG_FTP_PASS") }

    if ([string]::IsNullOrWhiteSpace($FtpUser)) { throw "FtpUser missing. Set EPG_FTP_USER or pass -FtpUser." }
    if ([string]::IsNullOrWhiteSpace($FtpPass)) { throw "FtpPass missing. Set EPG_FTP_PASS or pass -FtpPass." }
    if (-not (Test-Path -LiteralPath $LocalXmlPath)) { throw "Local XML not found: $LocalXmlPath" }

    $bytes = (Get-Item -LiteralPath $LocalXmlPath).Length
    $cleanRemotePath = $RemotePath.TrimStart("/")
    $remoteUri = "ftp://$FtpHost/$cleanRemotePath"

    Write-JobLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        local_xml_path = $LocalXmlPath
        local_bytes = $bytes
        ftp_host = $FtpHost
        remote_path = $RemotePath
        remote_uri_present = $true
        provider_calls = $true
        db_writes = $false
        max_attempts = $MaxAttempts
    })

    $success = $false
    $lastError = ""
    $attemptsUsed = 0

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $attemptsUsed = $attempt
        Emit-Heartbeat -Status "attempt_$attempt"

        try {
            $wc = New-Object System.Net.WebClient
            $wc.Credentials = New-Object System.Net.NetworkCredential($FtpUser, $FtpPass)
            $wc.UploadFile($remoteUri, $LocalXmlPath)
            $wc.Dispose()

            $success = $true
            break
        }
        catch {
            $lastError = $_.Exception.Message
            if ($_.Exception.InnerException) {
                $lastError = $_.Exception.InnerException.Message
            }

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
        local_xml_path = $LocalXmlPath
        local_bytes = $bytes
        ftp_host = $FtpHost
        remote_path = $RemotePath
        attempts_used = $attemptsUsed
        success = $success
        last_error = $lastError
        provider_calls = $true
        db_writes = $false
        duration_ms = Get-DurationMs -Start $StartedAt
        status = if ($success) { "pass" } else { "failed" }
    }

    $summary | ConvertTo-Json -Depth 8 | Set-Content -Path $SummaryPath -Encoding UTF8
    Emit-Signal -SignalName "epg_xml_upload_completed" -SignalValue $summary.status -Payload $summary
    Write-JobLog -EventName "job_completed" -Status $summary.status -Data $summary

    if (-not $success) {
        throw "EPG XML upload failed after $MaxAttempts attempts. Last error: $lastError"
    }

    Write-Output "OK: EPG XML upload completed. bytes=$bytes remote=$RemotePath summary=$SummaryPath"
}
catch {
    $errorSummary = [pscustomobject][ordered]@{
        run_id = $RunId
        worker_name = $WorkerName
        provider = $Provider
        local_xml_path = $LocalXmlPath
        local_bytes = 0
        ftp_host = $FtpHost
        remote_path = $RemotePath
        attempts_used = 0
        success = $false
        last_error = $_.Exception.Message
        provider_calls = $true
        db_writes = $false
        duration_ms = Get-DurationMs -Start $StartedAt
        status = "failed"
    }

    $errorSummary | ConvertTo-Json -Depth 8 | Set-Content -Path $SummaryPath -Encoding UTF8
    Emit-Signal -SignalName "epg_xml_upload_completed" -SignalValue "failed" -Payload $errorSummary
    Write-JobLog -EventName "job_failed" -Status "failed" -Data $errorSummary

    throw
}

