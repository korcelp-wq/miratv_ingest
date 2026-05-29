<#
.SYNOPSIS
  Summarize provider snapshot import readiness from existing runtime reports.

.DESCRIPTION
  Read-only readiness summarizer. It reads the latest existing summary JSON reports from:
    - provider_snapshot_spine_runner
    - provider_snapshot_import_preview
    - provider_snapshot_delta_import_dryrun
    - vod_streams_delta_import_preview
    - grinder_disposition_contract

  It does not read provider snapshot payloads.
  It does not call providers.
  It does not read or write the database.
  It does not import anything.

.CONTRACT-MARKERS
  Write-JobLog
  Emit-Signal
  Emit-Heartbeat
  Test-KillSwitch
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "summarize_provider_snapshot_import_readiness"
$Component = "provider_snapshot_import_readiness"
$DatabaseTarget = "none"
$SourceName = "runtime_reports"
$KillSwitchName = "ENABLE_PROVIDER_SNAPSHOT_IMPORT_READINESS_SUMMARY"

$CompletedSignal = "provider_snapshot_import_readiness_summary_completed"
$ReadyCountSignal = "provider_snapshot_import_readiness_ready_count"
$BlockedCountSignal = "provider_snapshot_import_readiness_blocked_count"
$ReviewCountSignal = "provider_snapshot_import_readiness_review_count"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\provider_snapshot_import_readiness"
$LogRoot = Join-Path $RepoRoot "runtime\logs\provider_snapshot_import_readiness"

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null

function Get-DurationMs {
    param([datetime]$Start)
    return [int][Math]::Round(((Get-Date) - $Start).TotalMilliseconds)
}

function Write-LocalJsonLog {
    param(
        [string]$EventName,
        [string]$Status,
        [object]$Data = $null
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
    Add-Content -Path $logPath -Value ($record | ConvertTo-Json -Depth 20 -Compress)
}

function Emit-LocalSignal {
    param(
        [string]$SignalName,
        [object]$SignalValue,
        [object]$Payload = $null
    )

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
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $true
    }

    $normalized = $raw.Trim().ToLowerInvariant()
    return ($normalized -notin @("0", "false", "no", "off", "disabled"))
}

function Get-LatestSummary {
    param(
        [string]$ReportFolder,
        [string]$Filter
    )

    $folder = Join-Path $RepoRoot ("runtime\reports\{0}" -f $ReportFolder)

    if (-not (Test-Path -LiteralPath $folder)) {
        return [pscustomobject]@{
            found = $false
            path = $null
            data = $null
            reason = "folder_missing"
        }
    }

    $file = Get-ChildItem -LiteralPath $folder -Filter $Filter -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $file) {
        return [pscustomobject]@{
            found = $false
            path = $null
            data = $null
            reason = "summary_missing"
        }
    }

    try {
        $data = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
        return [pscustomobject]@{
            found = $true
            path = $file.FullName
            data = $data
            reason = "ok"
        }
    }
    catch {
        return [pscustomobject]@{
            found = $false
            path = $file.FullName
            data = $null
            reason = "summary_parse_failed: $($_.Exception.Message)"
        }
    }
}

function Get-PropertyValue {
    param(
        [object]$Object,
        [string[]]$Names,
        [object]$Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties |
            Where-Object { $_.Name -ieq $name } |
            Select-Object -First 1

        if ($null -ne $property) {
            return $property.Value
        }
    }

    return $Default
}

function Convert-ToInt {
    param([object]$Value, [int]$Default = 0)

    if ($null -eq $Value) {
        return $Default
    }

    $text = [string]$Value
    $number = 0
    if ([int]::TryParse($text, [ref]$number)) {
        return $number
    }

    return $Default
}

try {
    Write-LocalJsonLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        preview_only = $true
        db_writes = $false
        provider_calls = $false
    })

    Emit-LocalHeartbeat -Status "running"

    if (-not (Test-WorkerKillSwitch)) {
        $summary = [ordered]@{
            status = "disabled"
            preview_only = $true
            db_writes = $false
            provider_calls = $false
            run_id = $RunId
        }

        Emit-LocalSignal -SignalName $CompletedSignal -SignalValue "disabled" -Payload $summary
        Write-LocalJsonLog -EventName "job_completed" -Status "disabled" -Data $summary
        Write-Output "SKIPPED: $KillSwitchName is disabled. run_id=$RunId"
        exit 0
    }

    $sources = [ordered]@{
        spine = Get-LatestSummary -ReportFolder "provider_snapshot_spine_runner" -Filter "provider_snapshot_spine_runner_summary_*.json"
        import_preview = Get-LatestSummary -ReportFolder "provider_snapshot_import_preview" -Filter "provider_snapshot_import_preview_summary_*.json"
        import_dryrun = Get-LatestSummary -ReportFolder "provider_snapshot_delta_import_dryrun" -Filter "provider_snapshot_delta_import_dryrun_summary_*.json"
        vod_streams_preview = Get-LatestSummary -ReportFolder "vod_streams_delta_import_preview" -Filter "vod_streams_delta_import_preview_summary_*.json"
        grinder_contract = Get-LatestSummary -ReportFolder "grinder_disposition_contract" -Filter "grinder_disposition_contract_summary_*.json"
    }

    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($key in $sources.Keys) {
        $source = $sources[$key]
        $data = $source.data

        $sourceStatus = if ($source.found) { [string](Get-PropertyValue -Object $data -Names @("status", "overall_status") -Default "unknown") } else { "missing" }
        $blockReason = if ($source.found) { "" } else { [string]$source.reason }

        $rows.Add([pscustomobject][ordered]@{
            source_key = $key
            found = [bool]$source.found
            status = $sourceStatus
            path = $source.path
            block_reason = $blockReason
        }) | Out-Null
    }

    $allRequiredFound = @($rows | Where-Object { -not $_.found }).Count -eq 0
    $failedSources = @($rows | Where-Object { $_.status -in @("fail", "failed", "error", "blocked") }).Count
    $warningSources = @($rows | Where-Object { $_.status -in @("warning") }).Count

    $previewData = $sources.import_preview.data
    $dryrunData = $sources.import_dryrun.data
    $vodPreviewData = $sources.vod_streams_preview.data
    $grinderData = $sources.grinder_contract.data
    $spineData = $sources.spine.data

    $importNeeded = Convert-ToInt (Get-PropertyValue -Object $previewData -Names @("import_needed", "import_needed_count") -Default 0)
    $skipProviderNoise = Convert-ToInt (Get-PropertyValue -Object $previewData -Names @("skip_provider_noise", "skip_provider_noise_count") -Default 0)
    $manualReview = Convert-ToInt (Get-PropertyValue -Object $previewData -Names @("manual_review", "manual_review_count") -Default 0)

    $dryrunWouldImport = Convert-ToInt (Get-PropertyValue -Object $dryrunData -Names @("would_import", "would_import_count", "lanes_import_needed") -Default 0)
    $dryrunManualReview = Convert-ToInt (Get-PropertyValue -Object $dryrunData -Names @("manual_review", "manual_review_count", "lanes_manual_review") -Default 0)

    $vodPlannedImport = Convert-ToInt (Get-PropertyValue -Object $vodPreviewData -Names @("planned_import", "planned_import_count") -Default 0)
    $vodManualReview = Convert-ToInt (Get-PropertyValue -Object $vodPreviewData -Names @("manual_review", "manual_review_count") -Default 0)
    $vodSourceRows = Convert-ToInt (Get-PropertyValue -Object $vodPreviewData -Names @("source_rows", "source_row_count") -Default 0)

    $grinderNeedsReview = Convert-ToInt (Get-PropertyValue -Object $grinderData -Names @("needs_review", "needs_review_count") -Default 0)
    $grinderCompliant = Convert-ToInt (Get-PropertyValue -Object $grinderData -Names @("compliant", "compliant_count") -Default 0)

    $spineDbImported = [bool](Get-PropertyValue -Object $spineData -Names @("db_imported") -Default $false)
    $spineProviderCalls = [bool](Get-PropertyValue -Object $spineData -Names @("provider_calls") -Default $false)

    $readyCount = 0
    $blockedCount = 0
    $reviewCount = 0
    $readinessDisposition = "ready_for_next_preview"

    if (-not $allRequiredFound) {
        $blockedCount++
        $readinessDisposition = "blocked_missing_required_report"
    }

    if ($failedSources -gt 0) {
        $blockedCount += $failedSources
        $readinessDisposition = "blocked_failed_report"
    }

    $reviewCount = $manualReview + $dryrunManualReview + $vodManualReview + $grinderNeedsReview

    if ($reviewCount -gt 0 -and $readinessDisposition -eq "ready_for_next_preview") {
        $readinessDisposition = "needs_manual_review"
    }

    if ($spineDbImported) {
        $blockedCount++
        $readinessDisposition = "blocked_unexpected_db_import"
    }

    if ($readinessDisposition -eq "ready_for_next_preview") {
        $readyCount = 1
    }

    $overallStatus = if ($blockedCount -gt 0) { "fail" } elseif ($reviewCount -gt 0 -or $warningSources -gt 0) { "warning" } else { "pass" }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $reportCsv = Join-Path $OutputRoot "provider_snapshot_import_readiness_sources_$timestamp.csv"
    $summaryJson = Join-Path $OutputRoot "provider_snapshot_import_readiness_summary_$timestamp.json"

    $rows | Export-Csv -Path $reportCsv -NoTypeInformation

    $summary = [ordered]@{
        status = $overallStatus
        readiness_disposition = $readinessDisposition
        preview_only = $true
        db_writes = $false
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        required_reports_found = $allRequiredFound
        failed_source_count = $failedSources
        warning_source_count = $warningSources
        ready_count = $readyCount
        blocked_count = $blockedCount
        review_count = $reviewCount
        import_needed_count = $importNeeded
        skip_provider_noise_count = $skipProviderNoise
        manual_review_count = $manualReview
        dryrun_would_import_count = $dryrunWouldImport
        dryrun_manual_review_count = $dryrunManualReview
        vod_streams_planned_import_count = $vodPlannedImport
        vod_streams_manual_review_count = $vodManualReview
        vod_streams_source_rows = $vodSourceRows
        grinder_needs_review_count = $grinderNeedsReview
        grinder_compliant_count = $grinderCompliant
        spine_db_imported = $spineDbImported
        spine_provider_calls = $spineProviderCalls
        report_csv = $reportCsv
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $overallStatus -Payload $summary
    Emit-LocalSignal -SignalName $ReadyCountSignal -SignalValue $readyCount -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $BlockedCountSignal -SignalValue $blockedCount -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $ReviewCountSignal -SignalValue $reviewCount -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $overallStatus -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: provider snapshot import readiness summary completed. status=$overallStatus disposition=$readinessDisposition ready=$readyCount blocked=$blockedCount review=$reviewCount db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: report_csv=$reportCsv summary_json=$summaryJson"
        $rows | Format-Table source_key, found, status, block_reason -AutoSize
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

    Write-Error "FAILED: provider snapshot import readiness summary failed. $message run_id=$RunId"
    exit 1
}
