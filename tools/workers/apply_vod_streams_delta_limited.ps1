<#
.SYNOPSIS
  Apply VOD streams delta with strict bounded controls.

.DESCRIPTION
  Dry-run-first apply worker skeleton for VOD streams.

  This worker is intentionally conservative:
    - Default is dry-run.
    - DB writes are disabled unless -Apply is explicitly passed.
    - Even with -Apply, the worker refuses to proceed unless the latest real selector
      says candidate_found=True and selected_lane=vod_streams.
    - Synthetic simulator output is never accepted as apply authorization.
    - Row-level disposition discipline is enforced.
    - This version does not call providers.
    - This version does not import through the legacy unbounded import_vod_streams.ps1.

  Today, with the current real selector state of noop_ready, this worker should self-block.

.CONTRACT-MARKERS
  Write-JobLog
  Emit-Signal
  Emit-Heartbeat
  Test-KillSwitch
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [int]$Limit = 25,
    [switch]$Apply,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "apply_vod_streams_delta_limited"
$Component = "vod_streams_delta_limited_apply"
$DatabaseTarget = "xpdgxfsp_content"
$SourceName = "provider_snapshot_import_candidate_selector"
$KillSwitchName = "ENABLE_VOD_STREAMS_DELTA_LIMITED_APPLY"

$CompletedSignal = "vod_streams_delta_limited_apply_completed"
$DispositionSignal = "vod_streams_delta_limited_apply_disposition"
$WouldWriteCountSignal = "vod_streams_delta_limited_apply_would_write_count"
$ActualWriteCountSignal = "vod_streams_delta_limited_apply_actual_write_count"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\vod_streams_delta_limited_apply"
$LogRoot = Join-Path $RepoRoot "runtime\logs\vod_streams_delta_limited_apply"

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
        signal_name  = $SignalName
        signal_value = $SignalValue
        payload      = $Payload
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

function Get-Bool {
    param([object]$Object, [string]$Name, [bool]$Default = $false)

    $text = Get-Text -Object $Object -Name $Name -Default ""
    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }

    return ($text.Trim().ToLowerInvariant() -in @("true", "1", "yes"))
}

function Get-IntValue {
    param([object]$Object, [string]$Name, [int]$Default = 0)

    $text = Get-Text -Object $Object -Name $Name -Default ""
    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }

    $value = 0
    if ([int]::TryParse($text, [ref]$value)) { return $value }

    return $Default
}

function Get-LatestRealSelectorSummary {
    $folder = Join-Path $RepoRoot "runtime\reports\provider_snapshot_import_candidate_selector"
    $latest = Get-LatestFile -Folder $folder -Filter "provider_snapshot_import_candidate_selection_summary_*.json"

    if ($null -eq $latest) {
        return $null
    }

    return Read-JsonFile -Path $latest.FullName
}

function Get-LatestVodPreviewSummary {
    $folder = Join-Path $RepoRoot "runtime\reports\vod_streams_delta_import_preview"
    $latest = Get-LatestFile -Folder $folder -Filter "vod_streams_delta_import_preview_summary_*.json"

    if ($null -eq $latest) {
        return $null
    }

    return Read-JsonFile -Path $latest.FullName
}

try {
    if ($Limit -lt 1) { $Limit = 1 }
    if ($Limit -gt 100) { $Limit = 100 }

    $dryRun = -not [bool]$Apply

    Write-LocalJsonLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        dry_run = $dryRun
        apply_requested = [bool]$Apply
        limit = $Limit
        provider_calls = $false
    })

    Emit-LocalHeartbeat -Status "running"

    if (-not (Test-WorkerKillSwitch)) {
        $summary = [ordered]@{
            status = "disabled"
            disposition = "disabled_by_kill_switch"
            dry_run = $dryRun
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

    $selector = Get-LatestRealSelectorSummary
    $vodPreview = Get-LatestVodPreviewSummary

    $candidateFound = Get-Bool -Object $selector -Name "candidate_found" -Default $false
    $selectedLane = Get-Text -Object $selector -Name "selected_lane" -Default "none"
    $selectorDisposition = Get-Text -Object $selector -Name "selector_disposition" -Default "unknown"
    $selectorNextWorker = Get-Text -Object $selector -Name "next_worker" -Default "none"

    $plannedImportCount = Get-IntValue -Object $vodPreview -Name "planned_import_count" -Default 0
    $sourceRowCount = Get-IntValue -Object $vodPreview -Name "source_row_count" -Default 0
    $manualReviewCount = Get-IntValue -Object $vodPreview -Name "manual_review_count" -Default 0
    $skippedProviderNoiseCount = Get-IntValue -Object $vodPreview -Name "skipped_provider_noise_count" -Default 0
    $vodPreviewOutputCsv = Get-Text -Object $vodPreview -Name "output_csv" -Default ""

    $blockReasons = @()
    $disposition = "blocked_no_real_candidate"
    $wouldWriteCount = 0
    $actualWriteCount = 0
    $dbWrites = $false

    if ($null -eq $selector) {
        $blockReasons += "real_selector_summary_missing"
    }

    if (-not $candidateFound) {
        $blockReasons += "real_selector_candidate_found_false"
    }

    if ($selectedLane -ne "vod_streams") {
        $blockReasons += "real_selector_selected_lane_not_vod_streams"
    }

    if ($selectorNextWorker -ne "apply_vod_streams_delta_limited.ps1") {
        $blockReasons += "real_selector_next_worker_not_this_worker"
    }

    if ($plannedImportCount -le 0) {
        $blockReasons += "vod_preview_planned_import_count_zero"
    }

    if ($manualReviewCount -gt 0) {
        $blockReasons += "vod_preview_manual_review_count_gt_zero"
    }

    if ([string]::IsNullOrWhiteSpace($vodPreviewOutputCsv) -or -not (Test-Path -LiteralPath $vodPreviewOutputCsv)) {
        $blockReasons += "vod_preview_output_csv_missing"
    }

    if (@($blockReasons).Count -eq 0) {
        $disposition = "dry_run_would_apply"
        $wouldWriteCount = [Math]::Min($Limit, $plannedImportCount)

        if ($Apply) {
            $disposition = "blocked_apply_not_implemented_yet"
            $blockReasons += "db_apply_step_not_implemented_in_skeleton"
            $actualWriteCount = 0
            $dbWrites = $false
        }
    }

    $status = "pass"
    if ($disposition -match "^blocked") {
        $status = "warning"
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $reportCsv = Join-Path $OutputRoot "vod_streams_delta_limited_apply_$timestamp.csv"
    $reportJson = Join-Path $OutputRoot "vod_streams_delta_limited_apply_$timestamp.json"
    $summaryJson = Join-Path $OutputRoot "vod_streams_delta_limited_apply_summary_$timestamp.json"

    $row = [pscustomobject][ordered]@{
        disposition = $disposition
        dry_run = $dryRun
        apply_requested = [bool]$Apply
        limit = $Limit
        candidate_found = $candidateFound
        selected_lane = $selectedLane
        selector_disposition = $selectorDisposition
        selector_next_worker = $selectorNextWorker
        planned_import_count = $plannedImportCount
        source_row_count = $sourceRowCount
        manual_review_count = $manualReviewCount
        skipped_provider_noise_count = $skippedProviderNoiseCount
        would_write_count = $wouldWriteCount
        actual_write_count = $actualWriteCount
        db_writes = $dbWrites
        provider_calls = $false
        block_reasons = ($blockReasons -join "|")
    }

    $row | Export-Csv -Path $reportCsv -NoTypeInformation
    $row | ConvertTo-Json -Depth 20 | Set-Content -Path $reportJson -Encoding UTF8

    $summary = [ordered]@{
        status = $status
        disposition = $disposition
        dry_run = $dryRun
        apply_requested = [bool]$Apply
        db_writes = $dbWrites
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        candidate_found = $candidateFound
        selected_lane = $selectedLane
        selector_disposition = $selectorDisposition
        selector_next_worker = $selectorNextWorker
        planned_import_count = $plannedImportCount
        source_row_count = $sourceRowCount
        manual_review_count = $manualReviewCount
        skipped_provider_noise_count = $skippedProviderNoiseCount
        would_write_count = $wouldWriteCount
        actual_write_count = $actualWriteCount
        block_reasons = $blockReasons
        report_csv = $reportCsv
        report_json = $reportJson
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $status -Payload $summary
    Emit-LocalSignal -SignalName $DispositionSignal -SignalValue $disposition -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $WouldWriteCountSignal -SignalValue $wouldWriteCount -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $ActualWriteCountSignal -SignalValue $actualWriteCount -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: VOD streams limited apply gate evaluated. status=$status disposition=$disposition dry_run=$dryRun would_write=$wouldWriteCount actual_write=$actualWriteCount db_writes=$dbWrites provider_calls=False run_id=$RunId"
        Write-Output "FILES: report_csv=$reportCsv report_json=$reportJson summary_json=$summaryJson"
        Import-Csv $reportCsv | Format-List
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

    Write-Error "FAILED: VOD streams limited apply gate failed. $message run_id=$RunId"
    exit 1
}
