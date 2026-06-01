[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [string]$Provider = "default",
    [string]$PreviewCsvPath = "",
    [int]$BatchSize = 500,
    [int]$MaxBatches = 100,
    [switch]$Apply,
    [switch]$AllowDbWrite,
    [string]$WriteAuthorizationCode = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path ".").Path
$WorkerName = "run_epg_programs_delta_apply_queue"
$Stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")

if ([string]::IsNullOrWhiteSpace($PreviewCsvPath)) {
    $PreviewCsvPath = (Get-ChildItem ".\runtime\reports\epg_programs_delta_preview\epg_programs_delta_preview_*.csv" |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1).FullName
}

if (-not (Test-Path $PreviewCsvPath)) {
    throw "Preview CSV not found: $PreviewCsvPath"
}

$QueueDir = Join-Path $RepoRoot "runtime\reports\epg_programs_delta_apply_queue"
New-Item -ItemType Directory -Force $QueueDir | Out-Null

$SummaryPath = Join-Path $QueueDir "epg_programs_delta_apply_queue_summary_$Stamp.json"

function Ensure-QueueColumns {
    param([object[]]$Rows)

    foreach ($row in $Rows) {
        foreach ($name in @("import_status","import_attempt_count","last_import_message","import_completed_at")) {
            if (-not ($row.PSObject.Properties.Name -contains $name)) {
                $row | Add-Member -NotePropertyName $name -NotePropertyValue ""
            }
        }
    }

    return $Rows
}

function Get-Key {
    param([object]$Row)
    return "{0}|{1}|{2}|{3}" -f $Row.epg_channel_id,$Row.start_time,$Row.end_time,$Row.title
}

$totalCompleted = 0
$totalFailed = 0
$batchesRun = 0

for ($batch = 1; $batch -le $MaxBatches; $batch++) {
    $rows = @(Import-Csv -LiteralPath $PreviewCsvPath)
    $rows = @(Ensure-QueueColumns -Rows $rows)

    $pending = @(
        $rows |
        Where-Object {
            $_.preview_disposition -eq "preview_ready" -and
            $_.apply_action -eq "upsert_epg_program" -and
            [string]::IsNullOrWhiteSpace([string]$_.import_status)
        } |
        Select-Object -First $BatchSize
    )

    if ($pending.Count -eq 0) {
        Write-Host "QUEUE EMPTY. Nothing left to process."
        break
    }

    $batchesRun++
    Write-Host "EPG QUEUE BATCH $batch : pending=$($pending.Count)"

    foreach ($p in $pending) {
        $attempt = 0
        [void][int]::TryParse([string]$p.import_attempt_count, [ref]$attempt)
        $p.import_attempt_count = [string]($attempt + 1)
    }

    $BatchPath = Join-Path $QueueDir "epg_programs_delta_apply_batch_${Stamp}_$batch.csv"
    $pending | Export-Csv -NoTypeInformation -Path $BatchPath -Encoding UTF8

    pwsh -NoProfile -ExecutionPolicy Bypass `
      -File ".\tools\workers\apply_epg_programs_delta_limited.ps1" `
      -Environment $Environment `
      -Provider $Provider `
      -PreviewCsvPath $BatchPath `
      -Limit $BatchSize `
      -Apply:$Apply `
      -AllowDbWrite:$AllowDbWrite `
      -WriteAuthorizationCode $WriteAuthorizationCode

    $LatestApply = Get-ChildItem ".\runtime\reports\epg_programs_delta_limited_apply\epg_programs_delta_limited_apply_*.csv" |
      Sort-Object LastWriteTimeUtc -Descending |
      Select-Object -First 1

    $applyRows = @(Import-Csv -LiteralPath $LatestApply.FullName)
    $applyByKey = @{}

    foreach ($a in $applyRows) {
        $applyByKey[(Get-Key -Row $a)] = $a
    }

    foreach ($row in $rows) {
        $key = Get-Key -Row $row
        if ($applyByKey.ContainsKey($key)) {
            $applyRow = $applyByKey[$key]

            if ($applyRow.apply_disposition -eq "apply_completed") {
                $row.import_status = "completed"
                $row.last_import_message = "apply_completed"
                $row.import_completed_at = (Get-Date).ToUniversalTime().ToString("o")
                $totalCompleted++
            }
            elseif ($applyRow.apply_disposition -eq "would_apply") {
                $row.import_status = "completed"
                $row.last_import_message = "dry_run_would_apply"
                $row.import_completed_at = (Get-Date).ToUniversalTime().ToString("o")
                $totalCompleted++
            }
            else {
                $row.import_status = "failed"
                $row.last_import_message = [string]$applyRow.error_message
                $row.import_completed_at = (Get-Date).ToUniversalTime().ToString("o")
                $totalFailed++
            }
        }
    }

    $rows | Export-Csv -NoTypeInformation -Path $PreviewCsvPath -Encoding UTF8
}

$finalRows = @(Import-Csv -LiteralPath $PreviewCsvPath)
$remaining = @($finalRows | Where-Object {
    $_.preview_disposition -eq "preview_ready" -and
    $_.apply_action -eq "upsert_epg_program" -and
    [string]::IsNullOrWhiteSpace([string]$_.import_status)
}).Count

$summary = [pscustomobject][ordered]@{
    worker_name = $WorkerName
    preview_csv_path = $PreviewCsvPath
    batch_size = $BatchSize
    batches_run = $batchesRun
    completed_this_run = $totalCompleted
    failed_this_run = $totalFailed
    remaining_unprocessed = $remaining
    status = if ($remaining -eq 0 -and $totalFailed -eq 0) { "pass" } else { "warning" }
}

$summary | ConvertTo-Json -Depth 6 | Set-Content -Path $SummaryPath -Encoding UTF8

Write-Output "OK: EPG queue runner completed. batches=$batchesRun completed=$totalCompleted failed=$totalFailed remaining=$remaining summary=$SummaryPath"
