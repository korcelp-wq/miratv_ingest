<#
.SYNOPSIS
  Preview EPG program retention cleanup.

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
    [int]$RetentionHours = 48,
    [string]$CutoffMode = "db_now"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "preview_epg_retention"
$Component = "epg_retention_preview"
$KillSwitchName = "ENABLE_EPG_RETENTION_PREVIEW"
$DatabaseKey = "content"

$RepoRoot = (Resolve-Path ".").Path
$StartedAt = Get-Date
$Stamp = $StartedAt.ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$RunId = "$WorkerName-$Stamp"

$ReportDir = Join-Path $RepoRoot "runtime\reports\epg_retention_preview"
$LogDir = Join-Path $RepoRoot "runtime\logs\epg_retention_preview"

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$SummaryPath = Join-Path $ReportDir "epg_retention_preview_summary_$Stamp.json"
$DetailPath = Join-Path $ReportDir "epg_retention_preview_$Stamp.csv"
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

function Invoke-ReadSql {
    param([string]$Sql)

    $modulePath = Join-Path $RepoRoot "tools\common\DbQuery.psm1"
    Import-Module $modulePath -Force
    return Invoke-DogOpenProc -DatabaseKey $DatabaseKey -Sql $Sql -TimeoutSec 120
}

try {
    if (-not (Test-KillSwitch)) {
        throw "Worker disabled by $KillSwitchName."
    }

    if ($CutoffMode -notin @("db_now", "import_state")) {
        throw "Invalid CutoffMode '$CutoffMode'. Use db_now or import_state."
    }

    Write-JobLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        retention_hours = $RetentionHours
        cutoff_mode = $CutoffMode
        db_writes = $false
        provider_calls = $false
    })

    Emit-Heartbeat -Status "running"

    if ($CutoffMode -eq "import_state") {
        $cutoffSql = "(SELECT last_successful_epg_import_date FROM epg_import_state WHERE provider = '$Provider' LIMIT 1)"
    }
    else {
        $cutoffSql = "DATE_SUB(NOW(), INTERVAL $RetentionHours HOUR)"
    }

    $sql = @"
SELECT
  NOW() AS db_now,
  $cutoffSql AS cutoff_time,
  COUNT(*) AS total_programs,
  MIN(start_time) AS oldest_start,
  MAX(end_time) AS newest_end,
  SUM(CASE WHEN end_time < $cutoffSql THEN 1 ELSE 0 END) AS purge_candidate_count,
  MIN(CASE WHEN end_time < $cutoffSql THEN start_time ELSE NULL END) AS purge_oldest_start,
  MAX(CASE WHEN end_time < $cutoffSql THEN end_time ELSE NULL END) AS purge_newest_end
FROM epg_programs;
"@

    $result = Invoke-ReadSql -Sql $sql
    $row = @($result.rows)[0]

    $detail = [pscustomobject][ordered]@{
        provider = $Provider
        cutoff_mode = $CutoffMode
        retention_hours = $RetentionHours
        db_now = [string]$row.db_now
        cutoff_time = [string]$row.cutoff_time
        total_programs = [int64]$row.total_programs
        oldest_start = [string]$row.oldest_start
        newest_end = [string]$row.newest_end
        purge_candidate_count = [int64]$row.purge_candidate_count
        purge_oldest_start = [string]$row.purge_oldest_start
        purge_newest_end = [string]$row.purge_newest_end
        preview_disposition = "preview_completed"
    }

    $detail | Export-Csv -NoTypeInformation -Path $DetailPath -Encoding UTF8

    $summary = [pscustomobject][ordered]@{
        run_id = $RunId
        worker_name = $WorkerName
        provider = $Provider
        cutoff_mode = $CutoffMode
        retention_hours = $RetentionHours
        total_programs = $detail.total_programs
        purge_candidate_count = $detail.purge_candidate_count
        db_now = $detail.db_now
        cutoff_time = $detail.cutoff_time
        detail_csv_path = $DetailPath
        db_writes = $false
        provider_calls = $false
        duration_ms = Get-DurationMs -Start $StartedAt
        status = "pass"
    }

    $summary | ConvertTo-Json -Depth 8 | Set-Content -Path $SummaryPath -Encoding UTF8
    Emit-Signal -SignalName "epg_retention_preview_completed" -SignalValue "pass" -Payload $summary
    Write-JobLog -EventName "job_completed" -Status "pass" -Data $summary

    Write-Output "OK: EPG retention preview completed. candidates=$($summary.purge_candidate_count) total=$($summary.total_programs) cutoff=$($summary.cutoff_time) summary=$SummaryPath"
}
catch {
    $summary = [pscustomobject][ordered]@{
        run_id = $RunId
        worker_name = $WorkerName
        provider = $Provider
        cutoff_mode = $CutoffMode
        retention_hours = $RetentionHours
        last_error = $_.Exception.Message
        db_writes = $false
        provider_calls = $false
        duration_ms = Get-DurationMs -Start $StartedAt
        status = "failed"
    }

    $summary | ConvertTo-Json -Depth 8 | Set-Content -Path $SummaryPath -Encoding UTF8
    Emit-Signal -SignalName "epg_retention_preview_completed" -SignalValue "failed" -Payload $summary
    Write-JobLog -EventName "job_failed" -Status "failed" -Data $summary

    throw
}
