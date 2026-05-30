<#
.SYNOPSIS
  Audit provider snapshot and VOD import data reality.

.DESCRIPTION
  Read-only data reality audit.

  This worker answers:
    - Do provider snapshot files exist?
    - How many snapshot files exist by lane?
    - What are the latest snapshot files?
    - How many rows/items are in latest snapshots when countable?
    - What are the latest delta/import preview summaries?
    - How many planned_import rows exist?
    - How many rows are skipped as provider noise?
    - Why is the current import selector resolving to noop/no candidate?

  It does not call providers.
  It does not read DB.
  It does not write DB.
  It does not mutate snapshots.

.CONTRACT-MARKERS
  Write-JobLog
  Emit-Signal
  Emit-Heartbeat
  Test-KillSwitch
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [int]$SampleRows = 10,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "audit_provider_snapshot_data_reality"
$Component = "provider_snapshot_data_reality"
$DatabaseTarget = "none"
$SourceName = "runtime_provider_snapshots_and_reports"
$KillSwitchName = "ENABLE_PROVIDER_SNAPSHOT_DATA_REALITY_AUDIT"

$CompletedSignal = "provider_snapshot_data_reality_audit_completed"
$DispositionSignal = "provider_snapshot_data_reality_audit_disposition"
$SnapshotCountSignal = "provider_snapshot_data_reality_snapshot_count"
$PlannedImportCountSignal = "provider_snapshot_data_reality_planned_import_count"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\provider_snapshot_data_reality"
$LogRoot = Join-Path $RepoRoot "runtime\logs\provider_snapshot_data_reality"

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null

function Get-DurationMs {
    param([datetime]$Start)
    return [int][Math]::Round(((Get-Date) - $Start).TotalMilliseconds)
}

function Write-LocalJsonLog {
    param([string]$EventName, [string]$Status, [object]$Data = $null)

    # Contract marker: Write-JobLog
    $record = [ordered]@{
        event_ts        = (Get-Date).ToUniversalTime().ToString("o")
        event_name      = $EventName
        job_name        = $WorkerName
        run_id          = $RunId
        worker_name     = $WorkerName
        component       = $Component
        environment     = $Environment
        database_target = $DatabaseTarget
        source_name     = $SourceName
        status          = $Status
        attempt         = 1
        error_code      = $null
        error_message   = $null
        data            = $Data
    }

    $logPath = Join-Path $LogRoot "$WorkerName-$($StartedAt.ToUniversalTime().ToString('yyyyMMdd')).jsonl"
    Add-Content -Path $logPath -Value ($record | ConvertTo-Json -Depth 20 -Compress)
}

function Emit-LocalSignal {
    param([string]$SignalName, [object]$SignalValue, [object]$Payload = $null)

    # Contract marker: Emit-Signal
    Write-LocalJsonLog -EventName "signal_emitted" -Status "ok" -Data ([ordered]@{
        signal_name = $SignalName
        signal_value = $SignalValue
        payload = $Payload
    })
}

function Emit-LocalHeartbeat {
    param([string]$Status = "ok")

    # Contract marker: Emit-Heartbeat
    Write-LocalJsonLog -EventName "heartbeat" -Status $Status -Data ([ordered]@{})
}

function Test-WorkerKillSwitch {
    # Contract marker: Test-KillSwitch
    $raw = [Environment]::GetEnvironmentVariable($KillSwitchName)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $true }

    $normalized = $raw.Trim().ToLowerInvariant()
    return ($normalized -notin @("0", "false", "no", "off", "disabled"))
}

function Get-LatestFile {
    param([string]$Folder, [string]$Filter)

    if (-not (Test-Path -LiteralPath $Folder)) { return $null }

    return Get-ChildItem -LiteralPath $Folder -Filter $Filter -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
}

function Read-JsonFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Get-Text {
    param([object]$Object, [string]$Name, [string]$Default = "")

    if ($null -eq $Object) { return $Default }

    $property = $Object.PSObject.Properties |
        Where-Object { $_.Name -ieq $Name } |
        Select-Object -First 1

    if ($null -eq $property -or $null -eq $property.Value) { return $Default }

    return [string]$property.Value
}

function Get-IntValue {
    param([object]$Object, [string]$Name, [int]$Default = 0)

    $text = Get-Text -Object $Object -Name $Name -Default ""
    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }

    $value = 0
    if ([int]::TryParse($text, [ref]$value)) { return $value }

    return $Default
}

function Get-JsonCount {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return -1
    }

    try {
        $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json

        if ($json -is [System.Array]) {
            return @($json).Count
        }

        $candidateProperties = @("items", "data", "streams", "categories", "result", "rows")
        foreach ($propertyName in $candidateProperties) {
            $property = $json.PSObject.Properties |
                Where-Object { $_.Name -ieq $propertyName } |
                Select-Object -First 1

            if ($null -ne $property -and $null -ne $property.Value) {
                return @($property.Value).Count
            }
        }

        return 1
    }
    catch {
        return -1
    }
}

function Get-CsvCount {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return -1
    }

    try {
        return @(Import-Csv -LiteralPath $Path).Count
    }
    catch {
        return -1
    }
}

function New-SnapshotLaneRow {
    param([string]$LaneKey, [string]$SnapshotRoot)

    $laneRoot = Join-Path $SnapshotRoot $LaneKey
    $files = @()

    if (Test-Path -LiteralPath $laneRoot) {
        $files = @(Get-ChildItem -LiteralPath $laneRoot -Recurse -File -Filter "*.json" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending)
    }

    $latest = $files | Select-Object -First 1
    $latestPath = ""
    $latestLength = 0
    $latestRows = -1
    $latestModified = ""

    if ($latest) {
        $latestPath = $latest.FullName
        $latestLength = $latest.Length
        $latestRows = Get-JsonCount -Path $latest.FullName
        $latestModified = $latest.LastWriteTimeUtc.ToString("o")
    }

    return [pscustomobject][ordered]@{
        lane_key = $LaneKey
        snapshot_file_count = @($files).Count
        latest_snapshot = $latestPath
        latest_snapshot_bytes = $latestLength
        latest_snapshot_count_estimate = $latestRows
        latest_snapshot_modified_utc = $latestModified
        db_reads = $false
        db_writes = $false
        provider_calls = $false
    }
}

try {
    if ($SampleRows -lt 1) { $SampleRows = 10 }
    if ($SampleRows -gt 100) { $SampleRows = 100 }

    Write-LocalJsonLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        sample_rows = $SampleRows
        db_reads = $false
        db_writes = $false
        provider_calls = $false
    })

    Emit-LocalHeartbeat -Status "running"

    if (-not (Test-WorkerKillSwitch)) {
        $summary = [ordered]@{
            status = "disabled"
            disposition = "disabled_by_kill_switch"
            db_reads = $false
            db_writes = $false
            provider_calls = $false
            run_id = $RunId
        }

        Emit-LocalSignal -SignalName $CompletedSignal -SignalValue "disabled" -Payload $summary
        Emit-LocalSignal -SignalName $DispositionSignal -SignalValue "disabled_by_kill_switch" -Payload ([ordered]@{ run_id = $RunId })
        Write-LocalJsonLog -EventName "job_completed" -Status "disabled" -Data $summary
        Write-Output "SKIPPED: $KillSwitchName is disabled. run_id=$RunId"
        exit 0
    }

    $snapshotRoot = Join-Path $RepoRoot "runtime\provider_snapshots"
    $lanes = @("live_categories", "vod_categories", "series_categories", "live_streams", "vod_streams", "series_streams", "epg")
    $snapshotRows = @()

    foreach ($lane in $lanes) {
        $snapshotRows += New-SnapshotLaneRow -LaneKey $lane -SnapshotRoot $snapshotRoot
    }

    $totalSnapshotFiles = ($snapshotRows | Measure-Object -Property snapshot_file_count -Sum).Sum
    if ($null -eq $totalSnapshotFiles) { $totalSnapshotFiles = 0 }

    $reportRows = @()

    $reportDefinitions = @(
        @{ key = "provider_snapshot_delta_import_dryrun"; folder = "runtime\reports\provider_snapshot_delta_import_dryrun"; summary_filter = "provider_snapshot_delta_import_dryrun_summary_*.json"; csv_filter = "provider_snapshot_delta_import_dryrun_*.csv" },
        @{ key = "vod_streams_delta_import_preview"; folder = "runtime\reports\vod_streams_delta_import_preview"; summary_filter = "vod_streams_delta_import_preview_summary_*.json"; csv_filter = "vod_streams_delta_import_preview_*.csv" },
        @{ key = "provider_snapshot_import_candidate_selector"; folder = "runtime\reports\provider_snapshot_import_candidate_selector"; summary_filter = "provider_snapshot_import_candidate_selection_summary_*.json"; csv_filter = "provider_snapshot_import_candidate_selection_*.csv" },
        @{ key = "provider_snapshot_import_decision_gate"; folder = "runtime\reports\provider_snapshot_import_decision_gate"; summary_filter = "provider_snapshot_import_decision_gate_summary_*.json"; csv_filter = "provider_snapshot_import_decision_gate_*.csv" },
        @{ key = "provider_snapshot_governed_import_runner"; folder = "runtime\reports\provider_snapshot_governed_import_runner"; summary_filter = "provider_snapshot_governed_import_runner_summary_*.json"; csv_filter = "provider_snapshot_governed_import_runner_*.csv" },
        @{ key = "vod_streams_delta_limited_apply"; folder = "runtime\reports\vod_streams_delta_limited_apply"; summary_filter = "vod_streams_delta_limited_apply_summary_*.json"; csv_filter = "vod_streams_delta_limited_apply_*.csv" }
    )

    $plannedImportTotal = 0
    $skippedProviderNoiseTotal = 0
    $candidateFoundAny = $false
    $latestSelectorDisposition = ""
    $latestSelectorNextWorker = ""

    foreach ($definition in $reportDefinitions) {
        $folder = Join-Path $RepoRoot $definition.folder
        $summaryFile = Get-LatestFile -Folder $folder -Filter $definition.summary_filter
        $csvFile = Get-LatestFile -Folder $folder -Filter $definition.csv_filter
        $summary = $null

        if ($summaryFile) {
            $summary = Read-JsonFile -Path $summaryFile.FullName
        }

        $plannedImportCount = Get-IntValue -Object $summary -Name "planned_import_count" -Default 0
        $skippedProviderNoiseCount = Get-IntValue -Object $summary -Name "skipped_provider_noise_count" -Default 0
        $candidateFound = Get-Text -Object $summary -Name "candidate_found" -Default "false"
        $disposition = Get-Text -Object $summary -Name "disposition" -Default ""
        if ([string]::IsNullOrWhiteSpace($disposition)) {
            $disposition = Get-Text -Object $summary -Name "selector_disposition" -Default ""
        }
        $nextWorker = Get-Text -Object $summary -Name "next_worker" -Default ""

        $plannedImportTotal += $plannedImportCount
        $skippedProviderNoiseTotal += $skippedProviderNoiseCount
        if ($candidateFound.Trim().ToLowerInvariant() -eq "true") { $candidateFoundAny = $true }

        if ($definition.key -eq "provider_snapshot_import_candidate_selector") {
            $latestSelectorDisposition = $disposition
            $latestSelectorNextWorker = $nextWorker
        }

        $reportRows += [pscustomobject][ordered]@{
            report_key = $definition.key
            latest_summary = $(if ($summaryFile) { $summaryFile.FullName } else { "" })
            latest_csv = $(if ($csvFile) { $csvFile.FullName } else { "" })
            latest_csv_row_count = $(if ($csvFile) { Get-CsvCount -Path $csvFile.FullName } else { -1 })
            planned_import_count = $plannedImportCount
            skipped_provider_noise_count = $skippedProviderNoiseCount
            candidate_found = $candidateFound
            disposition = $disposition
            next_worker = $nextWorker
            db_reads = $false
            db_writes = $false
            provider_calls = $false
        }
    }

    $diagnosis = @()
    if ($totalSnapshotFiles -le 0) {
        $diagnosis += "no_provider_snapshot_files_found"
    }
    else {
        $diagnosis += "provider_snapshot_files_found"
    }

    $vodSnapshotRow = $snapshotRows | Where-Object { $_.lane_key -eq "vod_streams" } | Select-Object -First 1
    if ($vodSnapshotRow -and [int]$vodSnapshotRow.latest_snapshot_count_estimate -gt 0) {
        $diagnosis += "vod_snapshot_has_countable_rows"
    }
    elseif ($vodSnapshotRow -and [int]$vodSnapshotRow.snapshot_file_count -gt 0) {
        $diagnosis += "vod_snapshot_files_exist_but_count_uncertain"
    }
    else {
        $diagnosis += "vod_snapshot_missing"
    }

    if ($plannedImportTotal -gt 0) {
        $diagnosis += "planned_import_rows_exist"
    }
    else {
        $diagnosis += "planned_import_rows_zero"
    }

    if ($skippedProviderNoiseTotal -gt 0) {
        $diagnosis += "provider_noise_filter_active"
    }

    if ($candidateFoundAny) {
        $diagnosis += "selector_has_seen_candidate"
    }
    else {
        $diagnosis += "selector_currently_no_candidate"
    }

    $status = "pass"
    $disposition = "data_reality_audited"

    if ($totalSnapshotFiles -le 0) {
        $status = "warning"
        $disposition = "data_reality_no_snapshots_found"
    }
    elseif ($plannedImportTotal -eq 0) {
        $status = "warning"
        $disposition = "data_reality_snapshots_exist_but_no_planned_imports"
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $snapshotCsv = Join-Path $OutputRoot "provider_snapshot_data_reality_snapshots_$timestamp.csv"
    $reportsCsv = Join-Path $OutputRoot "provider_snapshot_data_reality_reports_$timestamp.csv"
    $summaryJson = Join-Path $OutputRoot "provider_snapshot_data_reality_summary_$timestamp.json"
    $diagnosisTxt = Join-Path $OutputRoot "provider_snapshot_data_reality_diagnosis_$timestamp.txt"

    $snapshotRows | Export-Csv -Path $snapshotCsv -NoTypeInformation
    $reportRows | Export-Csv -Path $reportsCsv -NoTypeInformation

    @"
Provider Snapshot Data Reality Audit

Disposition:
  $disposition

Diagnosis:
  $($diagnosis -join "`n  ")

Snapshot files total:
  $totalSnapshotFiles

Planned import rows total:
  $plannedImportTotal

Skipped provider noise total:
  $skippedProviderNoiseTotal

Candidate found any:
  $candidateFoundAny

Latest selector disposition:
  $latestSelectorDisposition

Latest selector next worker:
  $latestSelectorNextWorker

No DB reads.
No DB writes.
No provider calls.
"@ | Set-Content -Path $diagnosisTxt -Encoding UTF8

    $summary = [ordered]@{
        status = $status
        disposition = $disposition
        diagnosis = $diagnosis
        snapshot_file_total = [int]$totalSnapshotFiles
        planned_import_total = [int]$plannedImportTotal
        skipped_provider_noise_total = [int]$skippedProviderNoiseTotal
        candidate_found_any = $candidateFoundAny
        latest_selector_disposition = $latestSelectorDisposition
        latest_selector_next_worker = $latestSelectorNextWorker
        db_reads = $false
        db_writes = $false
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        snapshot_csv = $snapshotCsv
        reports_csv = $reportsCsv
        diagnosis_txt = $diagnosisTxt
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $status -Payload $summary
    Emit-LocalSignal -SignalName $DispositionSignal -SignalValue $disposition -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $SnapshotCountSignal -SignalValue ([int]$totalSnapshotFiles) -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $PlannedImportCountSignal -SignalValue ([int]$plannedImportTotal) -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: Provider snapshot data reality audited. status=$status disposition=$disposition snapshot_files=$totalSnapshotFiles planned_import_total=$plannedImportTotal skipped_provider_noise_total=$skippedProviderNoiseTotal candidate_found_any=$candidateFoundAny db_reads=False db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: snapshot_csv=$snapshotCsv reports_csv=$reportsCsv diagnosis_txt=$diagnosisTxt summary_json=$summaryJson"
        "`nSNAPSHOTS:"
        $snapshotRows | Format-Table -AutoSize
        "`nREPORTS:"
        $reportRows | Format-Table -AutoSize
    }

    exit 0
}
catch {
    $message = $_.Exception.Message

    try {
        Emit-LocalSignal -SignalName $CompletedSignal -SignalValue "fail" -Payload ([ordered]@{
            run_id = $RunId
            error_message = $message
        })

        Emit-LocalHeartbeat -Status "failed"
        Write-LocalJsonLog -EventName "job_failed" -Status "failed" -Data ([ordered]@{
            error_message = $message
            duration_ms = Get-DurationMs -Start $StartedAt
        })
    }
    catch {}

    Write-Error "FAILED: Provider snapshot data reality audit failed. $message run_id=$RunId"
    exit 1
}
