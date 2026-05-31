[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [string]$Provider = "default",
    [string]$SnapshotCsvPath = "",
    [int]$Limit = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path ".").Path
$Stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$RunId = "epg-delta-plan-$Stamp"

$OutDir = Join-Path $RepoRoot "runtime\reports\epg_programs_delta_plan"
$LogDir = Join-Path $RepoRoot "runtime\logs\epg_programs_delta_plan"

New-Item -ItemType Directory -Force $OutDir | Out-Null
New-Item -ItemType Directory -Force $LogDir | Out-Null

$PlanCsvPath = Join-Path $OutDir "epg_programs_delta_plan_$Stamp.csv"
$SummaryPath = Join-Path $OutDir "epg_programs_delta_plan_summary_$Stamp.json"
$LogPath = Join-Path $LogDir "plan_epg_programs_delta-$((Get-Date).ToUniversalTime().ToString('yyyyMMdd')).jsonl"

function Write-Event {
    param([hashtable]$Event)

    $Event.run_id = $RunId
    $Event.worker_name = "plan_epg_programs_delta"
    $Event.component = "epg_programs_delta_plan"
    $Event.environment = $Environment
    $Event.provider = $Provider
    $Event.timestamp = (Get-Date).ToUniversalTime().ToString("o")

    ($Event | ConvertTo-Json -Depth 8 -Compress) | Add-Content -Path $LogPath -Encoding UTF8
}

if ([string]::IsNullOrWhiteSpace($SnapshotCsvPath)) {
    $latest = Get-ChildItem (Join-Path $RepoRoot "runtime\provider_snapshots\epg") -File |
        Where-Object { $_.Name -match "^provider_epg_snapshot_\d{8}T\d{6}Z\.csv$" } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $latest) {
        throw "No EPG snapshot CSV found."
    }

    $SnapshotCsvPath = $latest.FullName
}

Write-Event @{
    event_type = "job_started"
    status = "started"
    source_name = $SnapshotCsvPath
}

$rows = @(Import-Csv -LiteralPath $SnapshotCsvPath)

if ($Limit -gt 0) {
    $rows = @($rows | Select-Object -First $Limit)
}

$planned = New-Object System.Collections.Generic.List[object]
$seen = 0
$failed = 0

foreach ($row in $rows) {
    $seen++

    $providerValue = if ([string]::IsNullOrWhiteSpace([string]$row.provider)) { $Provider } else { [string]$row.provider }

    if ([string]::IsNullOrWhiteSpace([string]$row.epg_channel_id) -or
        [string]::IsNullOrWhiteSpace([string]$row.start_time) -or
        [string]::IsNullOrWhiteSpace([string]$row.end_time)) {
        $failed++
        $planned.Add([pscustomobject][ordered]@{
            row_disposition = "invalid_missing_required_fields"
            provider = $providerValue
            epg_channel_id = [string]$row.epg_channel_id
            channel = [string]$row.channel
            title = [string]$row.title
            description = [string]$row.description
            start_time = [string]$row.start_time
            end_time = [string]$row.end_time
            catchup = [string]$row.catchup
            provider_channel_id = [string]$row.provider_channel_id
            canonical_channel = [string]$row.canonical_channel
            plan_reason = "missing epg_channel_id/start_time/end_time"
        })
        continue
    }

    $planned.Add([pscustomobject][ordered]@{
        row_disposition = "planned_import"
        provider = $providerValue
        epg_channel_id = [string]$row.epg_channel_id
        channel = [string]$row.channel
        title = [string]$row.title
        description = [string]$row.description
        start_time = [string]$row.start_time
        end_time = [string]$row.end_time
        catchup = [string]$row.catchup
        provider_channel_id = [string]$row.provider_channel_id
        canonical_channel = [string]$row.canonical_channel
        plan_reason = "snapshot_delta_row"
    })
}

$planned | Export-Csv -NoTypeInformation -Path $PlanCsvPath -Encoding UTF8

$plannedImportCount = @($planned | Where-Object { $_.row_disposition -eq "planned_import" }).Count
$invalidCount = @($planned | Where-Object { $_.row_disposition -ne "planned_import" }).Count

$summary = [pscustomobject][ordered]@{
    run_id = $RunId
    provider = $Provider
    source_snapshot_csv = $SnapshotCsvPath
    total_rows_seen = $seen
    planned_import = $plannedImportCount
    invalid_rows = $invalidCount
    plan_csv_path = $PlanCsvPath
    status = if ($seen -gt 0 -and $plannedImportCount -gt 0) { "pass" } else { "warning" }
}

$summary | ConvertTo-Json -Depth 6 | Set-Content -Path $SummaryPath -Encoding UTF8

Write-Event @{
    event_type = "job_completed"
    status = $summary.status
    source_row_count = $seen
    planned_import = $plannedImportCount
    rows_failed = $failed
    summary_path = $SummaryPath
}

Write-Output "OK: EPG delta plan completed. planned_import=$plannedImportCount invalid=$invalidCount summary=$SummaryPath"
