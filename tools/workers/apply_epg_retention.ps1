<#
.SYNOPSIS
  Apply EPG program retention cleanup with bounded deletes.

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
    [string]$CutoffMode = "db_now",
    [int]$BatchSize = 5000,
    [int]$MaxBatches = 20,
    [switch]$Apply,
    [switch]$AllowDbWrite,
    [string]$WriteAuthorizationCode = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "apply_epg_retention"
$Component = "epg_retention_apply"
$KillSwitchName = "ENABLE_EPG_RETENTION_APPLY"
$WriteEnvName = "ENABLE_EPG_RETENTION_APPLY_WRITES"
$ExpectedAuthorizationCode = "APPLY_EPG_RETENTION"
$DatabaseKey = "content"

$RepoRoot = (Resolve-Path ".").Path
$StartedAt = Get-Date
$Stamp = $StartedAt.ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$RunId = "$WorkerName-$Stamp"

$ReportDir = Join-Path $RepoRoot "runtime\reports\epg_retention_apply"
$LogDir = Join-Path $RepoRoot "runtime\logs\epg_retention_apply"

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$SummaryPath = Join-Path $ReportDir "epg_retention_apply_summary_$Stamp.json"
$DetailPath = Join-Path $ReportDir "epg_retention_apply_$Stamp.csv"
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

function Test-WriteEnabled {
    $raw = [Environment]::GetEnvironmentVariable($WriteEnvName)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
    return ($raw.Trim().ToLowerInvariant() -in @("1","true","yes","on","enabled"))
}

function Invoke-Sql {
    param([string]$Sql)

    $modulePath = Join-Path $RepoRoot "tools\common\DbQuery.psm1"
    Import-Module $modulePath -Force
    return Invoke-DogOpenProc -DatabaseKey $DatabaseKey -Sql $Sql -TimeoutSec 180
}

try {
    if (-not (Test-KillSwitch)) {
        throw "Worker disabled by $KillSwitchName."
    }

    if ($CutoffMode -notin @("db_now", "import_state")) {
        throw "Invalid CutoffMode '$CutoffMode'. Use db_now or import_state."
    }

    if ($BatchSize -lt 1 -or $BatchSize -gt 50000) {
        throw "BatchSize must be between 1 and 50000."
    }

    if ($MaxBatches -lt 1 -or $MaxBatches -gt 500) {
        throw "MaxBatches must be between 1 and 500."
    }

    $writeEnabled = Test-WriteEnabled
    $authorized = ($Apply -and $AllowDbWrite -and $writeEnabled -and $WriteAuthorizationCode -eq $ExpectedAuthorizationCode)
    $dryRun = -not $authorized

    Write-JobLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        retention_hours = $RetentionHours
        cutoff_mode = $CutoffMode
        batch_size = $BatchSize
        max_batches = $MaxBatches
        apply = [bool]$Apply
        allow_db_write = [bool]$AllowDbWrite
        write_env_enabled = $writeEnabled
        authorized = $authorized
        dry_run = $dryRun
        db_writes = $authorized
        provider_calls = $false
    })

    Emit-Heartbeat -Status "running"

    if ($CutoffMode -eq "import_state") {
        $cutoffSql = "(SELECT last_successful_epg_import_date FROM epg_import_state WHERE provider = '$Provider' LIMIT 1)"
    }
    else {
        $cutoffSql = "DATE_SUB(NOW(), INTERVAL $RetentionHours HOUR)"
    }

    $previewSql = @"
SELECT
  NOW() AS db_now,
  $cutoffSql AS cutoff_time,
  COUNT(*) AS total_programs,
  SUM(CASE WHEN end_time < $cutoffSql THEN 1 ELSE 0 END) AS purge_candidate_count,
  MIN(CASE WHEN end_time < $cutoffSql THEN start_time ELSE NULL END) AS purge_oldest_start,
  MAX(CASE WHEN end_time < $cutoffSql THEN end_time ELSE NULL END) AS purge_newest_end
FROM epg_programs;
"@

    $previewResult = Invoke-Sql -Sql $previewSql
    $preview = @($previewResult.rows)[0]
    $candidateCount = [int64]$preview.purge_candidate_count

    $rows = New-Object System.Collections.Generic.List[object]
    $totalDeleted = 0
    $batchesRun = 0

    if ($dryRun -or $candidateCount -le 0) {
        $rows.Add([pscustomobject][ordered]@{
            batch_number = 0
            apply_disposition = if ($dryRun) { "dry_run_no_write" } else { "no_candidates" }
            rows_deleted = 0
            candidate_count_before = $candidateCount
            error_message = ""
        })
    }
    else {
        for ($batch = 1; $batch -le $MaxBatches; $batch++) {
            Emit-Heartbeat -Status "batch_$batch"

            $countSql = "SELECT COUNT(*) AS candidates FROM epg_programs WHERE end_time < $cutoffSql;"
            $countResult = Invoke-Sql -Sql $countSql
            $remainingBefore = [int64](@($countResult.rows)[0]).candidates

            if ($remainingBefore -le 0) {
                break
            }

            $deleteSql = "DELETE FROM epg_programs WHERE end_time < $cutoffSql LIMIT $BatchSize;"
            $deleteResult = Invoke-Sql -Sql $deleteSql

            $rowsAffected = 0
            if ($deleteResult.PSObject.Properties.Name -contains "rows_affected") {
                [void][int]::TryParse([string]$deleteResult.rows_affected, [ref]$rowsAffected)
            }
            elseif ($deleteResult.PSObject.Properties.Name -contains "affected_rows") {
                [void][int]::TryParse([string]$deleteResult.affected_rows, [ref]$rowsAffected)
            }
            elseif ($deleteResult.PSObject.Properties.Name -contains "rowsAffected") {
                [void][int]::TryParse([string]$deleteResult.rowsAffected, [ref]$rowsAffected)
            }

            $batchesRun++
            $totalDeleted += $rowsAffected

            $rows.Add([pscustomobject][ordered]@{
                batch_number = $batch
                apply_disposition = "delete_attempted"
                rows_deleted = $rowsAffected
                candidate_count_before = $remainingBefore
                error_message = ""
            })

            Write-JobLog -EventName "batch_completed" -Status "ok" -Data ([ordered]@{
                batch_number = $batch
                rows_deleted = $rowsAffected
                candidate_count_before = $remainingBefore
            })

            if ($rowsAffected -le 0) {
                break
            }
        }
    }

    $rows | Export-Csv -NoTypeInformation -Path $DetailPath -Encoding UTF8

    $postSql = @"
SELECT
  COUNT(*) AS total_programs_after,
  SUM(CASE WHEN end_time < $cutoffSql THEN 1 ELSE 0 END) AS purge_candidate_count_after,
  MIN(start_time) AS oldest_start_after,
  MAX(end_time) AS newest_end_after
FROM epg_programs;
"@

    $postResult = Invoke-Sql -Sql $postSql
    $post = @($postResult.rows)[0]

    $summary = [pscustomobject][ordered]@{
        run_id = $RunId
        worker_name = $WorkerName
        provider = $Provider
        cutoff_mode = $CutoffMode
        retention_hours = $RetentionHours
        batch_size = $BatchSize
        max_batches = $MaxBatches
        dry_run = $dryRun
        authorized = $authorized
        db_now = [string]$preview.db_now
        cutoff_time = [string]$preview.cutoff_time
        candidate_count_before = $candidateCount
        batches_run = $batchesRun
        rows_deleted = $totalDeleted
        total_programs_after = [int64]$post.total_programs_after
        candidate_count_after = [int64]$post.purge_candidate_count_after
        oldest_start_after = [string]$post.oldest_start_after
        newest_end_after = [string]$post.newest_end_after
        detail_csv_path = $DetailPath
        db_writes = $authorized
        provider_calls = $false
        duration_ms = Get-DurationMs -Start $StartedAt
        status = "pass"
    }

    $summary | ConvertTo-Json -Depth 8 | Set-Content -Path $SummaryPath -Encoding UTF8
    Emit-Signal -SignalName "epg_retention_apply_completed" -SignalValue "pass" -Payload $summary
    Write-JobLog -EventName "job_completed" -Status "pass" -Data $summary

    Write-Output "OK: EPG retention apply completed. dry_run=$dryRun candidates_before=$candidateCount deleted=$totalDeleted candidates_after=$($summary.candidate_count_after) summary=$SummaryPath"
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
    Emit-Signal -SignalName "epg_retention_apply_completed" -SignalValue "failed" -Payload $summary
    Write-JobLog -EventName "job_failed" -Status "failed" -Data $summary

    throw
}
