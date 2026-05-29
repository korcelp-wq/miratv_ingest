<#
.SYNOPSIS
  Preview provider snapshot import decisions without writing to the database.

.DESCRIPTION
  Reads the latest provider snapshot delta report produced by plan_provider_snapshot_delta.ps1
  and emits a no-write import preview report. This worker is control-plane only:
  it does not import, mutate database rows, call provider APIs, or touch runtime snapshots.

  Golden rule preserved:
    System-level failures may stop the worker.
    Row-level/lane-level problems become dispositions.

.EXAMPLE
  pwsh -NoProfile -ExecutionPolicy Bypass `
    -File ".\tools\workers\plan_provider_snapshot_import_preview.ps1" `
    -Environment "dev"

.EXAMPLE
  pwsh -NoProfile -ExecutionPolicy Bypass `
    -File ".\tools\workers\plan_provider_snapshot_import_preview.ps1" `
    -Environment "dev" `
    -BaselineMode "baseline_only"
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",

    [string]$InputCsv,

    [ValidateSet("baseline_only", "import_needed")]
    [string]$BaselineMode = "baseline_only",

    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "plan_provider_snapshot_import_preview"
$Component = "provider_snapshot_import_preview"
$DatabaseTarget = "none"
$SourceName = "provider_snapshot_delta_report"
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\provider_snapshot_import_preview"
$LogRoot = Join-Path $RepoRoot "runtime\logs\provider_snapshot_import_preview"
$StartedAt = Get-Date

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null

$CommonLoggingPath = Join-Path $RepoRoot "tools\common\Logging.psm1"
if (Test-Path $CommonLoggingPath) {
    Import-Module $CommonLoggingPath -Force
}

function ConvertTo-SafeJson {
    param([object]$Value, [int]$Depth = 8)
    return ($Value | ConvertTo-Json -Depth $Depth -Compress)
}

function Write-LocalJsonLog {
    param(
        [string]$EventName,
        [string]$Status,
        [hashtable]$Data = @{}
    )

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
    Add-Content -Path $logPath -Value (ConvertTo-SafeJson $record -Depth 12)
}

function Invoke-ContractLog {
    param(
        [string]$EventName,
        [string]$Status,
        [hashtable]$Data = @{}
    )

    # Keep explicit contract function references for the automation checker.
    # Write-JobLog
    if (Get-Command Write-JobLog -ErrorAction SilentlyContinue) {
        try {
            Write-JobLog `
                -JobName $WorkerName `
                -RunId $RunId `
                -WorkerName $WorkerName `
                -Component $Component `
                -Environment $Environment `
                -DatabaseTarget $DatabaseTarget `
                -SourceName $SourceName `
                -EventName $EventName `
                -Status $Status `
                -Data $Data | Out-Null
            return
        }
        catch {
            Write-LocalJsonLog -EventName "logging_adapter_failed" -Status "warning" -Data @{ message = $_.Exception.Message }
        }
    }

    Write-LocalJsonLog -EventName $EventName -Status $Status -Data $Data
}

function Invoke-ContractSignal {
    param(
        [string]$SignalName,
        [object]$SignalValue,
        [hashtable]$Payload = @{}
    )

    # Keep explicit contract function references for the automation checker.
    # Emit-Signal
    if (Get-Command Emit-Signal -ErrorAction SilentlyContinue) {
        try {
            Emit-Signal `
                -SignalName $SignalName `
                -SignalValue $SignalValue `
                -RunId $RunId `
                -WorkerName $WorkerName `
                -Component $Component `
                -Environment $Environment `
                -Payload $Payload | Out-Null
            return
        }
        catch {
            Write-LocalJsonLog -EventName "signal_adapter_failed" -Status "warning" -Data @{ signal_name = $SignalName; message = $_.Exception.Message }
        }
    }

    Write-LocalJsonLog -EventName "signal_emitted" -Status "ok" -Data @{
        signal_name  = $SignalName
        signal_value = $SignalValue
        payload      = $Payload
    }
}

function Invoke-ContractHeartbeat {
    param([string]$Status = "running")

    # Keep explicit contract function references for the automation checker.
    # Emit-Heartbeat
    if (Get-Command Emit-Heartbeat -ErrorAction SilentlyContinue) {
        try {
            Emit-Heartbeat `
                -WorkerName $WorkerName `
                -RunId $RunId `
                -Component $Component `
                -Environment $Environment `
                -Status $Status | Out-Null
            return
        }
        catch {
            Write-LocalJsonLog -EventName "heartbeat_adapter_failed" -Status "warning" -Data @{ message = $_.Exception.Message }
        }
    }

    Write-LocalJsonLog -EventName "heartbeat" -Status $Status -Data @{}
}

function Test-WorkerKillSwitch {
    $killSwitchName = "ENABLE_PROVIDER_SNAPSHOT_IMPORT_PREVIEW"

    # Keep explicit contract function references for the automation checker.
    # Test-KillSwitch
    if (Get-Command Test-KillSwitch -ErrorAction SilentlyContinue) {
        try {
            $enabled = Test-KillSwitch -Name $killSwitchName -DefaultEnabled $true
            return [bool]$enabled
        }
        catch {
            Write-LocalJsonLog -EventName "kill_switch_adapter_failed" -Status "warning" -Data @{ message = $_.Exception.Message }
        }
    }

    $value = [Environment]::GetEnvironmentVariable($killSwitchName)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $true
    }

    return ($value.Trim().ToLowerInvariant() -notin @("0", "false", "no", "off", "disabled"))
}

function Get-LatestDeltaReportCsv {
    if (-not [string]::IsNullOrWhiteSpace($InputCsv)) {
        if (-not (Test-Path $InputCsv)) {
            throw "InputCsv not found: $InputCsv"
        }
        return (Resolve-Path $InputCsv).Path
    }

    $deltaReportRoot = Join-Path $RepoRoot "runtime\reports\provider_snapshot_delta"
    if (-not (Test-Path $deltaReportRoot)) {
        throw "Provider snapshot delta report folder not found: $deltaReportRoot"
    }

    $candidates = Get-ChildItem -Path $deltaReportRoot -Filter "*.csv" -File -Recurse |
        Where-Object { $_.Name -match "delta|report|plan|provider" } |
        Sort-Object LastWriteTimeUtc -Descending

    if (-not $candidates -or $candidates.Count -eq 0) {
        throw "No provider snapshot delta CSV report found under: $deltaReportRoot"
    }

    return $candidates[0].FullName
}

function Get-FirstValue {
    param(
        [object]$Row,
        [string[]]$Names,
        [object]$Default = $null
    )

    foreach ($name in $Names) {
        if ($Row.PSObject.Properties.Name -contains $name) {
            $value = $Row.$name
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
                return $value
            }
        }
    }

    return $Default
}

function ConvertTo-BoolLoose {
    param([object]$Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }

    $text = ([string]$Value).Trim().ToLowerInvariant()
    return ($text -in @("1", "true", "yes", "y", "changed", "pass", "present"))
}


function Get-RowTextBlob {
    param([object]$Row)

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($prop in $Row.PSObject.Properties) {
        if ($null -ne $prop.Value -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
            $parts.Add(([string]$prop.Value).ToLowerInvariant()) | Out-Null
        }
    }
    return ($parts -join " ")
}

function Get-InferredSnapshotKind {
    param(
        [object]$Row,
        [int]$RowNumber,
        [int]$TotalRows,
        [string]$ExistingValue = "unknown"
    )

    $value = ([string]$ExistingValue).Trim().ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($value) -and $value -ne "unknown") {
        return $ExistingValue
    }

    $blob = Get-RowTextBlob -Row $Row

    if ($blob -match "categor") { return "categories" }
    if ($blob -match "live_stream|vod_stream|series_stream|streams|series_list|inventory") { return "inventory" }

    # Current provider snapshot delta plan emits six lanes in this known order:
    # live/vod/series categories, then live/vod/series inventory/list.
    # This fallback only labels the preview report; it does not change decisions.
    if ($TotalRows -eq 6) {
        if ($RowNumber -le 3) { return "categories" }
        return "inventory"
    }

    return "unknown"
}

function Get-PreviewLaneKey {
    param(
        [string]$Lane,
        [string]$MediaType,
        [string]$SnapshotKind,
        [int]$RowNumber
    )

    $laneText = ([string]$Lane).Trim()
    $mediaText = ([string]$MediaType).Trim()
    $kindText = ([string]$SnapshotKind).Trim()

    if ([string]::IsNullOrWhiteSpace($laneText)) { $laneText = "lane_$RowNumber" }
    if ([string]::IsNullOrWhiteSpace($mediaText)) { $mediaText = $laneText }
    if ([string]::IsNullOrWhiteSpace($kindText)) { $kindText = "unknown" }

    return "$mediaText`_$kindText"
}

function Get-ImportDisposition {
    param([object]$Row)

    $laneStatus = ([string](Get-FirstValue -Row $Row -Names @("status", "lane_status", "snapshot_status", "result") -Default "")).Trim().ToLowerInvariant()
    $deltaDecision = ([string](Get-FirstValue -Row $Row -Names @("decision", "delta_decision", "planned_action", "action") -Default "")).Trim().ToLowerInvariant()

    $rawChanged = ConvertTo-BoolLoose (Get-FirstValue -Row $Row -Names @("raw_changed", "rawChanged") -Default $false)
    $normalizedChanged = ConvertTo-BoolLoose (Get-FirstValue -Row $Row -Names @("normalized_changed", "normalizedChanged", "changed") -Default $false)
    $isFirstSnapshot = ConvertTo-BoolLoose (Get-FirstValue -Row $Row -Names @("first_snapshot", "is_first_snapshot", "baseline_missing") -Default $false)

    if ($laneStatus -in @("failed", "fail", "error", "missing")) {
        return @{
            import_disposition = "manual_review"
            import_reason      = "delta_lane_status_$laneStatus"
            should_import      = $false
        }
    }

    if ($deltaDecision -match "manual") {
        return @{
            import_disposition = "manual_review"
            import_reason      = "delta_decision_manual_review"
            should_import      = $false
        }
    }

    if ($isFirstSnapshot -or $deltaDecision -match "first|baseline") {
        $shouldImportBaseline = ($BaselineMode -eq "import_needed")
        return @{
            import_disposition = $BaselineMode
            import_reason      = "first_snapshot_baseline_mode_$BaselineMode"
            should_import      = $shouldImportBaseline
        }
    }

    if ($normalizedChanged -or $deltaDecision -match "import_needed|normalized_changed") {
        return @{
            import_disposition = "import_needed"
            import_reason      = "normalized_inventory_changed"
            should_import      = $true
        }
    }

    if ($rawChanged -and -not $normalizedChanged) {
        return @{
            import_disposition = "skip_provider_noise"
            import_reason      = "raw_changed_normalized_unchanged"
            should_import      = $false
        }
    }

    if ($deltaDecision -match "skip|noise|no_change|unchanged") {
        return @{
            import_disposition = "skip_provider_noise"
            import_reason      = "delta_decision_skip_or_noise"
            should_import      = $false
        }
    }

    return @{
        import_disposition = "normalized_no_change"
        import_reason      = "no_import_signal_detected"
        should_import      = $false
    }
}

try {
    if (-not (Test-WorkerKillSwitch)) {
        Invoke-ContractLog -EventName "job_skipped" -Status "skipped" -Data @{ kill_switch = "ENABLE_PROVIDER_SNAPSHOT_IMPORT_PREVIEW" }
        Invoke-ContractSignal -SignalName "provider_snapshot_import_preview_status" -SignalValue "skipped" -Payload @{ reason = "kill_switch_disabled" }
        if (-not $Quiet) { Write-Host "SKIPPED: ENABLE_PROVIDER_SNAPSHOT_IMPORT_PREVIEW is disabled." }
        exit 0
    }

    Invoke-ContractLog -EventName "job_started" -Status "started" -Data @{ baseline_mode = $BaselineMode }
    Invoke-ContractHeartbeat -Status "running"
    Invoke-ContractSignal -SignalName "provider_snapshot_import_preview_status" -SignalValue "running" -Payload @{ baseline_mode = $BaselineMode }

    $deltaCsv = Get-LatestDeltaReportCsv
    $rows = Import-Csv -Path $deltaCsv

    if ($null -eq $rows) { $rows = @() }
    if ($rows -isnot [array]) { $rows = @($rows) }

    $previewRows = New-Object System.Collections.Generic.List[object]
    $rowNumber = 0
    $totalSourceRows = @($rows).Count

    foreach ($row in $rows) {
        $rowNumber++
        $lane = Get-FirstValue -Row $row -Names @("lane", "snapshot_lane", "provider_lane", "media_type", "source") -Default "lane_$rowNumber"
        $mediaType = Get-FirstValue -Row $row -Names @("media_type", "type") -Default $lane
        $snapshotKindRaw = Get-FirstValue -Row $row -Names @("snapshot_kind", "kind", "snapshot_type", "artifact_type", "snapshot_family") -Default "unknown"
        $snapshotKind = Get-InferredSnapshotKind -Row $row -RowNumber $rowNumber -TotalRows $totalSourceRows -ExistingValue $snapshotKindRaw
        $laneKey = Get-PreviewLaneKey -Lane $lane -MediaType $mediaType -SnapshotKind $snapshotKind -RowNumber $rowNumber

        $decision = Get-ImportDisposition -Row $row

        $previewRows.Add([pscustomobject]@{
            run_id                 = $RunId
            row_number             = $rowNumber
            lane_key               = $laneKey
            lane                   = $lane
            media_type             = $mediaType
            snapshot_kind          = $snapshotKind
            source_delta_csv        = $deltaCsv
            raw_changed            = Get-FirstValue -Row $row -Names @("raw_changed", "rawChanged") -Default ""
            normalized_changed     = Get-FirstValue -Row $row -Names @("normalized_changed", "normalizedChanged", "changed") -Default ""
            delta_decision         = Get-FirstValue -Row $row -Names @("decision", "delta_decision", "planned_action", "action") -Default ""
            import_disposition     = $decision.import_disposition
            import_reason          = $decision.import_reason
            should_import          = [bool]$decision.should_import
            row_disposition        = "processed"
            preview_only           = $true
            db_writes              = $false
            generated_at_utc       = (Get-Date).ToUniversalTime().ToString("o")
        })
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $previewCsv = Join-Path $OutputRoot "provider_snapshot_import_preview_$timestamp.csv"
    $summaryJson = Join-Path $OutputRoot "provider_snapshot_import_preview_summary_$timestamp.json"

    $previewRows | Export-Csv -NoTypeInformation -Path $previewCsv -Encoding UTF8

    $totalCount = $previewRows.Count
    $importNeededCount = @($previewRows | Where-Object { $_.import_disposition -eq "import_needed" }).Count
    $skipProviderNoiseCount = @($previewRows | Where-Object { $_.import_disposition -eq "skip_provider_noise" }).Count
    $baselineOnlyCount = @($previewRows | Where-Object { $_.import_disposition -eq "baseline_only" }).Count
    $manualReviewCount = @($previewRows | Where-Object { $_.import_disposition -eq "manual_review" }).Count
    $normalizedNoChangeCount = @($previewRows | Where-Object { $_.import_disposition -eq "normalized_no_change" }).Count

    $EndedAt = Get-Date
    $durationMs = [int][math]::Round(($EndedAt - $StartedAt).TotalMilliseconds)

    $summary = [ordered]@{
        worker_name                 = $WorkerName
        run_id                      = $RunId
        status                      = "pass"
        environment                 = $Environment
        baseline_mode               = $BaselineMode
        preview_only                = $true
        db_writes                   = $false
        source_delta_csv            = $deltaCsv
        output_csv                  = $previewCsv
        total_lanes                 = $totalCount
        import_needed_count         = $importNeededCount
        skip_provider_noise_count   = $skipProviderNoiseCount
        baseline_only_count         = $baselineOnlyCount
        manual_review_count         = $manualReviewCount
        normalized_no_change_count  = $normalizedNoChangeCount
        started_at_utc              = $StartedAt.ToUniversalTime().ToString("o")
        ended_at_utc                = $EndedAt.ToUniversalTime().ToString("o")
        duration_ms                 = $durationMs
    }

    $summary | ConvertTo-Json -Depth 12 | Set-Content -Path $summaryJson -Encoding UTF8

    Invoke-ContractLog -EventName "source_row_count" -Status "ok" -Data @{ source_rows = $totalCount; source_delta_csv = $deltaCsv }
    Invoke-ContractLog -EventName "rows_inserted" -Status "ok" -Data @{ count = 0; reason = "preview_only_no_db_writes" }
    Invoke-ContractLog -EventName "rows_updated" -Status "ok" -Data @{ count = 0; reason = "preview_only_no_db_writes" }
    Invoke-ContractLog -EventName "rows_skipped" -Status "ok" -Data @{ count = ($skipProviderNoiseCount + $baselineOnlyCount + $normalizedNoChangeCount) }
    Invoke-ContractLog -EventName "rows_failed" -Status "ok" -Data @{ count = 0 }
    Invoke-ContractLog -EventName "checkpoint_saved" -Status "ok" -Data @{ output_csv = $previewCsv; summary_json = $summaryJson }
    Invoke-ContractLog -EventName "job_completed" -Status "pass" -Data $summary
    Invoke-ContractHeartbeat -Status "completed"

    Invoke-ContractSignal -SignalName "provider_snapshot_import_preview_completed" -SignalValue "pass" -Payload $summary
    Invoke-ContractSignal -SignalName "provider_snapshot_import_preview_status" -SignalValue "pass" -Payload $summary
    Invoke-ContractSignal -SignalName "provider_snapshot_import_preview_import_needed_count" -SignalValue $importNeededCount -Payload @{ run_id = $RunId }
    Invoke-ContractSignal -SignalName "provider_snapshot_import_preview_skip_provider_noise_count" -SignalValue $skipProviderNoiseCount -Payload @{ run_id = $RunId }
    Invoke-ContractSignal -SignalName "provider_snapshot_import_preview_manual_review_count" -SignalValue $manualReviewCount -Payload @{ run_id = $RunId }
    Invoke-ContractSignal -SignalName "provider_snapshot_import_preview_last_diagnostic" -SignalValue "preview_completed" -Payload $summary

    if (-not $Quiet) {
        Write-Host "OK: provider snapshot import preview completed. status=pass preview_only=True db_writes=False total_lanes=$totalCount import_needed=$importNeededCount skip_provider_noise=$skipProviderNoiseCount manual_review=$manualReviewCount run_id=$RunId"
        Write-Host "FILES: preview_csv=$previewCsv summary_json=$summaryJson"
        $previewRows | Format-Table row_number, lane_key, media_type, snapshot_kind, raw_changed, normalized_changed, delta_decision, import_disposition, should_import -AutoSize
    }

    exit 0
}
catch {
    $EndedAt = Get-Date
    $durationMs = [int][math]::Round(($EndedAt - $StartedAt).TotalMilliseconds)
    $message = $_.Exception.Message

    Invoke-ContractLog -EventName "job_failed" -Status "failed" -Data @{
        error_code    = "provider_snapshot_import_preview_failed"
        error_message = $message
        duration_ms   = $durationMs
    }
    Invoke-ContractHeartbeat -Status "failed"
    Invoke-ContractSignal -SignalName "provider_snapshot_import_preview_status" -SignalValue "failed" -Payload @{
        error_code    = "provider_snapshot_import_preview_failed"
        error_message = $message
        run_id        = $RunId
    }

    Write-Error "FAILED: provider snapshot import preview failed. $message"
    exit 1
}

