<#
.SYNOPSIS
  Simulate a provider snapshot import candidate selection path.

.DESCRIPTION
  Read-only simulator.

  This worker creates a synthetic provider snapshot import candidate selection report
  without changing real readiness, execution plan, provider snapshot, or database files.

  It is used to test the "candidate_selected" branch while the real provider cycle is
  noop/provider-noise.

  No provider calls.
  No DB reads.
  No DB writes.
  No imports.
  No mutation of real readiness/execution-plan reports.

.CONTRACT-MARKERS
  Write-JobLog
  Emit-Signal
  Emit-Heartbeat
  Test-KillSwitch
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [ValidateSet("vod_streams", "series_streams", "live_streams", "vod_categories", "series_categories", "live_categories")]
    [string]$SimulatedLane = "vod_streams",
    [int]$SimulatedSourceRows = 10,
    [int]$SimulatedPlannedRows = 1,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "simulate_provider_snapshot_import_candidate"
$Component = "provider_snapshot_import_candidate_simulator"
$DatabaseTarget = "none"
$SourceName = "synthetic_provider_snapshot_import_candidate"
$KillSwitchName = "ENABLE_PROVIDER_SNAPSHOT_IMPORT_CANDIDATE_SIMULATOR"

$CompletedSignal = "provider_snapshot_import_candidate_simulated_completed"
$CandidateLaneSignal = "provider_snapshot_import_candidate_simulated_lane"
$CandidateDispositionSignal = "provider_snapshot_import_candidate_simulated_disposition"
$NextWorkerSignal = "provider_snapshot_import_candidate_simulated_next_worker"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\provider_snapshot_import_candidate_simulator"
$LogRoot = Join-Path $RepoRoot "runtime\logs\provider_snapshot_import_candidate_simulator"

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

function Get-NextWorkerForLane {
    param([string]$Lane)

    switch ($Lane) {
        "vod_streams" { return "apply_vod_streams_delta_limited.ps1" }
        "series_streams" { return "apply_series_streams_delta_limited.ps1" }
        "live_streams" { return "apply_live_streams_delta_limited.ps1" }
        "vod_categories" { return "apply_vod_categories_delta_limited.ps1" }
        "series_categories" { return "apply_series_categories_delta_limited.ps1" }
        "live_categories" { return "apply_live_categories_delta_limited.ps1" }
        default { return "plan_lane_specific_apply_contract.ps1" }
    }
}

function Get-Priority {
    param([string]$Lane)

    switch ($Lane) {
        "vod_streams" { return 10 }
        "series_streams" { return 20 }
        "live_streams" { return 30 }
        "vod_categories" { return 40 }
        "series_categories" { return 50 }
        "live_categories" { return 60 }
        default { return 999 }
    }
}

try {
    if ($SimulatedSourceRows -lt 1) { $SimulatedSourceRows = 1 }
    if ($SimulatedPlannedRows -lt 1) { $SimulatedPlannedRows = 1 }

    Write-LocalJsonLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        preview_only = $true
        simulation_only = $true
        db_writes = $false
        provider_calls = $false
        simulated_lane = $SimulatedLane
        simulated_source_rows = $SimulatedSourceRows
        simulated_planned_rows = $SimulatedPlannedRows
    })

    Emit-LocalHeartbeat -Status "running"

    if (-not (Test-WorkerKillSwitch)) {
        $summary = [ordered]@{
            status = "disabled"
            preview_only = $true
            simulation_only = $true
            db_writes = $false
            provider_calls = $false
            run_id = $RunId
        }

        Emit-LocalSignal -SignalName $CompletedSignal -SignalValue "disabled" -Payload $summary
        Write-LocalJsonLog -EventName "job_completed" -Status "disabled" -Data $summary
        Write-Output "SKIPPED: $KillSwitchName is disabled. run_id=$RunId"
        exit 0
    }

    $nextWorker = Get-NextWorkerForLane -Lane $SimulatedLane
    $priority = Get-Priority -Lane $SimulatedLane

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $syntheticPlanCsv = Join-Path $OutputRoot "synthetic_provider_snapshot_import_execution_plan_$timestamp.csv"
    $selectionCsv = Join-Path $OutputRoot "synthetic_provider_snapshot_import_candidate_selection_$timestamp.csv"
    $selectionJson = Join-Path $OutputRoot "synthetic_provider_snapshot_import_candidate_selection_$timestamp.json"
    $summaryJson = Join-Path $OutputRoot "synthetic_provider_snapshot_import_candidate_selection_summary_$timestamp.json"

    $syntheticPlanRows = @(
        [pscustomobject][ordered]@{
            execution_order = 1
            lane_key = $SimulatedLane
            action = "import"
            reason = "synthetic_candidate_for_selector_path_test"
            source_rows = $SimulatedSourceRows
            planned_rows = $SimulatedPlannedRows
            would_call_provider = $false
            would_write_db = $false
            simulation_only = $true
            priority = $priority
        }
    )

    $syntheticPlanRows | Export-Csv -Path $syntheticPlanCsv -NoTypeInformation

    $selectionRow = [pscustomobject][ordered]@{
        candidate_found = $true
        selected_lane = $SimulatedLane
        selector_disposition = "candidate_selected_simulated"
        next_worker = $nextWorker
        reason = "synthetic_candidate_for_selector_path_test"
        simulated_source_rows = $SimulatedSourceRows
        simulated_planned_rows = $SimulatedPlannedRows
        priority = $priority
        simulation_only = $true
        real_execution_plan_mutated = $false
        real_readiness_mutated = $false
        db_writes = $false
        provider_calls = $false
    }

    $selectionRow | Export-Csv -Path $selectionCsv -NoTypeInformation
    $selectionRow | ConvertTo-Json -Depth 20 | Set-Content -Path $selectionJson -Encoding UTF8

    $summary = [ordered]@{
        status = "pass"
        preview_only = $true
        simulation_only = $true
        db_writes = $false
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        candidate_found = $true
        selected_lane = $SimulatedLane
        selector_disposition = "candidate_selected_simulated"
        next_worker = $nextWorker
        simulated_source_rows = $SimulatedSourceRows
        simulated_planned_rows = $SimulatedPlannedRows
        real_execution_plan_mutated = $false
        real_readiness_mutated = $false
        synthetic_plan_csv = $syntheticPlanCsv
        selection_csv = $selectionCsv
        selection_json = $selectionJson
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue "pass" -Payload $summary
    Emit-LocalSignal -SignalName $CandidateLaneSignal -SignalValue $SimulatedLane -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $CandidateDispositionSignal -SignalValue "candidate_selected_simulated" -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $NextWorkerSignal -SignalValue $nextWorker -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status "pass" -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: provider snapshot import candidate simulation completed. status=pass selected_lane=$SimulatedLane next_worker=$nextWorker simulation_only=True db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: synthetic_plan_csv=$syntheticPlanCsv selection_csv=$selectionCsv selection_json=$selectionJson summary_json=$summaryJson"
        Import-Csv $selectionCsv | Format-List
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

    Write-Error "FAILED: provider snapshot import candidate simulation failed. $message run_id=$RunId"
    exit 1
}
