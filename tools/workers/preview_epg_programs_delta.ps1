[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [string]$Provider = "default",
    [string]$PlanCsvPath = "",
    [int]$Limit = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path ".").Path
$Stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$RunId = "epg-delta-preview-$Stamp"

$OutDir = Join-Path $RepoRoot "runtime\reports\epg_programs_delta_preview"
$LogDir = Join-Path $RepoRoot "runtime\logs\epg_programs_delta_preview"

New-Item -ItemType Directory -Force $OutDir | Out-Null
New-Item -ItemType Directory -Force $LogDir | Out-Null

$PreviewCsvPath = Join-Path $OutDir "epg_programs_delta_preview_$Stamp.csv"
$SummaryPath = Join-Path $OutDir "epg_programs_delta_preview_summary_$Stamp.json"
$LogPath = Join-Path $LogDir "preview_epg_programs_delta-$((Get-Date).ToUniversalTime().ToString('yyyyMMdd')).jsonl"

function Write-Event {
    param([hashtable]$Event)

    $Event.run_id = $RunId
    $Event.worker_name = "preview_epg_programs_delta"
    $Event.component = "epg_programs_delta_preview"
    $Event.environment = $Environment
    $Event.provider = $Provider
    $Event.timestamp = (Get-Date).ToUniversalTime().ToString("o")

    ($Event | ConvertTo-Json -Depth 8 -Compress) | Add-Content -Path $LogPath -Encoding UTF8
}

if ([string]::IsNullOrWhiteSpace($PlanCsvPath)) {
    $latest = Get-ChildItem (Join-Path $RepoRoot "runtime\reports\epg_programs_delta_plan") -File |
        Where-Object { $_.Name -match "^epg_programs_delta_plan_\d{8}T\d{6}Z\.csv$" } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $latest) {
        throw "No EPG delta plan CSV found."
    }

    $PlanCsvPath = $latest.FullName
}

Write-Event @{
    event_type = "job_started"
    status = "started"
    source_name = $PlanCsvPath
    db_writes = $false
    provider_calls = $false
}

$rows = @(Import-Csv -LiteralPath $PlanCsvPath)

if ($Limit -gt 0) {
    $rows = @($rows | Select-Object -First $Limit)
}

$preview = New-Object System.Collections.Generic.List[object]
$total = 0
$planned = 0
$invalid = 0

foreach ($row in $rows) {
    $total++

    $disposition = [string]$row.row_disposition

    if ($disposition -eq "planned_import") {
        $planned++
        $previewDisposition = "preview_ready"
        $action = "upsert_epg_program"
    }
    else {
        $invalid++
        $previewDisposition = "preview_blocked"
        $action = "none"
    }

    $naturalKeyParts = @(
        [string]$row.epg_channel_id
        [string]$row.start_time
        [string]$row.end_time
        [string]$row.title
    )
    $naturalKey = $naturalKeyParts -join "|"

    $previewRow = [pscustomobject][ordered]@{
        preview_disposition = $previewDisposition
        row_disposition = $disposition
        provider = [string]$row.provider
        epg_channel_id = [string]$row.epg_channel_id
        channel = [string]$row.channel
        title = [string]$row.title
        description = [string]$row.description
        start_time = [string]$row.start_time
        end_time = [string]$row.end_time
        catchup = [string]$row.catchup
        provider_channel_id = [string]$row.provider_channel_id
        canonical_channel = [string]$row.canonical_channel
        apply_action = $action
        natural_key = $naturalKey
        source_plan = $PlanCsvPath
    }

    $preview.Add($previewRow)
}

$preview | Export-Csv -NoTypeInformation -Path $PreviewCsvPath -Encoding UTF8

$summary = [pscustomobject][ordered]@{
    run_id = $RunId
    provider = $Provider
    source_plan_csv = $PlanCsvPath
    total_rows_seen = $total
    preview_ready = $planned
    preview_blocked = $invalid
    preview_csv_path = $PreviewCsvPath
    db_writes = $false
    provider_calls = $false
    status = if ($total -gt 0 -and $planned -gt 0) { "pass" } else { "warning" }
}

$summary | ConvertTo-Json -Depth 6 | Set-Content -Path $SummaryPath -Encoding UTF8

Write-Event @{
    event_type = "job_completed"
    status = $summary.status
    source_row_count = $total
    preview_ready = $planned
    preview_blocked = $invalid
    db_writes = $false
    provider_calls = $false
    summary_path = $SummaryPath
}

Write-Output "OK: EPG delta preview completed. preview_ready=$planned preview_blocked=$invalid summary=$SummaryPath"
