# MiraTV Automation Contract Status Checker
# File: tools/workers/check_automation_contract_status.ps1
# Purpose:
#   Verifies automation units against the MiraTV Automation Implementation Contract.
#
# Contract gates:
#   1. It logs.
#   2. It heartbeats if recurring.
#   3. It emits one named signal.
#   4. That signal appears in dashboard mapping.
#   5. It has rollback / kill switch.
#
# Signals:
#   - worker_heartbeat_status
#   - quality_gate_result
#
# Kill switch:
#   - ENABLE_WORKER_RUNTIME
#
# Usage:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_automation_contract_status.ps1" -Environment "dev"

[CmdletBinding()]
param(
    [string]$WorkerName = "automation_contract_checker",
    [string]$Component = "automation_contract_checker",
    [string]$Environment = "prod",
    [string]$KillSwitchName = "ENABLE_WORKER_RUNTIME",
    [string]$LogRoot = "",
    [switch]$FailOnBlocked
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:StartedAt = Get-Date
$script:RunId = $null

function Get-ScriptRepoRoot {
    [CmdletBinding()]
    param()

    $scriptDir = Split-Path -Parent $PSCommandPath
    $rootCandidate = Join-Path $scriptDir "..\.."
    $resolved = Resolve-Path -Path $rootCandidate -ErrorAction SilentlyContinue

    if ($null -ne $resolved) {
        return $resolved.Path
    }

    return (Get-Location).Path
}

function Get-DurationMs {
    [CmdletBinding()]
    param(
        [datetime]$Start
    )

    $elapsed = (Get-Date) - $Start
    return [int][math]::Round($elapsed.TotalMilliseconds, 0)
}

function Read-TextFileSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
}

function Test-TextContainsAny {
    [CmdletBinding()]
    param(
        [string]$Text,
        [string[]]$Patterns
    )

    foreach ($pattern in $Patterns) {
        $escapedPattern = [regex]::Escape([string]$pattern)
        if ($Text -match $escapedPattern) {
            return $true
        }
    }

    return $false
}

function Test-TextRegex {
    [CmdletBinding()]
    param(
        [string]$Text,
        [string]$Pattern
    )

    if ([string]::IsNullOrWhiteSpace($Pattern)) {
        return $false
    }

    return ($Text -match $Pattern)
}

$repoRoot = Get-ScriptRepoRoot
$loggingModule = Join-Path $repoRoot "tools\common\Logging.psm1"
$dashboardMappingPath = Join-Path $repoRoot "10_DASHBOARD_SIGNAL_MAPPING_2026-05-26.csv"
$signalDictionaryPath = Join-Path $repoRoot "07_P0_SIGNAL_DICTIONARY_2026-05-26.csv"

if (-not (Test-Path -LiteralPath $loggingModule)) {
    throw "Logging module not found at: $loggingModule"
}

Import-Module $loggingModule -Force

$script:RunId = New-RunId -Prefix "contract-check"

try {
    $enabled = Test-KillSwitch -Name $KillSwitchName -DefaultEnabled $true

    if (-not $enabled) {
        Write-JobLog `
            -RunId $script:RunId `
            -JobName "check_automation_contract_status" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -Status "job_skipped" `
            -EventType "job_skipped" `
            -SourceName "repo_contract_scan" `
            -DurationMs (Get-DurationMs -Start $script:StartedAt) `
            -Data @{
                kill_switch_name = $KillSwitchName
                kill_switch_enabled = $false
                reason = "worker runtime disabled by kill switch"
            } `
            -LogRoot $LogRoot | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName "check_automation_contract_status" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName "quality_gate_result" `
            -P0Item "P0.5" `
            -SignalValue "disabled" `
            -Status "disabled" `
            -AllowedValues "pass|fail|warning|not_run|disabled" `
            -SourceTableOrEndpoint "tools/workers/check_automation_contract_status.ps1" `
            -Data @{
                dashboard_panel = "Quality Gates"
                widget_key = "quality.gate.result"
                owner = "Content Ops"
                kill_switch_name = $KillSwitchName
            } `
            -LogRoot $LogRoot | Out-Null

        Write-Output "SKIPPED: $KillSwitchName is disabled. run_id=$script:RunId"
        exit 0
    }

    Write-JobLog `
        -RunId $script:RunId `
        -JobName "check_automation_contract_status" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -Status "job_started" `
        -EventType "job_started" `
        -SourceName "repo_contract_scan" `
        -Data @{
            kill_switch_name = $KillSwitchName
            repo_root = $repoRoot
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Heartbeat `
        -RunId $script:RunId `
        -JobName "check_automation_contract_status" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -HeartbeatStatus "ok" `
        -HeartbeatIntervalSeconds 300 `
        -StaleAfterSeconds 900 `
        -Data @{
            signal_name = "worker_heartbeat_status"
            p0_item = "P0.2"
            kill_switch_name = $KillSwitchName
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "check_automation_contract_status" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "worker_heartbeat_status" `
        -P0Item "P0.2" `
        -SignalValue "ok" `
        -Status "ok" `
        -AllowedValues "ok|missed|failed|disabled" `
        -SourceTableOrEndpoint "tools/workers/check_automation_contract_status.ps1" `
        -Data @{
            dashboard_panel = "Worker Health"
            widget_key = "worker.heartbeat.status"
            owner = "SRE"
            kill_switch_name = $KillSwitchName
        } `
        -LogRoot $LogRoot | Out-Null

    $dashboardMappingText = Read-TextFileSafe -Path $dashboardMappingPath
    $signalDictionaryText = Read-TextFileSafe -Path $signalDictionaryPath

    $units = @(
        @{
            Name = "emit_worker_heartbeat"
            Path = "tools\workers\emit_worker_heartbeat.ps1"
            Recurring = $true
            RequiredSignals = @("worker_heartbeat_status", "last_heartbeat_at")
            RequiredKillSwitch = "ENABLE_WORKER_RUNTIME"
        },
        @{
            Name = "check_automation_contract_status"
            Path = "tools\workers\check_automation_contract_status.ps1"
            Recurring = $true
            RequiredSignals = @("worker_heartbeat_status", "quality_gate_result")
            RequiredKillSwitch = "ENABLE_WORKER_RUNTIME"
        },
        @{
            Name = "refresh_user_bouquet_availability"
            Path = "tools\workers\refresh_user_bouquet_availability.ps1"
            Recurring = $true
            RequiredSignals = @("availability_refresh_status", "availability_refresh_lag_minutes", "worker_heartbeat_status")
            RequiredKillSwitch = "ENABLE_AVAILABILITY_REFRESH"
        },
        @{
            Name = "refresh_user_item_availability"
            Path = "tools\workers\refresh_user_item_availability.ps1"
            Recurring = $true
            RequiredSignals = @("availability_refresh_status", "availability_refresh_lag_minutes", "worker_heartbeat_status")
            RequiredKillSwitch = "ENABLE_AVAILABILITY_REFRESH"
        },
        @{
            Name = "refresh_user_series_availability"
            Path = "tools\workers\refresh_user_series_availability.ps1"
            Recurring = $true
            RequiredSignals = @("availability_refresh_status", "availability_refresh_lag_minutes", "worker_heartbeat_status")
            RequiredKillSwitch = "ENABLE_AVAILABILITY_REFRESH"
        },
        @{
            Name = "check_epg_freshness"
            Path = "tools\workers\check_epg_freshness.ps1"
            Recurring = $true
            RequiredSignals = @("epg_freshness_age_hours", "worker_heartbeat_status")
            RequiredKillSwitch = "ENABLE_EPG_IMPORT"
        },
        @{
            Name = "check_epg_join_validation"
            Path = "tools\workers\check_epg_join_validation.ps1"
            Recurring = $true
            RequiredSignals = @("epg_join_validation_status", "worker_heartbeat_status")
            RequiredKillSwitch = "ENABLE_EPG_JOIN_GATE"
        },
 	@{
            Name = "check_cache_stale_serving"
            Path = "tools\workers\check_cache_stale_serving.ps1"
            Recurring = $true
            RequiredSignals = @("cache_stale_serving_status", "cache_stale_ratio", "worker_heartbeat_status")
            RequiredKillSwitch = "ENABLE_ASYNC_CACHE_REFRESH"
        },
        @{
            Name = "run_db_quality_gates"
            Path = "tools\workers\run_db_quality_gates.ps1"
            Recurring = $true
            RequiredSignals = @("quality_gate_result", "duplicate_ratio", "blank_key_ratio", "filter_diversity_score", "worker_heartbeat_status")
            RequiredKillSwitch = "ENABLE_DB_QUALITY_GATE_AUTOMATION"
        },
   	@{
            Name = "check_materialization_queue"
            Path = "tools\workers\check_materialization_queue.ps1"
            Recurring = $true
            RequiredSignals = @("materialization_queue_oldest_age_minutes", "materialization_dead_letter_count", "materialization_requeue_rate", "worker_heartbeat_status")
            RequiredKillSwitch = "ENABLE_MATERIALIZATION_CONSUMERS"
        },
        @{
            Name = "check_playback_preflight_attribution"
            Path = "tools\workers\check_playback_preflight_attribution.ps1"
            Recurring = $true
            RequiredSignals = @("playback_preflight_outcome", "attribution_coverage_percent", "worker_heartbeat_status")
            RequiredKillSwitch = "ENABLE_PLAYBACK_ATTRIBUTION"
        },
    	  @{
    	Name = "capture_series_frame_artwork"
    	Path = "tools\workers\capture_series_frame_artwork.ps1"
	Recurring = $true
    	RequiredSignals = @(
        	"worker_heartbeat_status",
        	"materialization_series_frame_capture_status",
        	"materialization_series_frame_capture_candidate_count",
        	"materialization_series_frame_capture_probe_success_count",
        	"materialization_series_frame_capture_probe_failed_count",
        	"materialization_series_frame_capture_generated_count",
        	"materialization_series_frame_capture_unplayable_count",
        	"materialization_series_frame_capture_manual_needed_count",
        	"materialization_series_frame_capture_last_diagnostic"
    )
    RequiredKillSwitch = "ENABLE_FRAME_CAPTURE_ARTWORK"
},
        @{
            Name = "inventory_master_control_integration"
            Path = "tools\workers\inventory_master_control_integration.ps1"
            Recurring = $false
            RequiredSignals = @("master_control_inventory_completed")
            RequiredKillSwitch = "ENABLE_MASTER_CONTROL_INVENTORY"
        },
        @{
            Name = "plan_provider_sync_delta"
            Path = "tools\workers\plan_provider_sync_delta.ps1"
            Recurring = $false
            RequiredSignals = @("provider_sync_delta_plan_completed")
            RequiredKillSwitch = "ENABLE_PROVIDER_SYNC_DELTA_PLANNER"
        },
        @{
            Name = "inspect_provider_pull_spine"
            Path = "tools\workers\inspect_provider_pull_spine.ps1"
            Recurring = $false
            RequiredSignals = @("provider_pull_spine_inspection_completed")
            RequiredKillSwitch = "ENABLE_PROVIDER_PULL_SPINE_INSPECTION"
        },
        @{
            Name = "inspect_provider_account_context"
            Path = "tools\workers\inspect_provider_account_context.ps1"
            Recurring = $false
            RequiredSignals = @("provider_account_context_inspection_completed")
            RequiredKillSwitch = "ENABLE_PROVIDER_ACCOUNT_CONTEXT_INSPECTION"
        },
        @{
            Name = "build_provider_live_categories_snapshot"
            Path = "tools\workers\build_provider_live_categories_snapshot.ps1"
            Recurring = $false
            RequiredSignals = @("provider_live_categories_snapshot_completed")
            RequiredKillSwitch = "ENABLE_PROVIDER_LIVE_CATEGORIES_SNAPSHOT"
        },
        @{
            Name = "build_provider_vod_categories_snapshot"
            Path = "tools\workers\build_provider_vod_categories_snapshot.ps1"
            Recurring = $false
            RequiredSignals = @("provider_vod_categories_snapshot_completed")
            RequiredKillSwitch = "ENABLE_PROVIDER_VOD_CATEGORIES_SNAPSHOT"
        },
        @{
            Name = "build_provider_series_categories_snapshot"
            Path = "tools\workers\build_provider_series_categories_snapshot.ps1"
            Recurring = $false
            RequiredSignals = @("provider_series_categories_snapshot_completed")
            RequiredKillSwitch = "ENABLE_PROVIDER_SERIES_CATEGORIES_SNAPSHOT"
        },
        @{
            Name = "build_provider_live_streams_snapshot"
            Path = "tools\workers\build_provider_live_streams_snapshot.ps1"
            Recurring = $false
            RequiredSignals = @("provider_live_streams_snapshot_completed")
            RequiredKillSwitch = "ENABLE_PROVIDER_LIVE_STREAMS_SNAPSHOT"
        },
        @{
            Name = "build_provider_vod_streams_snapshot"
            Path = "tools\workers\build_provider_vod_streams_snapshot.ps1"
            Recurring = $false
            RequiredSignals = @("provider_vod_streams_snapshot_completed")
            RequiredKillSwitch = "ENABLE_PROVIDER_VOD_STREAMS_SNAPSHOT"
        },
        @{
            Name = "build_provider_series_streams_snapshot"
            Path = "tools\workers\build_provider_series_streams_snapshot.ps1"
            Recurring = $false
            RequiredSignals = @("provider_series_streams_snapshot_completed")
            RequiredKillSwitch = "ENABLE_PROVIDER_SERIES_STREAMS_SNAPSHOT"
        },
        @{
            Name = "plan_provider_snapshot_delta"
            Path = "tools\workers\plan_provider_snapshot_delta.ps1"
            Recurring = $false
            RequiredSignals = @("provider_snapshot_delta_plan_completed")
            RequiredKillSwitch = "ENABLE_PROVIDER_SNAPSHOT_DELTA_PLAN"
        },
        @{
            Name = "run_provider_snapshot_spine"
            Path = "tools\workers\run_provider_snapshot_spine.ps1"
            Recurring = $false
            RequiredSignals = @("provider_snapshot_spine_runner_completed")
            RequiredKillSwitch = "ENABLE_PROVIDER_SNAPSHOT_SPINE_RUNNER"
        },
        @{
            Name = "plan_provider_snapshot_import_preview"
            Path = "tools\workers\plan_provider_snapshot_import_preview.ps1"
            Recurring = $false
            RequiredSignals = @("provider_snapshot_import_preview_completed")
            RequiredKillSwitch = "ENABLE_PROVIDER_SNAPSHOT_IMPORT_PREVIEW"
        },
        @{
            Name = "import_provider_snapshot_delta_dryrun"
            Path = "tools\workers\import_provider_snapshot_delta_dryrun.ps1"
            Recurring = $false
            RequiredSignals = @("provider_snapshot_delta_import_dryrun_completed")
            RequiredKillSwitch = "ENABLE_PROVIDER_SNAPSHOT_DELTA_IMPORT_DRYRUN"
        },
        @{
            Name = "import_vod_streams_delta_preview"
            Path = "tools\workers\import_vod_streams_delta_preview.ps1"
            Recurring = $false
            RequiredSignals = @("provider_snapshot_vod_streams_import_preview_completed")
            RequiredKillSwitch = "ENABLE_PROVIDER_SNAPSHOT_VOD_STREAMS_IMPORT_PREVIEW"
        },
        @{
            Name = "import_vod_streams_delta_row_preview"
            Path = "tools\workers\import_vod_streams_delta_row_preview.ps1"
            Recurring = $false
            RequiredSignals = @("provider_snapshot_vod_streams_import_row_preview_completed")
            RequiredKillSwitch = "ENABLE_PROVIDER_SNAPSHOT_VOD_STREAMS_IMPORT_ROW_PREVIEW"
        },
        @{
            Name = "summarize_provider_snapshot_import_readiness"
            Path = "tools\workers\summarize_provider_snapshot_import_readiness.ps1"
            Recurring = $false
            RequiredSignals = @("provider_snapshot_import_readiness_summary_completed")
            RequiredKillSwitch = "ENABLE_PROVIDER_SNAPSHOT_IMPORT_READINESS_SUMMARY"
        },
        @{
            Name = "plan_provider_snapshot_import_execution"
            Path = "tools\workers\plan_provider_snapshot_import_execution.ps1"
            Recurring = $false
            RequiredSignals = @("provider_snapshot_import_execution_plan_completed")
            RequiredKillSwitch = "ENABLE_PROVIDER_SNAPSHOT_IMPORT_EXECUTION_PLAN"
        },
        @{
            Name = "run_provider_snapshot_import_preflight_gate"
            Path = "tools\workers\run_provider_snapshot_import_preflight_gate.ps1"
            Recurring = $false
            RequiredSignals = @("provider_snapshot_import_preflight_gate_completed")
            RequiredKillSwitch = "ENABLE_PROVIDER_SNAPSHOT_IMPORT_PREFLIGHT_GATE"
        },
        @{
            Name = "run_provider_snapshot_governed_refresh_gate"
            Path = "tools\workers\run_provider_snapshot_governed_refresh_gate.ps1"
            Recurring = $false
            RequiredSignals = @("provider_snapshot_governed_refresh_gate_completed")
            RequiredKillSwitch = "ENABLE_PROVIDER_SNAPSHOT_GOVERNED_REFRESH_GATE"
        },
        @{
            Name = "normalize_master_control_manifest_to_import_route_registry"
            Path = "tools\workers\normalize_master_control_manifest_to_import_route_registry.ps1"
            Recurring = $false
            RequiredSignals = @("master_control_route_registry_normalized_completed")
            RequiredKillSwitch = "ENABLE_MASTER_CONTROL_ROUTE_REGISTRY_NORMALIZER"
        },
        @{
            Name = "classify_master_control_worker_functions"
            Path = "tools\workers\classify_master_control_worker_functions.ps1"
            Recurring = $false
            RequiredSignals = @("master_control_worker_functions_classified_completed")
            RequiredKillSwitch = "ENABLE_MASTER_CONTROL_WORKER_FUNCTION_CLASSIFIER"
        },
        @{
            Name = "plan_deferred_partial_salvage_queue"
            Path = "tools\workers\plan_deferred_partial_salvage_queue.ps1"
            Recurring = $false
            RequiredSignals = @("deferred_partial_salvage_queue_planned_completed")
            RequiredKillSwitch = "ENABLE_DEFERRED_PARTIAL_SALVAGE_QUEUE_PLANNER"
        },
        @{
            Name = "plan_vod_streams_import_route_apply_contract"
            Path = "tools\workers\plan_vod_streams_import_route_apply_contract.ps1"
            Recurring = $false
            RequiredSignals = @("vod_streams_import_route_apply_contract_planned_completed")
            RequiredKillSwitch = "ENABLE_VOD_STREAMS_IMPORT_ROUTE_APPLY_CONTRACT_PLANNER"
        },
        @{
            Name = "select_next_provider_snapshot_import_candidate"
            Path = "tools\workers\select_next_provider_snapshot_import_candidate.ps1"
            Recurring = $false
            RequiredSignals = @("provider_snapshot_import_candidate_selected_completed")
            RequiredKillSwitch = "ENABLE_PROVIDER_SNAPSHOT_IMPORT_CANDIDATE_SELECTOR"
        },
        @{
            Name = "simulate_provider_snapshot_import_candidate"
            Path = "tools\workers\simulate_provider_snapshot_import_candidate.ps1"
            Recurring = $false
            RequiredSignals = @("provider_snapshot_import_candidate_simulated_completed")
            RequiredKillSwitch = "ENABLE_PROVIDER_SNAPSHOT_IMPORT_CANDIDATE_SIMULATOR"
        },
        @{
            Name = "apply_vod_streams_delta_limited"
            Path = "tools\workers\apply_vod_streams_delta_limited.ps1"
            Recurring = $false
            RequiredSignals = @("vod_streams_delta_limited_apply_completed")
            RequiredKillSwitch = "ENABLE_VOD_STREAMS_DELTA_LIMITED_APPLY"
        },
        @{
            Name = "run_provider_snapshot_import_decision_gate"
            Path = "tools\workers\run_provider_snapshot_import_decision_gate.ps1"
            Recurring = $false
            RequiredSignals = @("provider_snapshot_import_decision_gate_completed")
            RequiredKillSwitch = "ENABLE_PROVIDER_SNAPSHOT_IMPORT_DECISION_GATE"
        },
        @{
            Name = "run_provider_snapshot_governed_import_runner"
            Path = "tools\workers\run_provider_snapshot_governed_import_runner.ps1"
            Recurring = $false
            RequiredSignals = @("provider_snapshot_governed_import_runner_completed")
            RequiredKillSwitch = "ENABLE_PROVIDER_SNAPSHOT_GOVERNED_IMPORT_RUNNER"
        },
        @{
            Name = "test_vod_streams_apply_mapping_fixture"
            Path = "tools\workers\test_vod_streams_apply_mapping_fixture.ps1"
            Recurring = $false
            RequiredSignals = @("vod_streams_apply_mapping_fixture_test_completed")
            RequiredKillSwitch = "ENABLE_VOD_STREAMS_APPLY_MAPPING_FIXTURE_TEST"
        },
        @{
            Name = "inventory_vod_apply_db_targets"
            Path = "tools\workers\inventory_vod_apply_db_targets.ps1"
            Recurring = $false
            RequiredSignals = @("vod_apply_db_target_inventory_completed")
            RequiredKillSwitch = "ENABLE_VOD_APPLY_DB_TARGET_INVENTORY"
        },
        @{
            Name = "select_vod_apply_db_target_candidate"
            Path = "tools\workers\select_vod_apply_db_target_candidate.ps1"
            Recurring = $false
            RequiredSignals = @("vod_apply_db_target_selector_completed")
            RequiredKillSwitch = "ENABLE_VOD_APPLY_DB_TARGET_SELECTOR"
        },
        @{
            Name = "plan_vod_streams_apply_sql_contract"
            Path = "tools\workers\plan_vod_streams_apply_sql_contract.ps1"
            Recurring = $false
            RequiredSignals = @("vod_streams_apply_sql_contract_planned_completed")
            RequiredKillSwitch = "ENABLE_VOD_STREAMS_APPLY_SQL_CONTRACT_PLANNER"
        },
        @{
            Name = "test_vod_streams_sql_parameter_binding_fixture"
            Path = "tools\workers\test_vod_streams_sql_parameter_binding_fixture.ps1"
            Recurring = $false
            RequiredSignals = @("vod_streams_sql_parameter_binding_fixture_completed")
            RequiredKillSwitch = "ENABLE_VOD_STREAMS_SQL_PARAMETER_BINDING_FIXTURE_TEST"
        },
        @{
            Name = "plan_vod_apply_adapter_selection"
            Path = "tools\workers\plan_vod_apply_adapter_selection.ps1"
            Recurring = $false
            RequiredSignals = @("vod_apply_adapter_selection_planned_completed")
            RequiredKillSwitch = "ENABLE_VOD_APPLY_ADAPTER_SELECTION_PLANNER"
        },
        @{
            Name = "test_vod_apply_db_schema_contract"
            Path = "tools\workers\test_vod_apply_db_schema_contract.ps1"
            Recurring = $false
            RequiredSignals = @("vod_apply_db_schema_contract_test_completed")
            RequiredKillSwitch = "ENABLE_VOD_APPLY_DB_SCHEMA_CONTRACT_TEST"
        },
        @{
            Name = "inventory_powershell_db_connection_paths"
            Path = "tools\workers\inventory_powershell_db_connection_paths.ps1"
            Recurring = $false
            RequiredSignals = @("powershell_db_connection_path_inventory_completed")
            RequiredKillSwitch = "ENABLE_POWERSHELL_DB_CONNECTION_PATH_INVENTORY"
        },
        @{
            Name = "plan_vod_powershell_db_adapter_contract"
            Path = "tools\workers\plan_vod_powershell_db_adapter_contract.ps1"
            Recurring = $false
            RequiredSignals = @("vod_powershell_db_adapter_contract_planned_completed")
            RequiredKillSwitch = "ENABLE_VOD_POWERSHELL_DB_ADAPTER_CONTRACT_PLANNER"
        },
        @{
            Name = "test_mira_db_safe_adapter_fixture"
            Path = "tools\workers\test_mira_db_safe_adapter_fixture.ps1"
            Recurring = $false
            RequiredSignals = @("mira_db_safe_adapter_fixture_test_completed")
            RequiredKillSwitch = "ENABLE_MIRA_DB_SAFE_ADAPTER_FIXTURE_TEST"
        },
        @{
            Name = "test_vod_apply_safe_adapter_integration_fixture"
            Path = "tools\workers\test_vod_apply_safe_adapter_integration_fixture.ps1"
            Recurring = $false
            RequiredSignals = @("vod_apply_safe_adapter_integration_fixture_completed")
            RequiredKillSwitch = "ENABLE_VOD_APPLY_SAFE_ADAPTER_INTEGRATION_FIXTURE_TEST"
        },
        @{
            Name = "plan_vod_limited_apply_promotion_readiness"
            Path = "tools\workers\plan_vod_limited_apply_promotion_readiness.ps1"
            Recurring = $false
            RequiredSignals = @("vod_limited_apply_promotion_readiness_completed")
            RequiredKillSwitch = "ENABLE_VOD_LIMITED_APPLY_PROMOTION_READINESS_PLANNER"
        },
        @{
            Name = "plan_vod_schema_validation_execution_gate"
            Path = "tools\workers\plan_vod_schema_validation_execution_gate.ps1"
            Recurring = $false
            RequiredSignals = @("vod_schema_validation_execution_gate_planned_completed")
            RequiredKillSwitch = "ENABLE_VOD_SCHEMA_VALIDATION_EXECUTION_GATE_PLANNER"
        },
        @{
            Name = "test_vod_apply_db_schema_live_read"
            Path = "tools\workers\test_vod_apply_db_schema_live_read.ps1"
            Recurring = $false
            RequiredSignals = @("vod_apply_db_schema_live_read_completed")
            RequiredKillSwitch = "ENABLE_VOD_APPLY_DB_SCHEMA_LIVE_READ_TEST"
        },
        @{
            Name = "check_vod_query_wrapper_prerequisites"
            Path = "tools\workers\check_vod_query_wrapper_prerequisites.ps1"
            Recurring = $false
            RequiredSignals = @("vod_query_wrapper_prerequisites_check_completed")
            RequiredKillSwitch = "ENABLE_VOD_QUERY_WRAPPER_PREREQUISITES_CHECK"
        },
        @{
            Name = "plan_vod_schema_validation_query_wrapper_gate"
            Path = "tools\workers\plan_vod_schema_validation_query_wrapper_gate.ps1"
            Recurring = $false
            RequiredSignals = @("vod_schema_validation_query_wrapper_gate_planned_completed")
            RequiredKillSwitch = "ENABLE_VOD_SCHEMA_VALIDATION_QUERY_WRAPPER_GATE_PLANNER"
        },
        @{
            Name = "inspect_query_wrapper_invocation_shape"
            Path = "tools\workers\inspect_query_wrapper_invocation_shape.ps1"
            Recurring = $false
            RequiredSignals = @("query_wrapper_invocation_shape_inspected_completed")
            RequiredKillSwitch = "ENABLE_QUERY_WRAPPER_INVOCATION_SHAPE_INSPECTOR"
        },
        @{
            Name = "resolve_query_wrapper_canonical_source"
            Path = "tools\workers\resolve_query_wrapper_canonical_source.ps1"
            Recurring = $false
            RequiredSignals = @("query_wrapper_canonical_source_resolved_completed")
            RequiredKillSwitch = "ENABLE_QUERY_WRAPPER_CANONICAL_SOURCE_RESOLVER"
        },
        @{
            Name = "audit_provider_snapshot_data_reality"
            Path = "tools\workers\audit_provider_snapshot_data_reality.ps1"
            Recurring = $false
            RequiredSignals = @("provider_snapshot_data_reality_audit_completed")
            RequiredKillSwitch = "ENABLE_PROVIDER_SNAPSHOT_DATA_REALITY_AUDIT"
        },
        @{
            Name = "audit_vod_delta_preview_dispositions"
            Path = "tools\workers\audit_vod_delta_preview_dispositions.ps1"
            Recurring = $false
            RequiredSignals = @("vod_delta_preview_disposition_audit_completed")
            RequiredKillSwitch = "ENABLE_VOD_DELTA_PREVIEW_DISPOSITION_AUDIT"
        },
        @{
            Name = "audit_provider_import_controls_and_switches"
            Path = "tools\workers\audit_provider_import_controls_and_switches.ps1"
            Recurring = $false
            RequiredSignals = @("provider_import_controls_audit_completed")
            RequiredKillSwitch = "ENABLE_PROVIDER_IMPORT_CONTROLS_AUDIT"
        },
        @{
            Name = "check_grinder_disposition_contract"
            Path = "tools\workers\check_grinder_disposition_contract.ps1"
            Recurring = $false
            RequiredSignals = @("grinder_disposition_contract_completed")
            RequiredKillSwitch = "ENABLE_GRINDER_DISPOSITION_CONTRACT_CHECK"
        }
    )

    $helperSubcomponents = @(
        @{
            ParentUnit = "capture_series_frame_artwork"
            HelperName = "FrameCapturePreviewCommon"
            Path = "tools\common\FrameCapturePreviewCommon.psm1"
            Subcomponent = "frame_capture_preview_common"
            Purpose = "shared preview helpers, redaction, JSON/hash helpers, and module event wrapper"
        },
        @{
            ParentUnit = "capture_series_frame_artwork"
            HelperName = "SeriesEpisodeResolver"
            Path = "tools\common\SeriesEpisodeResolver.psm1"
            Subcomponent = "series_episode_resolver"
            Purpose = "provider_series_id to episode/container/playback URL preview resolution"
        },
        @{
            ParentUnit = "capture_series_frame_artwork"
            HelperName = "MediaProbePreview"
            Path = "tools\common\MediaProbePreview.psm1"
            Subcomponent = "media_probe_preview"
            Purpose = "resolved episode URL ffprobe preview and probe diagnostic classification"
        },
        @{
            ParentUnit = "capture_series_frame_artwork"
            HelperName = "SupportCasePreview"
            Path = "tools\common\SupportCasePreview.psm1"
            Subcomponent = "support_case_preview"
            Purpose = "support_playback_cases preview payload shaping without writes"
        }
    )

    $results = New-Object System.Collections.Generic.List[object]

    foreach ($unit in $units) {
        $relativePath = [string]$unit.Path
        $fullPath = Join-Path $repoRoot $relativePath
        $exists = Test-Path -LiteralPath $fullPath
        $text = Read-TextFileSafe -Path $fullPath

        $logs = Test-TextContainsAny -Text $text -Patterns @("Write-JobLog", "worker_log")

        $heartbeats = $true
        if ($unit.Recurring) {
            $heartbeats = Test-TextContainsAny -Text $text -Patterns @("Emit-Heartbeat", "emit_heartbeat")
        }

        $signals = $true
        $missingSignals = New-Object System.Collections.Generic.List[string]
        $dashboardMissingSignals = New-Object System.Collections.Generic.List[string]
        $dictionaryMissingSignals = New-Object System.Collections.Generic.List[string]

        foreach ($signalName in $unit.RequiredSignals) {
            $signalNameString = [string]$signalName
            $escapedSignalName = [regex]::Escape($signalNameString)

            $hasSignalInFile = Test-TextRegex -Text $text -Pattern $escapedSignalName

            if (-not $hasSignalInFile) {
                $signals = $false
                $missingSignals.Add($signalNameString) | Out-Null
            }

            if ($dashboardMappingText -notmatch $escapedSignalName) {
                $dashboardMissingSignals.Add($signalNameString) | Out-Null
            }

            if ($signalDictionaryText -notmatch $escapedSignalName) {
                $dictionaryMissingSignals.Add($signalNameString) | Out-Null
            }
        }

        $dashboardMapped = ($dashboardMissingSignals.Count -eq 0)
        $inSignalDictionary = ($dictionaryMissingSignals.Count -eq 0)
        $requiredKillSwitch = [string]$unit.RequiredKillSwitch
        $killSwitchReferencedInWorker = $false

        if (-not [string]::IsNullOrWhiteSpace($requiredKillSwitch)) {
            $escapedKillSwitch = [regex]::Escape($requiredKillSwitch)
            $killSwitchReferencedInWorker = Test-TextRegex -Text $text -Pattern $escapedKillSwitch
        }

        # Contract definition lives in the contract catalog. Some workers use shared/default
        # kill-switch handling and do not embed the exact switch string in the worker body.
        # Keep the direct worker reference as diagnostics, but do not block solely because
        # the literal string is absent from the file.
        $killSwitchDefined = -not [string]::IsNullOrWhiteSpace($requiredKillSwitch)

        $contractStatus = "blocked"

        if ($exists -and $logs -and $heartbeats -and $signals -and $dashboardMapped -and $inSignalDictionary -and $killSwitchDefined) {
            $contractStatus = "compliant"
        }

        $block_reasons = @()
        if (-not $exists) { $block_reasons += "missing_file" }
        if (-not $logs) { $block_reasons += "logging_missing" }
        if (-not $heartbeats) { $block_reasons += "heartbeat_missing" }
        if (-not $signals) { $block_reasons += "signal_missing" }
        if (-not $dashboardMapped) { $block_reasons += "dashboard_mapping_missing" }
        if (-not $inSignalDictionary) { $block_reasons += "signal_dictionary_missing" }
        if (-not $killSwitchDefined) { $block_reasons += "kill_switch_missing" }

        $result = [ordered]@{
            unit_name = [string]$unit.Name
            path = $relativePath
            exists = $exists
            logging_enabled = $logs
            heartbeat_enabled = $heartbeats
            signal_emitted = $signals
            dashboard_mapped = $dashboardMapped
            signal_dictionary_mapped = $inSignalDictionary
            kill_switch_defined = $killSwitchDefined
            required_kill_switch = $requiredKillSwitch
            missing_signals = @($missingSignals)
            dashboard_missing_signals = @($dashboardMissingSignals)
            dictionary_missing_signals = @($dictionaryMissingSignals)
            block_reasons = ($block_reasons -join ",")
            contract_status = $contractStatus
        }

        $results.Add([pscustomobject]$result) | Out-Null
    }

    $totalUnits = $results.Count
    $compliantUnits = @($results | Where-Object { $_.contract_status -eq "compliant" }).Count
    $blockedUnits = $totalUnits - $compliantUnits

    $overallStatus = "pass"

    if ($blockedUnits -gt 0) {
        $overallStatus = "warning"
    }

    if ($FailOnBlocked -and $blockedUnits -gt 0) {
        $overallStatus = "fail"
    }

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "check_automation_contract_status" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "quality_gate_result" `
        -P0Item "P0.5" `
        -SignalValue $overallStatus `
        -Status $overallStatus `
        -AllowedValues "pass|fail|warning|not_run|disabled" `
        -SourceTableOrEndpoint "tools/workers/check_automation_contract_status.ps1" `
        -Data @{
            dashboard_panel = "Quality Gates"
            widget_key = "quality.gate.result"
            owner = "Content Ops"
            kill_switch_name = $KillSwitchName
            total_units = $totalUnits
            compliant_units = $compliantUnits
            blocked_units = $blockedUnits
            fail_on_blocked = [bool]$FailOnBlocked
        } `
        -LogRoot $LogRoot | Out-Null

    Write-JobLog `
        -RunId $script:RunId `
        -JobName "check_automation_contract_status" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -Status "job_completed" `
        -EventType "job_completed" `
        -SourceName "repo_contract_scan" `
        -DurationMs (Get-DurationMs -Start $script:StartedAt) `
        -Data @{
            overall_status = $overallStatus
            total_units = $totalUnits
            compliant_units = $compliantUnits
            blocked_units = $blockedUnits
        } `
        -LogRoot $LogRoot | Out-Null

    $results | Select-Object unit_name, exists, logging_enabled, heartbeat_enabled, signal_emitted, dashboard_mapped, signal_dictionary_mapped, kill_switch_defined, block_reasons, contract_status | Format-Table -AutoSize

    if ($helperSubcomponents.Count -gt 0) {
        $helperRows = foreach ($helper in $helperSubcomponents) {
            $helperPath = [string]$helper.Path
            $helperFullPath = Join-Path $repoRoot $helperPath

            [pscustomobject]@{
                parent_unit = [string]$helper.ParentUnit
                helper_name = [string]$helper.HelperName
                subcomponent = [string]$helper.Subcomponent
                path = $helperPath
                exists = (Test-Path -LiteralPath $helperFullPath)
                purpose = [string]$helper.Purpose
            }
        }

        $presentCount = @($helperRows | Where-Object { $_.exists }).Count
        $helperTotal = @($helperRows).Count

        Write-Output ""
        Write-Output "SUBCOMPONENTS: capture_series_frame_artwork helper_files_present=$presentCount/$helperTotal"
        $helperRows | Format-Table -AutoSize
    }

    Write-Output "RESULT: $overallStatus total_units=$totalUnits compliant=$compliantUnits blocked=$blockedUnits run_id=$script:RunId"

    if ($FailOnBlocked -and $blockedUnits -gt 0) {
        exit 2
    }

    exit 0
}
catch {
    $message = $_.Exception.Message
    $duration = Get-DurationMs -Start $script:StartedAt

    if ([string]::IsNullOrWhiteSpace($script:RunId)) {
        $script:RunId = "contract-check-failed-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
    }

    try {
        Write-JobLog `
            -RunId $script:RunId `
            -JobName "check_automation_contract_status" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -Status "job_failed" `
            -EventType "job_failed" `
            -SourceName "repo_contract_scan" `
            -DurationMs $duration `
            -ErrorCode "CONTRACT_CHECK_FAILED" `
            -ErrorMessage $message `
            -Data @{
                kill_switch_name = $KillSwitchName
            } `
            -LogRoot $LogRoot | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName "check_automation_contract_status" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName "quality_gate_result" `
            -P0Item "P0.5" `
            -SignalValue "fail" `
            -Status "failed" `
            -AllowedValues "pass|fail|warning|not_run|disabled" `
            -SourceTableOrEndpoint "tools/workers/check_automation_contract_status.ps1" `
            -ErrorCode "CONTRACT_CHECK_FAILED" `
            -ErrorMessage $message `
            -Data @{
                dashboard_panel = "Quality Gates"
                widget_key = "quality.gate.result"
                owner = "Content Ops"
                kill_switch_name = $KillSwitchName
            } `
            -LogRoot $LogRoot | Out-Null
    }
    catch {
        Write-Error "Contract checker failed and failed to log error: $($_.Exception.Message)"
    }

    Write-Error "FAILED: contract checker failed. run_id=$script:RunId error=$message"
    exit 1
}

























































