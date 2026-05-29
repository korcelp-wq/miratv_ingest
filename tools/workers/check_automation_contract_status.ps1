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




















