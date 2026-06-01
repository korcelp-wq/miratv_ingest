<#
.SYNOPSIS
  Preview actionable top-level Series delta from the latest plan CSV.

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
    [string]$PlanCsvPath = "",
    [int]$Limit = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "preview_series_top_level_delta"
$Component = "series_top_level_delta_preview"
$KillSwitchName = "ENABLE_SERIES_TOP_LEVEL_DELTA_PREVIEW"

$RepoRoot = (Resolve-Path ".").Path
$StartedAt = Get-Date
$Stamp = $StartedAt.ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$RunId = "$WorkerName-$Stamp"

$ReportDir = Join-Path $RepoRoot "runtime\reports\series_top_level_delta_preview"
$LogDir = Join-Path $RepoRoot "runtime\logs\series_top_level_delta_preview"

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$CsvPath = Join-Path $ReportDir "series_top_level_delta_preview_$Stamp.csv"
$SummaryPath = Join-Path $ReportDir "series_top_level_delta_preview_summary_$Stamp.json"
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

function Get-LatestPlanCsv {
    $latest = Get-ChildItem (Join-Path $RepoRoot "runtime\reports\series_top_level_delta_plan\series_top_level_delta_plan_*.csv") |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if (-not $latest) {
        throw "No series_top_level_delta_plan CSV found."
    }

    return $latest.FullName
}

try {
    if (-not (Test-KillSwitch)) {
        throw "Worker disabled by $KillSwitchName."
    }

    Write-JobLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        plan_csv_path = $PlanCsvPath
        limit = $Limit
        db_writes = $false
        provider_calls = $false
        tmdb_calls = $false
    })

    Emit-Heartbeat -Status "loading_plan"

    if ([string]::IsNullOrWhiteSpace($PlanCsvPath)) {
        $PlanCsvPath = Get-LatestPlanCsv
    }

    if (-not (Test-Path -LiteralPath $PlanCsvPath)) {
        throw "PlanCsvPath not found: $PlanCsvPath"
    }

    $allRows = @(Import-Csv -LiteralPath $PlanCsvPath)

    $actionRows = @(
        $allRows | Where-Object {
            $_.row_disposition -in @("planned_insert", "planned_update")
        }
    )

    if ($Limit -gt 0) {
        $actionRows = @($actionRows | Select-Object -First $Limit)
    }

    Emit-Heartbeat -Status "building_preview"

    $previewRows = foreach ($row in $actionRows) {
        $previewDisposition = switch ($row.row_disposition) {
            "planned_insert" { "preview_insert_ready" }
            "planned_update" { "preview_update_ready" }
            default { "preview_ignored" }
        }

        [pscustomobject][ordered]@{
            import_status = ""
            preview_disposition = $previewDisposition
            row_disposition = $row.row_disposition
            change_reasons = $row.change_reasons
            provider = $row.provider
            provider_series_id = $row.provider_series_id
            provider_name = $row.provider_name
            display_clean_name = $row.display_clean_name
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
            local_ingest_hash = $row.local_ingest_hash
        }
    }

    $previewRows | Export-Csv -NoTypeInformation -Path $CsvPath -Encoding UTF8

    $summary = [pscustomobject][ordered]@{
        run_id = $RunId
        worker_name = $WorkerName
        provider = $Provider
        source_plan_csv = $PlanCsvPath
        total_plan_rows = $allRows.Count
        preview_rows = @($previewRows).Count
        preview_insert_ready = @($previewRows | Where-Object { $_.preview_disposition -eq "preview_insert_ready" }).Count
        preview_update_ready = @($previewRows | Where-Object { $_.preview_disposition -eq "preview_update_ready" }).Count
        limit = $Limit
        db_writes = $false
        provider_calls = $false
        tmdb_calls = $false
        report_csv = $CsvPath
        duration_ms = Get-DurationMs -Start $StartedAt
        status = "pass"
    }

    $summary | ConvertTo-Json -Depth 8 | Set-Content -Path $SummaryPath -Encoding UTF8

    Emit-Signal -SignalName "series_top_level_delta_preview_completed" -SignalValue "pass" -Payload $summary
    Write-JobLog -EventName "job_completed" -Status "pass" -Data $summary

    Write-Output "OK: Series top-level delta preview completed. rows=$($summary.preview_rows) inserts=$($summary.preview_insert_ready) updates=$($summary.preview_update_ready) summary=$SummaryPath"
}
catch {
    $summary = [pscustomobject][ordered]@{
        run_id = $RunId
        worker_name = $WorkerName
        provider = $Provider
        source_plan_csv = $PlanCsvPath
        last_error = $_.Exception.Message
        db_writes = $false
        provider_calls = $false
        tmdb_calls = $false
        duration_ms = Get-DurationMs -Start $StartedAt
        status = "failed"
    }

    $summary | ConvertTo-Json -Depth 8 | Set-Content -Path $SummaryPath -Encoding UTF8
    Emit-Signal -SignalName "series_top_level_delta_preview_completed" -SignalValue "failed" -Payload $summary
    Write-JobLog -EventName "job_failed" -Status "failed" -Data $summary
    throw
}
