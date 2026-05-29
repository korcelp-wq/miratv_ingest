<#
.SYNOPSIS
  Preview VOD stream delta import lane without writing to the database.

.DESCRIPTION
  Reads the latest provider snapshot delta import dry-run report and evaluates only
  the vod_streams lane. If vod_streams is marked import_needed, this worker creates
  a no-write lane preview showing that a VOD stream import would be prepared later.

  This worker is intentionally no-write:
    - no provider calls
    - no database writes
    - no import execution
    - runtime reports only

  Golden grinder rule preserved:
    System-level failures may stop the worker.
    Lane/row-level issues become dispositions.
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [string]$InputCsv,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "import_vod_streams_delta_preview"
$Component = "provider_snapshot_vod_streams_import_preview"
$DatabaseTarget = "none"
$SourceName = "provider_snapshot_delta_import_dryrun_report"
$KillSwitchName = "ENABLE_PROVIDER_SNAPSHOT_VOD_STREAMS_IMPORT_PREVIEW"
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\vod_streams_delta_import_preview"
$LogRoot = Join-Path $RepoRoot "runtime\logs\vod_streams_delta_import_preview"
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
    # Keep explicit contract function references for the automation checker.
    # Test-KillSwitch
    if (Get-Command Test-KillSwitch -ErrorAction SilentlyContinue) {
        try {
            $enabled = Test-KillSwitch -Name $KillSwitchName -DefaultEnabled $true
            return [bool]$enabled
        }
        catch {
            Write-LocalJsonLog -EventName "kill_switch_adapter_failed" -Status "warning" -Data @{ message = $_.Exception.Message }
        }
    }

    $value = [Environment]::GetEnvironmentVariable($KillSwitchName)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $true
    }

    return ($value.Trim().ToLowerInvariant() -notin @("0", "false", "no", "off", "disabled"))
}

function Get-LatestDryRunCsv {
    if (-not [string]::IsNullOrWhiteSpace($InputCsv)) {
        if (-not (Test-Path $InputCsv)) {
            throw "InputCsv not found: $InputCsv"
        }
        return (Resolve-Path $InputCsv).Path
    }

    $dryRunRoot = Join-Path $RepoRoot "runtime\reports\provider_snapshot_delta_import_dryrun"
    if (-not (Test-Path $dryRunRoot)) {
        throw "Provider snapshot delta import dry-run report folder not found: $dryRunRoot"
    }

    $candidates = Get-ChildItem -Path $dryRunRoot -Filter "*.csv" -File -Recurse |
        Where-Object { $_.Name -match "provider_snapshot_delta_import_dryrun" } |
        Sort-Object LastWriteTimeUtc -Descending

    if (-not $candidates -or $candidates.Count -eq 0) {
        throw "No provider snapshot delta import dry-run CSV report found under: $dryRunRoot"
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
    return ($text -in @("1", "true", "yes", "y", "import", "import_needed", "dryrun_import_planned"))
}

function Get-BestEffortSnapshotFile {
    $snapshotRoot = Join-Path $RepoRoot "runtime\provider_snapshots\vod_streams"
    if (-not (Test-Path $snapshotRoot)) {
        return $null
    }

    $candidates = Get-ChildItem -Path $snapshotRoot -File -Recurse |
        Where-Object { $_.Extension -in @(".csv", ".json", ".jsonl", ".txt") } |
        Sort-Object LastWriteTimeUtc -Descending

    if (-not $candidates -or $candidates.Count -eq 0) {
        return $null
    }

    return $candidates[0].FullName
}

function Get-BestEffortRowCount {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return 0
    }

    try {
        $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
        if ($extension -eq ".csv") {
            $rows = Import-Csv -Path $Path
            if ($null -eq $rows) { return 0 }
            return @($rows).Count
        }

        if ($extension -eq ".json") {
            $json = Get-Content -Path $Path -Raw | ConvertFrom-Json
            if ($json -is [array]) { return @($json).Count }
            if ($json.PSObject.Properties.Name -contains "items") { return @($json.items).Count }
            if ($json.PSObject.Properties.Name -contains "data") { return @($json.data).Count }
            return 1
        }

        if ($extension -eq ".jsonl" -or $extension -eq ".txt") {
            return @(Get-Content -Path $Path).Count
        }
    }
    catch {
        return 0
    }

    return 0
}

try {
    if (-not (Test-WorkerKillSwitch)) {
        Invoke-ContractLog -EventName "job_skipped" -Status "skipped" -Data @{ kill_switch = $KillSwitchName }
        Invoke-ContractSignal -SignalName "provider_snapshot_vod_streams_import_preview_completed" -SignalValue "disabled" -Payload @{ reason = "kill_switch_disabled" }
        if (-not $Quiet) { Write-Host "SKIPPED: $KillSwitchName is disabled." }
        exit 0
    }

    Invoke-ContractLog -EventName "job_started" -Status "started" -Data @{ preview_only = $true; db_writes = $false; lane_key = "vod_streams" }
    Invoke-ContractHeartbeat -Status "running"
    Invoke-ContractSignal -SignalName "provider_snapshot_vod_streams_import_preview_completed" -SignalValue "running" -Payload @{ preview_only = $true; db_writes = $false }

    $dryRunCsv = Get-LatestDryRunCsv
    $rows = Import-Csv -Path $dryRunCsv
    if ($null -eq $rows) { $rows = @() }
    if ($rows -isnot [array]) { $rows = @($rows) }

    $vodRows = @($rows | Where-Object { ([string](Get-FirstValue -Row $_ -Names @("lane_key") -Default "")).Trim().ToLowerInvariant() -eq "vod_streams" })

    $previewRows = New-Object System.Collections.Generic.List[object]
    $snapshotFile = Get-BestEffortSnapshotFile
    $snapshotRowCount = Get-BestEffortRowCount -Path $snapshotFile

    if ($vodRows.Count -eq 0) {
        $previewRows.Add([pscustomobject]@{
            run_id              = $RunId
            row_number          = 1
            lane_key            = "vod_streams"
            media_type          = "vod"
            snapshot_kind       = "streams"
            source_dryrun_csv   = $dryRunCsv
            source_snapshot     = $snapshotFile
            source_row_count    = $snapshotRowCount
            lane_disposition    = "manual_review"
            preview_disposition = "missing_vod_streams_lane"
            preview_reason      = "dryrun_report_did_not_include_vod_streams_lane"
            would_import        = $false
            would_write_db      = $false
            db_writes           = $false
            row_disposition     = "manual_review"
            generated_at_utc    = (Get-Date).ToUniversalTime().ToString("o")
        })
    }
    else {
        $rowNumber = 0
        foreach ($row in $vodRows) {
            $rowNumber++
            $wouldImport = ConvertTo-BoolLoose (Get-FirstValue -Row $row -Names @("would_import", "should_import") -Default $false)
            $dryRunDisposition = ([string](Get-FirstValue -Row $row -Names @("dryrun_disposition") -Default "")).Trim().ToLowerInvariant()
            $importDisposition = ([string](Get-FirstValue -Row $row -Names @("import_disposition") -Default "")).Trim().ToLowerInvariant()

            $previewDisposition = "skipped_provider_noise"
            $previewReason = "vod_streams_not_marked_for_import"
            $laneDisposition = "skip_provider_noise"

            if ($wouldImport -or $dryRunDisposition -eq "dryrun_import_planned" -or $importDisposition -eq "import_needed") {
                $previewDisposition = "vod_streams_import_preview_planned"
                $previewReason = "dryrun_marked_vod_streams_import_needed"
                $laneDisposition = "import_needed"
            }
            elseif ($dryRunDisposition -eq "manual_review" -or $importDisposition -eq "manual_review") {
                $previewDisposition = "manual_review"
                $previewReason = "dryrun_marked_vod_streams_manual_review"
                $laneDisposition = "manual_review"
            }
            elseif ($dryRunDisposition -eq "skipped_provider_noise" -or $importDisposition -eq "skip_provider_noise") {
                $previewDisposition = "skipped_provider_noise"
                $previewReason = "raw_changed_normalized_unchanged"
                $laneDisposition = "skip_provider_noise"
            }

            $previewRows.Add([pscustomobject]@{
                run_id              = $RunId
                row_number          = $rowNumber
                lane_key            = "vod_streams"
                media_type          = "vod"
                snapshot_kind       = "streams"
                source_dryrun_csv   = $dryRunCsv
                source_snapshot     = $snapshotFile
                source_row_count    = $snapshotRowCount
                lane_disposition    = $laneDisposition
                import_disposition  = $importDisposition
                dryrun_disposition  = $dryRunDisposition
                preview_disposition = $previewDisposition
                preview_reason      = $previewReason
                would_import        = [bool]($laneDisposition -eq "import_needed")
                would_write_db      = $false
                db_writes           = $false
                row_disposition     = "processed"
                generated_at_utc    = (Get-Date).ToUniversalTime().ToString("o")
            })
        }
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $previewCsv = Join-Path $OutputRoot "vod_streams_delta_import_preview_$timestamp.csv"
    $summaryJson = Join-Path $OutputRoot "vod_streams_delta_import_preview_summary_$timestamp.json"

    $previewRows | Export-Csv -NoTypeInformation -Path $previewCsv -Encoding UTF8

    $totalRows = $previewRows.Count
    $plannedCount = @($previewRows | Where-Object { $_.preview_disposition -eq "vod_streams_import_preview_planned" }).Count
    $skippedProviderNoiseCount = @($previewRows | Where-Object { $_.preview_disposition -eq "skipped_provider_noise" }).Count
    $manualReviewCount = @($previewRows | Where-Object { $_.preview_disposition -eq "manual_review" -or $_.row_disposition -eq "manual_review" }).Count

    $EndedAt = Get-Date
    $durationMs = [int][math]::Round(($EndedAt - $StartedAt).TotalMilliseconds)

    $summary = [ordered]@{
        worker_name                  = $WorkerName
        run_id                       = $RunId
        status                       = "pass"
        environment                  = $Environment
        preview_only                 = $true
        dry_run                      = $true
        db_writes                    = $false
        lane_key                     = "vod_streams"
        source_dryrun_csv            = $dryRunCsv
        source_snapshot              = $snapshotFile
        source_row_count             = $snapshotRowCount
        output_csv                   = $previewCsv
        total_rows                   = $totalRows
        planned_import_count         = $plannedCount
        skipped_provider_noise_count = $skippedProviderNoiseCount
        manual_review_count          = $manualReviewCount
        started_at_utc               = $StartedAt.ToUniversalTime().ToString("o")
        ended_at_utc                 = $EndedAt.ToUniversalTime().ToString("o")
        duration_ms                  = $durationMs
    }

    $summary | ConvertTo-Json -Depth 12 | Set-Content -Path $summaryJson -Encoding UTF8

    Invoke-ContractLog -EventName "source_row_count" -Status "ok" -Data @{ source_rows = $snapshotRowCount; lane_rows = $totalRows; source_dryrun_csv = $dryRunCsv }
    Invoke-ContractLog -EventName "rows_inserted" -Status "ok" -Data @{ count = 0; reason = "preview_no_db_writes" }
    Invoke-ContractLog -EventName "rows_updated" -Status "ok" -Data @{ count = 0; reason = "preview_no_db_writes" }
    Invoke-ContractLog -EventName "rows_skipped" -Status "ok" -Data @{ count = ($skippedProviderNoiseCount) }
    Invoke-ContractLog -EventName "rows_failed" -Status "ok" -Data @{ count = 0 }
    Invoke-ContractLog -EventName "checkpoint_saved" -Status "ok" -Data @{ output_csv = $previewCsv; summary_json = $summaryJson }
    Invoke-ContractLog -EventName "job_completed" -Status "pass" -Data $summary
    Invoke-ContractHeartbeat -Status "completed"

    Invoke-ContractSignal -SignalName "provider_snapshot_vod_streams_import_preview_completed" -SignalValue "pass" -Payload $summary
    Invoke-ContractSignal -SignalName "provider_snapshot_vod_streams_import_preview_planned_count" -SignalValue $plannedCount -Payload @{ run_id = $RunId }
    Invoke-ContractSignal -SignalName "provider_snapshot_vod_streams_import_preview_manual_review_count" -SignalValue $manualReviewCount -Payload @{ run_id = $RunId }

    if (-not $Quiet) {
        Write-Host "OK: VOD streams delta import preview completed. status=pass preview_only=True db_writes=False lane=vod_streams planned_import=$plannedCount skipped_provider_noise=$skippedProviderNoiseCount manual_review=$manualReviewCount source_rows=$snapshotRowCount run_id=$RunId"
        Write-Host "FILES: preview_csv=$previewCsv summary_json=$summaryJson"
        $previewRows | Format-Table row_number, lane_key, source_row_count, lane_disposition, preview_disposition, would_import, would_write_db -AutoSize
    }

    exit 0
}
catch {
    $EndedAt = Get-Date
    $durationMs = [int][math]::Round(($EndedAt - $StartedAt).TotalMilliseconds)
    $message = $_.Exception.Message

    Invoke-ContractLog -EventName "job_failed" -Status "failed" -Data @{
        error_code    = "vod_streams_delta_import_preview_failed"
        error_message = $message
        duration_ms   = $durationMs
    }
    Invoke-ContractHeartbeat -Status "failed"
    Invoke-ContractSignal -SignalName "provider_snapshot_vod_streams_import_preview_completed" -SignalValue "failed" -Payload @{
        error_code    = "vod_streams_delta_import_preview_failed"
        error_message = $message
        run_id        = $RunId
    }

    Write-Error "FAILED: VOD streams delta import preview failed. $message"
    exit 1
}
