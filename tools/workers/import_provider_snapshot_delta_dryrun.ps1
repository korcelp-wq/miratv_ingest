<#
.SYNOPSIS
  Dry-run provider snapshot delta import decisions without writing to the database.

.DESCRIPTION
  Reads the latest provider snapshot import preview report produced by
  plan_provider_snapshot_import_preview.ps1 and simulates the import lane decisions.

  This worker is intentionally no-write:
    - no provider calls
    - no database writes
    - no import execution
    - runtime reports only

  Golden grinder rule preserved:
    System-level failures may stop the worker.
    Lane/row-level issues become dispositions.

.EXAMPLE
  pwsh -NoProfile -ExecutionPolicy Bypass `
    -File ".\tools\workers\import_provider_snapshot_delta_dryrun.ps1" `
    -Environment "dev"
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [string]$InputCsv,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "import_provider_snapshot_delta_dryrun"
$Component = "provider_snapshot_delta_import_dryrun"
$DatabaseTarget = "none"
$SourceName = "provider_snapshot_import_preview_report"
$KillSwitchName = "ENABLE_PROVIDER_SNAPSHOT_DELTA_IMPORT_DRYRUN"
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\provider_snapshot_delta_import_dryrun"
$LogRoot = Join-Path $RepoRoot "runtime\logs\provider_snapshot_delta_import_dryrun"
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

function Get-LatestImportPreviewCsv {
    if (-not [string]::IsNullOrWhiteSpace($InputCsv)) {
        if (-not (Test-Path $InputCsv)) {
            throw "InputCsv not found: $InputCsv"
        }
        return (Resolve-Path $InputCsv).Path
    }

    $previewRoot = Join-Path $RepoRoot "runtime\reports\provider_snapshot_import_preview"
    if (-not (Test-Path $previewRoot)) {
        throw "Provider snapshot import preview report folder not found: $previewRoot"
    }

    $candidates = Get-ChildItem -Path $previewRoot -Filter "*.csv" -File -Recurse |
        Where-Object { $_.Name -match "provider_snapshot_import_preview" } |
        Sort-Object LastWriteTimeUtc -Descending

    if (-not $candidates -or $candidates.Count -eq 0) {
        throw "No provider snapshot import preview CSV report found under: $previewRoot"
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
    return ($text -in @("1", "true", "yes", "y", "import", "import_needed"))
}

function Get-DryRunDisposition {
    param([object]$Row)

    $importDisposition = ([string](Get-FirstValue -Row $Row -Names @("import_disposition", "disposition") -Default "")).Trim().ToLowerInvariant()
    $shouldImport = ConvertTo-BoolLoose (Get-FirstValue -Row $Row -Names @("should_import") -Default $false)

    if ($importDisposition -eq "import_needed" -or $shouldImport) {
        return @{
            dryrun_disposition = "dryrun_import_planned"
            dryrun_reason      = "preview_marked_import_needed"
            would_import       = $true
            would_write_db     = $false
        }
    }

    if ($importDisposition -eq "skip_provider_noise") {
        return @{
            dryrun_disposition = "skipped_provider_noise"
            dryrun_reason      = "raw_changed_normalized_unchanged"
            would_import       = $false
            would_write_db     = $false
        }
    }

    if ($importDisposition -eq "manual_review") {
        return @{
            dryrun_disposition = "manual_review"
            dryrun_reason      = "preview_marked_manual_review"
            would_import       = $false
            would_write_db     = $false
        }
    }

    if ($importDisposition -eq "baseline_only") {
        return @{
            dryrun_disposition = "baseline_only_no_import"
            dryrun_reason      = "preview_baseline_only"
            would_import       = $false
            would_write_db     = $false
        }
    }

    if ($importDisposition -eq "normalized_no_change") {
        return @{
            dryrun_disposition = "skipped_normalized_no_change"
            dryrun_reason      = "preview_normalized_no_change"
            would_import       = $false
            would_write_db     = $false
        }
    }

    return @{
        dryrun_disposition = "manual_review"
        dryrun_reason      = "unknown_preview_disposition_$importDisposition"
        would_import       = $false
        would_write_db     = $false
    }
}

try {
    if (-not (Test-WorkerKillSwitch)) {
        Invoke-ContractLog -EventName "job_skipped" -Status "skipped" -Data @{ kill_switch = $KillSwitchName }
        Invoke-ContractSignal -SignalName "provider_snapshot_delta_import_dryrun_completed" -SignalValue "disabled" -Payload @{ reason = "kill_switch_disabled" }
        if (-not $Quiet) { Write-Host "SKIPPED: $KillSwitchName is disabled." }
        exit 0
    }

    Invoke-ContractLog -EventName "job_started" -Status "started" -Data @{ dry_run = $true; db_writes = $false }
    Invoke-ContractHeartbeat -Status "running"
    Invoke-ContractSignal -SignalName "provider_snapshot_delta_import_dryrun_completed" -SignalValue "running" -Payload @{ dry_run = $true; db_writes = $false }

    $previewCsv = Get-LatestImportPreviewCsv
    $rows = Import-Csv -Path $previewCsv

    if ($null -eq $rows) { $rows = @() }
    if ($rows -isnot [array]) { $rows = @($rows) }

    $dryRunRows = New-Object System.Collections.Generic.List[object]
    $rowNumber = 0

    foreach ($row in $rows) {
        $rowNumber++
        $decision = Get-DryRunDisposition -Row $row
        $laneKey = Get-FirstValue -Row $row -Names @("lane_key", "lane", "media_type") -Default "lane_$rowNumber"

        $dryRunRows.Add([pscustomobject]@{
            run_id              = $RunId
            row_number          = $rowNumber
            lane_key            = $laneKey
            media_type          = Get-FirstValue -Row $row -Names @("media_type") -Default ""
            snapshot_kind       = Get-FirstValue -Row $row -Names @("snapshot_kind") -Default ""
            source_preview_csv  = $previewCsv
            import_disposition  = Get-FirstValue -Row $row -Names @("import_disposition") -Default ""
            import_reason       = Get-FirstValue -Row $row -Names @("import_reason") -Default ""
            should_import       = Get-FirstValue -Row $row -Names @("should_import") -Default "False"
            dryrun_disposition  = $decision.dryrun_disposition
            dryrun_reason       = $decision.dryrun_reason
            would_import        = [bool]$decision.would_import
            would_write_db      = [bool]$decision.would_write_db
            dry_run             = $true
            db_writes           = $false
            row_disposition     = "processed"
            generated_at_utc    = (Get-Date).ToUniversalTime().ToString("o")
        })
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $dryRunCsv = Join-Path $OutputRoot "provider_snapshot_delta_import_dryrun_$timestamp.csv"
    $summaryJson = Join-Path $OutputRoot "provider_snapshot_delta_import_dryrun_summary_$timestamp.json"

    $dryRunRows | Export-Csv -NoTypeInformation -Path $dryRunCsv -Encoding UTF8

    $totalLanes = $dryRunRows.Count
    $wouldImportCount = @($dryRunRows | Where-Object { $_.would_import -eq $true }).Count
    $skippedProviderNoiseCount = @($dryRunRows | Where-Object { $_.dryrun_disposition -eq "skipped_provider_noise" }).Count
    $manualReviewCount = @($dryRunRows | Where-Object { $_.dryrun_disposition -eq "manual_review" }).Count
    $baselineOnlyCount = @($dryRunRows | Where-Object { $_.dryrun_disposition -eq "baseline_only_no_import" }).Count
    $skippedNoChangeCount = @($dryRunRows | Where-Object { $_.dryrun_disposition -eq "skipped_normalized_no_change" }).Count

    $EndedAt = Get-Date
    $durationMs = [int][math]::Round(($EndedAt - $StartedAt).TotalMilliseconds)

    $summary = [ordered]@{
        worker_name                     = $WorkerName
        run_id                          = $RunId
        status                          = "pass"
        environment                     = $Environment
        dry_run                         = $true
        preview_only                    = $true
        db_writes                       = $false
        source_preview_csv              = $previewCsv
        output_csv                      = $dryRunCsv
        total_lanes                     = $totalLanes
        would_import_count              = $wouldImportCount
        skipped_provider_noise_count    = $skippedProviderNoiseCount
        manual_review_count             = $manualReviewCount
        baseline_only_count             = $baselineOnlyCount
        skipped_normalized_no_change    = $skippedNoChangeCount
        started_at_utc                  = $StartedAt.ToUniversalTime().ToString("o")
        ended_at_utc                    = $EndedAt.ToUniversalTime().ToString("o")
        duration_ms                     = $durationMs
    }

    $summary | ConvertTo-Json -Depth 12 | Set-Content -Path $summaryJson -Encoding UTF8

    Invoke-ContractLog -EventName "source_row_count" -Status "ok" -Data @{ source_rows = $totalLanes; source_preview_csv = $previewCsv }
    Invoke-ContractLog -EventName "rows_inserted" -Status "ok" -Data @{ count = 0; reason = "dry_run_no_db_writes" }
    Invoke-ContractLog -EventName "rows_updated" -Status "ok" -Data @{ count = 0; reason = "dry_run_no_db_writes" }
    Invoke-ContractLog -EventName "rows_skipped" -Status "ok" -Data @{ count = ($skippedProviderNoiseCount + $baselineOnlyCount + $skippedNoChangeCount) }
    Invoke-ContractLog -EventName "rows_failed" -Status "ok" -Data @{ count = 0 }
    Invoke-ContractLog -EventName "checkpoint_saved" -Status "ok" -Data @{ output_csv = $dryRunCsv; summary_json = $summaryJson }
    Invoke-ContractLog -EventName "job_completed" -Status "pass" -Data $summary
    Invoke-ContractHeartbeat -Status "completed"

    Invoke-ContractSignal -SignalName "provider_snapshot_delta_import_dryrun_completed" -SignalValue "pass" -Payload $summary
    Invoke-ContractSignal -SignalName "provider_snapshot_delta_import_dryrun_would_import_count" -SignalValue $wouldImportCount -Payload @{ run_id = $RunId }
    Invoke-ContractSignal -SignalName "provider_snapshot_delta_import_dryrun_skip_provider_noise_count" -SignalValue $skippedProviderNoiseCount -Payload @{ run_id = $RunId }
    Invoke-ContractSignal -SignalName "provider_snapshot_delta_import_dryrun_manual_review_count" -SignalValue $manualReviewCount -Payload @{ run_id = $RunId }

    if (-not $Quiet) {
        Write-Host "OK: provider snapshot delta import dryrun completed. status=pass dry_run=True db_writes=False total_lanes=$totalLanes would_import=$wouldImportCount skip_provider_noise=$skippedProviderNoiseCount manual_review=$manualReviewCount run_id=$RunId"
        Write-Host "FILES: dryrun_csv=$dryRunCsv summary_json=$summaryJson"
        $dryRunRows | Format-Table row_number, lane_key, media_type, snapshot_kind, import_disposition, dryrun_disposition, would_import, would_write_db -AutoSize
    }

    exit 0
}
catch {
    $EndedAt = Get-Date
    $durationMs = [int][math]::Round(($EndedAt - $StartedAt).TotalMilliseconds)
    $message = $_.Exception.Message

    Invoke-ContractLog -EventName "job_failed" -Status "failed" -Data @{
        error_code    = "provider_snapshot_delta_import_dryrun_failed"
        error_message = $message
        duration_ms   = $durationMs
    }
    Invoke-ContractHeartbeat -Status "failed"
    Invoke-ContractSignal -SignalName "provider_snapshot_delta_import_dryrun_completed" -SignalValue "failed" -Payload @{
        error_code    = "provider_snapshot_delta_import_dryrun_failed"
        error_message = $message
        run_id        = $RunId
    }

    Write-Error "FAILED: provider snapshot delta import dryrun failed. $message"
    exit 1
}
