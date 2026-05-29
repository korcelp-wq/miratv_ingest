<#
.SYNOPSIS
  Plan provider snapshot import execution from readiness and preview reports.

.DESCRIPTION
  Read-only execution planner. It consumes existing summary JSON reports and produces a
  lane-level execution plan for the next controlled import phase.

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

$WorkerName = "plan_provider_snapshot_import_execution"
$Component = "provider_snapshot_import_execution_plan"
$DatabaseTarget = "none"
$SourceName = "runtime_reports"
$KillSwitchName = "ENABLE_PROVIDER_SNAPSHOT_IMPORT_EXECUTION_PLAN"

$CompletedSignal = "provider_snapshot_import_execution_plan_completed"
$PlannedCountSignal = "provider_snapshot_import_execution_plan_planned_count"
$BlockedCountSignal = "provider_snapshot_import_execution_plan_blocked_count"
$NoopCountSignal = "provider_snapshot_import_execution_plan_noop_count"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\provider_snapshot_import_execution_plan"
$LogRoot = Join-Path $RepoRoot "runtime\logs\provider_snapshot_import_execution_plan"

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

    $number = 0
    if ([int]::TryParse([string]$Value, [ref]$number)) {
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

    $readiness = Get-LatestSummary -ReportFolder "provider_snapshot_import_readiness" -Filter "provider_snapshot_import_readiness_summary_*.json"
    $dryrun = Get-LatestSummary -ReportFolder "provider_snapshot_delta_import_dryrun" -Filter "provider_snapshot_delta_import_dryrun_summary_*.json"
    $vodPreview = Get-LatestSummary -ReportFolder "vod_streams_delta_import_preview" -Filter "vod_streams_delta_import_preview_summary_*.json"
    $importPreview = Get-LatestSummary -ReportFolder "provider_snapshot_import_preview" -Filter "provider_snapshot_import_preview_summary_*.json"

    $rows = New-Object System.Collections.Generic.List[object]

    if (-not $readiness.found) {
        $rows.Add([pscustomobject][ordered]@{
            execution_order = 1
            lane_key = "all"
            action = "blocked"
            reason = "missing_readiness_summary"
            source_rows = 0
            would_call_provider = $false
            would_write_db = $false
        }) | Out-Null
    }
    else {
        $readinessData = $readiness.data
        $readinessDisposition = [string](Get-PropertyValue -Object $readinessData -Names @("readiness_disposition") -Default "unknown")
        $readinessStatus = [string](Get-PropertyValue -Object $readinessData -Names @("status") -Default "unknown")
        $readinessBlocked = Convert-ToInt (Get-PropertyValue -Object $readinessData -Names @("blocked_count") -Default 0)
        $readinessReview = Convert-ToInt (Get-PropertyValue -Object $readinessData -Names @("review_count") -Default 0)

        if ($readinessBlocked -gt 0 -or $readinessStatus -eq "fail") {
            $rows.Add([pscustomobject][ordered]@{
                execution_order = 1
                lane_key = "all"
                action = "blocked"
                reason = "readiness_blocked:$readinessDisposition"
                source_rows = 0
                would_call_provider = $false
                would_write_db = $false
            }) | Out-Null
        }
        elseif ($readinessReview -gt 0) {
            $rows.Add([pscustomobject][ordered]@{
                execution_order = 1
                lane_key = "all"
                action = "manual_review"
                reason = "readiness_requires_review:$readinessDisposition"
                source_rows = 0
                would_call_provider = $false
                would_write_db = $false
            }) | Out-Null
        }
        else {
            $dryrunWouldImport = 0
            if ($dryrun.found) {
                $dryrunWouldImport = Convert-ToInt (Get-PropertyValue -Object $dryrun.data -Names @("would_import", "would_import_count", "lanes_import_needed") -Default 0)
            }

            $vodPlannedImport = 0
            $vodSourceRows = 0
            if ($vodPreview.found) {
                $vodPlannedImport = Convert-ToInt (Get-PropertyValue -Object $vodPreview.data -Names @("planned_import", "planned_import_count") -Default 0)
                $vodSourceRows = Convert-ToInt (Get-PropertyValue -Object $vodPreview.data -Names @("source_rows", "source_row_count") -Default 0)
            }

            if ($vodPlannedImport -gt 0 -or $dryrunWouldImport -gt 0) {
                $rows.Add([pscustomobject][ordered]@{
                    execution_order = 1
                    lane_key = "vod_streams"
                    action = "plan_preview_only_import_worker"
                    reason = "dryrun_or_vod_preview_planned_import"
                    source_rows = $vodSourceRows
                    would_call_provider = $false
                    would_write_db = $false
                }) | Out-Null
            }
            else {
                $skipProviderNoise = 0
                if ($importPreview.found) {
                    $skipProviderNoise = Convert-ToInt (Get-PropertyValue -Object $importPreview.data -Names @("skip_provider_noise", "skip_provider_noise_count") -Default 0)
                }

                $rows.Add([pscustomobject][ordered]@{
                    execution_order = 1
                    lane_key = "all"
                    action = "noop"
                    reason = "no_import_needed; skip_provider_noise_count=$skipProviderNoise"
                    source_rows = 0
                    would_call_provider = $false
                    would_write_db = $false
                }) | Out-Null
            }
        }
    }

    $plannedCount = @($rows | Where-Object { $_.action -like "plan_*" }).Count
    $blockedCount = @($rows | Where-Object { $_.action -eq "blocked" }).Count
    $noopCount = @($rows | Where-Object { $_.action -eq "noop" }).Count
    $reviewCount = @($rows | Where-Object { $_.action -eq "manual_review" }).Count

    $overallStatus = if ($blockedCount -gt 0) { "fail" } elseif ($reviewCount -gt 0) { "warning" } else { "pass" }
    $executionDisposition = if ($blockedCount -gt 0) { "blocked" } elseif ($reviewCount -gt 0) { "manual_review" } elseif ($plannedCount -gt 0) { "planned_next_preview" } else { "noop_ready" }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $planCsv = Join-Path $OutputRoot "provider_snapshot_import_execution_plan_$timestamp.csv"
    $summaryJson = Join-Path $OutputRoot "provider_snapshot_import_execution_plan_summary_$timestamp.json"

    $rows | Export-Csv -Path $planCsv -NoTypeInformation

    $summary = [ordered]@{
        status = $overallStatus
        execution_disposition = $executionDisposition
        preview_only = $true
        db_writes = $false
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        planned_count = $plannedCount
        blocked_count = $blockedCount
        noop_count = $noopCount
        review_count = $reviewCount
        readiness_found = [bool]$readiness.found
        dryrun_found = [bool]$dryrun.found
        vod_streams_preview_found = [bool]$vodPreview.found
        import_preview_found = [bool]$importPreview.found
        plan_csv = $planCsv
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $overallStatus -Payload $summary
    Emit-LocalSignal -SignalName $PlannedCountSignal -SignalValue $plannedCount -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $BlockedCountSignal -SignalValue $blockedCount -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $NoopCountSignal -SignalValue $noopCount -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $overallStatus -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: provider snapshot import execution plan completed. status=$overallStatus disposition=$executionDisposition planned=$plannedCount blocked=$blockedCount noop=$noopCount db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: plan_csv=$planCsv summary_json=$summaryJson"
        $rows | Format-Table execution_order, lane_key, action, reason, source_rows, would_write_db -AutoSize
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

    Write-Error "FAILED: provider snapshot import execution plan failed. $message run_id=$RunId"
    exit 1
}
