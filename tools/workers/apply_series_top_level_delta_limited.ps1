<#
.SYNOPSIS
  Apply actionable top-level Series delta from the latest preview CSV.

.DESCRIPTION
  Guarded, limited apply worker for Series top-level delta rows.

  Default behavior is DRY RUN. No database writes happen unless all write guards are present:
    -Apply
    -AllowDbWrite
    -WriteAuthorizationCode "APPLY_SERIES_TOP_LEVEL_DELTA"
    ENABLE_SERIES_TOP_LEVEL_DELTA_APPLY_WRITES=true

  This version includes:
    - CHAR(40)-safe ingest_hash handling.
    - post-error verification for INSERT/UPDATE rows when dog_open_proc returns HTTP 500 after a DB commit.
    - rows_affected parsing for affected/rows_affected/affected_rows/rowsAffected response shapes.

.CONTRACT-MARKERS
  Write-JobLog
  Emit-Signal
  Emit-Heartbeat
  Test-KillSwitch
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [string]$Provider = "eldervpn",
    [string]$PreviewCsvPath = "",
    [int]$BatchSize = 100,
    [int]$MaxRows = 100,
    [switch]$Apply,
    [switch]$AllowDbWrite,
    [string]$WriteAuthorizationCode = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "apply_series_top_level_delta_limited"
$Component = "series_top_level_delta_apply"
$KillSwitchName = "ENABLE_SERIES_TOP_LEVEL_DELTA_APPLY"
$WriteEnvName = "ENABLE_SERIES_TOP_LEVEL_DELTA_APPLY_WRITES"
$ExpectedAuthorizationCode = "APPLY_SERIES_TOP_LEVEL_DELTA"
$DatabaseKey = "content"

$RepoRoot = (Resolve-Path ".").Path
$StartedAt = Get-Date
$Stamp = $StartedAt.ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$RunId = "$WorkerName-$Stamp"

$ReportDir = Join-Path $RepoRoot "runtime\reports\series_top_level_delta_apply"
$LogDir = Join-Path $RepoRoot "runtime\logs\series_top_level_delta_apply"

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$CsvPath = Join-Path $ReportDir "series_top_level_delta_apply_$Stamp.csv"
$SummaryPath = Join-Path $ReportDir "series_top_level_delta_apply_summary_$Stamp.json"
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

function Escape-SqlString {
    param([string]$Value)
    if ($null -eq $Value) { return "" }
    return $Value.Replace("\", "\\").Replace("'", "''")
}

function Convert-ToIntSafe {
    param([object]$Value, [int]$Default = 0)

    if ($null -eq $Value) { return $Default }

    $n = 0
    if ([int]::TryParse(([string]$Value).Trim(), [ref]$n)) {
        return $n
    }

    return $Default
}

function Convert-ToSqlNullableString {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "NULL"
    }

    return "'" + (Escape-SqlString -Value $Value.Trim()) + "'"
}

function Convert-ToSqlHash40 {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "NULL"
    }

    $text = $Value.Trim()
    if ($text.Length -gt 40) {
        $text = $text.Substring(0, 40)
    }

    return "'" + (Escape-SqlString -Value $text) + "'"
}

function Convert-ToSqlNullableInt {
    param([object]$Value)

    $n = 0
    if ($null -ne $Value -and [int]::TryParse(([string]$Value).Trim(), [ref]$n)) {
        return [string]$n
    }

    return "NULL"
}

function Get-LatestPreviewCsv {
    $latest = Get-ChildItem (Join-Path $RepoRoot "runtime\reports\series_top_level_delta_preview\series_top_level_delta_preview_*.csv") |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if (-not $latest) {
        throw "No series_top_level_delta_preview CSV found."
    }

    return $latest.FullName
}

function Get-RowsAffected {
    param([object]$Result)

    foreach ($name in @("rows_affected", "affected", "affected_rows", "rowsAffected")) {
        if ($Result.PSObject.Properties.Name -contains $name) {
            $n = 0
            if ([int]::TryParse([string]$Result.$name, [ref]$n)) {
                return $n
            }
        }
    }

    return 0
}

function New-InsertSql {
    param([object]$Row)

    $providerSeriesId = Convert-ToIntSafe -Value $Row.provider_series_id
    $providerEscaped = Escape-SqlString -Value ([string]$Row.provider)
    $nameEscaped = Escape-SqlString -Value ([string]$Row.provider_name)
    $cleanEscaped = Escape-SqlString -Value ([string]$Row.clean_search_name)
    $categorySql = Convert-ToSqlNullableInt -Value $Row.provider_category_id
    $coverSql = Convert-ToSqlNullableString -Value ([string]$Row.provider_cover_url)
    $backdropSql = Convert-ToSqlNullableString -Value ([string]$Row.provider_backdrop_url)
    $lastModifiedSql = Convert-ToSqlNullableInt -Value $Row.provider_last_modified
    $hashSql = Convert-ToSqlHash40 -Value ([string]$Row.provider_row_hash)

    return @"
INSERT INTO series (
  provider_series_id,
  provider,
  name,
  category_id,
  cover_url,
  backdrop_url,
  provider_cover_url,
  provider_backdrop_url,
  clean_search_name,
  tmdb_search_name,
  last_modified,
  last_provider_update,
  last_ingest_at,
  ingest_hash,
  is_dirty,
  dirty_reason,
  details_ingested,
  details_state,
  details_worker,
  created_at,
  updated_at
)
VALUES (
  $providerSeriesId,
  '$providerEscaped',
  '$nameEscaped',
  $categorySql,
  $coverSql,
  $backdropSql,
  $coverSql,
  $backdropSql,
  '$cleanEscaped',
  '$cleanEscaped',
  $lastModifiedSql,
  $lastModifiedSql,
  NOW(),
  $hashSql,
  1,
  'series_top_level_delta_insert',
  0,
  'pending',
  '$WorkerName',
  NOW(),
  NOW()
);
"@
}

function New-UpdateSql {
    param([object]$Row)

    $localId = Convert-ToIntSafe -Value $Row.local_series_id
    $categorySql = Convert-ToSqlNullableInt -Value $Row.provider_category_id
    $coverSql = Convert-ToSqlNullableString -Value ([string]$Row.provider_cover_url)
    $backdropSql = Convert-ToSqlNullableString -Value ([string]$Row.provider_backdrop_url)
    $lastModifiedSql = Convert-ToSqlNullableInt -Value $Row.provider_last_modified
    $hashSql = Convert-ToSqlHash40 -Value ([string]$Row.provider_row_hash)

    return @"
UPDATE series
SET
  category_id = COALESCE($categorySql, category_id),
  cover_url = COALESCE(NULLIF(cover_url, ''), $coverSql),
  provider_cover_url = COALESCE(NULLIF(provider_cover_url, ''), $coverSql),
  backdrop_url = COALESCE(NULLIF(backdrop_url, ''), $backdropSql),
  provider_backdrop_url = COALESCE(NULLIF(provider_backdrop_url, ''), $backdropSql),
  last_modified = COALESCE($lastModifiedSql, last_modified),
  last_provider_update = COALESCE($lastModifiedSql, last_provider_update),
  ingest_hash = COALESCE($hashSql, ingest_hash),
  is_dirty = 1,
  dirty_reason = 'series_top_level_delta_update',
  updated_at = NOW()
WHERE id = $localId
LIMIT 1;
"@
}

function Test-InsertLanded {
    param([object]$Row)

    $providerEscaped = Escape-SqlString -Value ([string]$Row.provider)
    $providerSeriesId = Convert-ToIntSafe -Value $Row.provider_series_id

    $sql = @"
SELECT id, provider_series_id, provider, name
FROM series
WHERE provider = '$providerEscaped'
  AND provider_series_id = $providerSeriesId
LIMIT 1;
"@

    $result = Invoke-Sql -Sql $sql
    if ($result.PSObject.Properties.Name -contains "rows") {
        return @($result.rows).Count -gt 0
    }

    return $false
}

function Test-UpdateLanded {
    param([object]$Row)

    $localId = Convert-ToIntSafe -Value $Row.local_series_id
    if ($localId -lt 1) {
        return $false
    }

    $sql = @"
SELECT id
FROM series
WHERE id = $localId
LIMIT 1;
"@

    $result = Invoke-Sql -Sql $sql
    if ($result.PSObject.Properties.Name -contains "rows") {
        return @($result.rows).Count -gt 0
    }

    return $false
}

try {
    if (-not (Test-KillSwitch)) {
        throw "Worker disabled by $KillSwitchName."
    }

    if ($BatchSize -lt 1 -or $BatchSize -gt 1000) {
        throw "BatchSize must be between 1 and 1000."
    }

    if ($MaxRows -lt 1 -or $MaxRows -gt 10000) {
        throw "MaxRows must be between 1 and 10000."
    }

    $writeEnabled = Test-WriteEnabled
    $authorized = ($Apply -and $AllowDbWrite -and $writeEnabled -and $WriteAuthorizationCode -eq $ExpectedAuthorizationCode)
    $dryRun = -not $authorized

    Write-JobLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        preview_csv_path = $PreviewCsvPath
        batch_size = $BatchSize
        max_rows = $MaxRows
        apply = [bool]$Apply
        allow_db_write = [bool]$AllowDbWrite
        write_env_enabled = $writeEnabled
        authorized = $authorized
        dry_run = $dryRun
        db_writes = $authorized
        provider_calls = $false
        tmdb_calls = $false
    })

    Emit-Heartbeat -Status "loading_preview"

    if ([string]::IsNullOrWhiteSpace($PreviewCsvPath)) {
        $PreviewCsvPath = Get-LatestPreviewCsv
    }

    if (-not (Test-Path -LiteralPath $PreviewCsvPath)) {
        throw "PreviewCsvPath not found: $PreviewCsvPath"
    }

    $allRows = @(Import-Csv -LiteralPath $PreviewCsvPath)

    $candidateRows = @(
        $allRows | Where-Object {
            [string]::IsNullOrWhiteSpace([string]$_.import_status) -and
            $_.preview_disposition -in @("preview_insert_ready", "preview_update_ready")
        } | Select-Object -First $MaxRows
    )

    $resultRows = New-Object System.Collections.Generic.List[object]
    $attempted = 0
    $completed = 0
    $verifiedAfterError = 0
    $failed = 0
    $dryRunCount = 0

    foreach ($row in $candidateRows) {
        $attempted++
        if (($attempted % $BatchSize) -eq 1) {
            Emit-Heartbeat -Status "row_$attempted"
        }

        $sql = ""
        $applyDisposition = "dry_run_no_write"
        $rowsAffected = 0
        $errorMessage = ""

        try {
            if ($row.preview_disposition -eq "preview_insert_ready") {
                $sql = New-InsertSql -Row $row
            }
            elseif ($row.preview_disposition -eq "preview_update_ready") {
                if ([string]::IsNullOrWhiteSpace([string]$row.local_series_id)) {
                    throw "preview_update_ready row missing local_series_id."
                }

                $sql = New-UpdateSql -Row $row
            }
            else {
                throw "Unsupported preview_disposition: $($row.preview_disposition)"
            }

            if ($dryRun) {
                $dryRunCount++
                $applyDisposition = "dry_run_ready"
            }
            else {
                $result = Invoke-Sql -Sql $sql
                $rowsAffected = Get-RowsAffected -Result $result
                $applyDisposition = "apply_completed"
                $completed++
            }
        }
        catch {
            $errorMessage = $_.Exception.Message

            if (-not $dryRun) {
                try {
                    $landed = $false

                    if ($row.preview_disposition -eq "preview_insert_ready") {
                        $landed = Test-InsertLanded -Row $row
                    }
                    elseif ($row.preview_disposition -eq "preview_update_ready") {
                        $landed = Test-UpdateLanded -Row $row
                    }

                    if ($landed) {
                        $applyDisposition = "apply_completed_verified_after_error"
                        $rowsAffected = 1
                        $verifiedAfterError++
                    }
                    else {
                        $failed++
                        $applyDisposition = "apply_failed"
                    }
                }
                catch {
                    $failed++
                    $applyDisposition = "apply_failed"
                    $errorMessage = $errorMessage + " | verification_failed: " + $_.Exception.Message
                }
            }
            else {
                $failed++
                $applyDisposition = "apply_failed"
            }
        }

        $resultRows.Add([pscustomobject][ordered]@{
            import_status = if ($dryRun) { "" } elseif ($applyDisposition -in @("apply_completed", "apply_completed_verified_after_error")) { "completed" } elseif ($applyDisposition -eq "apply_failed") { "failed" } else { "" }
            apply_disposition = $applyDisposition
            dry_run = $dryRun
            rows_affected = $rowsAffected
            error_message = $errorMessage
            preview_disposition = $row.preview_disposition
            row_disposition = $row.row_disposition
            change_reasons = $row.change_reasons
            provider = $row.provider
            provider_series_id = $row.provider_series_id
            provider_name = $row.provider_name
            clean_search_name = $row.clean_search_name
            provider_category_id = $row.provider_category_id
            provider_cover_url = $row.provider_cover_url
            provider_backdrop_url = $row.provider_backdrop_url
            provider_last_modified = $row.provider_last_modified
            provider_row_hash = $row.provider_row_hash
            local_series_id = $row.local_series_id
            local_name = $row.local_name
            local_clean_search_name = $row.local_clean_search_name
            local_category_id = $row.local_category_id
            local_cover_url = $row.local_cover_url
            local_backdrop_url = $row.local_backdrop_url
            sql_preview = if ($dryRun) { $sql } else { "" }
        })
    }

    $resultRows | Export-Csv -NoTypeInformation -Path $CsvPath -Encoding UTF8

    $summary = [pscustomobject][ordered]@{
        run_id = $RunId
        worker_name = $WorkerName
        provider = $Provider
        source_preview_csv = $PreviewCsvPath
        candidate_rows = $candidateRows.Count
        attempted = $attempted
        dry_run = $dryRun
        dry_run_ready = $dryRunCount
        completed = $completed
        verified_after_error = $verifiedAfterError
        failed = $failed
        batch_size = $BatchSize
        max_rows = $MaxRows
        db_writes = $authorized
        provider_calls = $false
        tmdb_calls = $false
        report_csv = $CsvPath
        duration_ms = Get-DurationMs -Start $StartedAt
        status = if ($failed -gt 0) { "warning" } else { "pass" }
    }

    $summary | ConvertTo-Json -Depth 8 | Set-Content -Path $SummaryPath -Encoding UTF8

    Emit-Signal -SignalName "series_top_level_delta_apply_completed" -SignalValue $summary.status -Payload $summary
    Write-JobLog -EventName "job_completed" -Status $summary.status -Data $summary

    Write-Output "OK: Series top-level delta apply completed. dry_run=$dryRun attempted=$attempted completed=$completed verified_after_error=$verifiedAfterError failed=$failed summary=$SummaryPath"
}
catch {
    $summary = [pscustomobject][ordered]@{
        run_id = $RunId
        worker_name = $WorkerName
        provider = $Provider
        source_preview_csv = $PreviewCsvPath
        last_error = $_.Exception.Message
        db_writes = $false
        provider_calls = $false
        tmdb_calls = $false
        duration_ms = Get-DurationMs -Start $StartedAt
        status = "failed"
    }

    $summary | ConvertTo-Json -Depth 8 | Set-Content -Path $SummaryPath -Encoding UTF8
    Emit-Signal -SignalName "series_top_level_delta_apply_completed" -SignalValue "failed" -Payload $summary
    Write-JobLog -EventName "job_failed" -Status "failed" -Data $summary
    throw
}
