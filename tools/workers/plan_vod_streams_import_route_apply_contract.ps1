<#
.SYNOPSIS
  Plan the governed apply contract for the VOD streams import route.

.DESCRIPTION
  Read-only planner.

  This worker consumes the latest unified import route registry and finds the canonical
  provider_pull_spine VOD streams import route. It produces an apply-contract plan that
  defines what the later bounded apply worker may do.

  It does not import.
  It does not call providers.
  It does not write to the database.
  It does not invoke legacy import_vod_streams.ps1.

.CONTRACT-MARKERS
  Write-JobLog
  Emit-Signal
  Emit-Heartbeat
  Test-KillSwitch
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [string]$RouteRegistryCsv = "",
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "plan_vod_streams_import_route_apply_contract"
$Component = "vod_streams_import_route_apply_contract"
$DatabaseTarget = "none"
$SourceName = "unified_import_route_registry"
$KillSwitchName = "ENABLE_VOD_STREAMS_IMPORT_ROUTE_APPLY_CONTRACT_PLANNER"

$CompletedSignal = "vod_streams_import_route_apply_contract_planned_completed"
$RouteFoundSignal = "vod_streams_import_route_apply_contract_route_found"
$ReadinessSignal = "vod_streams_import_route_apply_contract_readiness_status"
$ApplyLimitSignal = "vod_streams_import_route_apply_contract_recommended_limit"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\vod_streams_import_route_apply_contract"
$LogRoot = Join-Path $RepoRoot "runtime\logs\vod_streams_import_route_apply_contract"

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
    param(
        [string]$Folder,
        [string]$Filter
    )

    if (-not (Test-Path -LiteralPath $Folder)) {
        return $null
    }

    return Get-ChildItem -LiteralPath $Folder -Filter $Filter -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
}

function Read-JsonFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Get-LatestRegistryCsv {
    if (-not [string]::IsNullOrWhiteSpace($RouteRegistryCsv)) {
        if (-not (Test-Path -LiteralPath $RouteRegistryCsv)) {
            throw "Route registry CSV not found: $RouteRegistryCsv"
        }
        return (Resolve-Path -LiteralPath $RouteRegistryCsv).Path
    }

    $registryRoot = Join-Path $RepoRoot "runtime\reports\unified_import_route_registry"
    $latest = Get-LatestFile -Folder $registryRoot -Filter "unified_import_route_registry_*.csv"

    if ($null -eq $latest) {
        throw "No unified import route registry CSV found. Run normalize_master_control_manifest_to_import_route_registry.ps1 first."
    }

    return $latest.FullName
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

function Get-Number {
    param([object]$Object, [string]$Name, [int]$Default = 0)

    $text = Get-Text -Object $Object -Name $Name -Default ""
    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }

    $value = 0
    if ([int]::TryParse($text, [ref]$value)) {
        return $value
    }

    return $Default
}

function Get-RecommendedApplyLimit {
    param(
        [string]$ReadinessStatus,
        [int]$PlannedImport,
        [int]$ManualReviewCount,
        [int]$SourceRows
    )

    if ($ReadinessStatus -eq "blocked") { return 0 }
    if ($ManualReviewCount -gt 0) { return 25 }
    if ($PlannedImport -le 0) { return 0 }
    if ($SourceRows -gt 10000) { return 50 }

    return 100
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

    $registryPath = Get-LatestRegistryCsv
    $registryRows = @(Import-Csv -LiteralPath $registryPath)

    $route = $registryRows |
        Where-Object {
            $_.lane -eq "provider_pull_spine" -and
            $_.media_type_guess -eq "vod" -and
            $_.operation_guess -eq "import" -and
            $_.actual_file_hint -eq "import_vod_streams.ps1"
        } |
        Select-Object -First 1

    if ($null -eq $route) {
        throw "Canonical provider_pull_spine VOD import route not found in registry: import_vod_streams.ps1"
    }

    $previewSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_streams_delta_import_preview") -Filter "vod_streams_delta_import_preview_summary_*.json"
    $rowPreviewSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_streams_delta_import_row_preview") -Filter "vod_streams_delta_import_row_preview_summary_*.json"
    $readinessSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\provider_snapshot_import_readiness") -Filter "provider_snapshot_import_readiness_summary_*.json"
    $executionPlanSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\provider_snapshot_import_execution_plan") -Filter "provider_snapshot_import_execution_plan_summary_*.json"

    $previewSummary = Read-JsonFile -Path $(if ($previewSummaryFile) { $previewSummaryFile.FullName } else { "" })
    $rowPreviewSummary = Read-JsonFile -Path $(if ($rowPreviewSummaryFile) { $rowPreviewSummaryFile.FullName } else { "" })
    $readinessSummary = Read-JsonFile -Path $(if ($readinessSummaryFile) { $readinessSummaryFile.FullName } else { "" })
    $executionPlanSummary = Read-JsonFile -Path $(if ($executionPlanSummaryFile) { $executionPlanSummaryFile.FullName } else { "" })

    $plannedImport = Get-Number -Object $previewSummary -Name "planned_import" -Default 0
    $manualReview = Get-Number -Object $previewSummary -Name "manual_review" -Default 0
    $sourceRows = Get-Number -Object $previewSummary -Name "source_rows" -Default 0

    if ($plannedImport -eq 0) {
        $plannedImport = Get-Number -Object $previewSummary -Name "would_import" -Default 0
    }

    $rowPreviewStatus = Get-Text -Object $rowPreviewSummary -Name "status" -Default "unknown"
    $rowManualReview = Get-Number -Object $rowPreviewSummary -Name "manual_review" -Default 0
    $rowSampledRows = Get-Number -Object $rowPreviewSummary -Name "sampled_rows" -Default 0

    $readinessStatus = Get-Text -Object $readinessSummary -Name "status" -Default "unknown"
    $executionStatus = Get-Text -Object $executionPlanSummary -Name "status" -Default "unknown"

    $recommendedLimit = Get-RecommendedApplyLimit -ReadinessStatus $readinessStatus -PlannedImport $plannedImport -ManualReviewCount ($manualReview + $rowManualReview) -SourceRows $sourceRows

    $applyStatus = "planned"
    $blockReasons = @()

    if ($recommendedLimit -le 0) {
        $applyStatus = "blocked"
        $blockReasons += "recommended_apply_limit_is_zero"
    }

    if ($rowPreviewStatus -eq "warning" -and $rowManualReview -gt 0) {
        $applyStatus = "caution"
        $blockReasons += "row_preview_has_manual_review"
    }

    if ($readinessStatus -eq "blocked") {
        $applyStatus = "blocked"
        $blockReasons += "readiness_summary_blocked"
    }

    if ($sourceRows -gt 0 -and $rowSampledRows -eq 0) {
        $applyStatus = "caution"
        $blockReasons += "source_rows_present_but_no_row_sample"
    }

    if (@($blockReasons).Count -eq 0) {
        $blockReasons += "none"
    }

    $contract = [ordered]@{
        contract_name = "vod_streams_import_route_apply_contract_v1"
        apply_worker_to_build = "apply_vod_streams_delta_limited.ps1"
        source_route = [ordered]@{
            lane = Get-Text -Object $route -Name "lane"
            media_type_guess = Get-Text -Object $route -Name "media_type_guess"
            operation_guess = Get-Text -Object $route -Name "operation_guess"
            route_type = Get-Text -Object $route -Name "route_type"
            actual_file_hint = Get-Text -Object $route -Name "actual_file_hint"
            current_relative_path = Get-Text -Object $route -Name "current_relative_path"
            current_absolute_path = Get-Text -Object $route -Name "current_absolute_path"
            risk_level = Get-Text -Object $route -Name "risk_level"
            recommended_next_action = Get-Text -Object $route -Name "recommended_next_action"
        }
        required_apply_controls = @(
            "default_dry_run_true",
            "explicit_apply_switch_required",
            "limit_required",
            "max_limit_guard",
            "row_disposition_required",
            "no_fail_fast_row_errors",
            "summary_json_required",
            "csv_report_required",
            "heartbeat_required",
            "signal_required",
            "kill_switch_required"
        )
        minimum_identity_fields = @(
            "provider_stream_id",
            "name_or_title",
            "category_id"
        )
        optional_fields = @(
            "container_extension",
            "stream_icon",
            "movie_image",
            "rating",
            "rating_5based",
            "added",
            "custom_sid",
            "direct_source",
            "tmdb",
            "year"
        )
        forbidden_apply_behaviors = @(
            "do_not_call_provider",
            "do_not_run_unbounded_import",
            "do_not_delete_existing_rows",
            "do_not_overwrite_enriched_tmdb_fields_with_blank_provider_values",
            "do_not_fail_whole_worker_on_single_bad_row"
        )
        recommended_apply_limit = $recommendedLimit
        apply_status = $applyStatus
        block_reasons = $blockReasons
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $contractJson = Join-Path $OutputRoot "vod_streams_import_route_apply_contract_$timestamp.json"
    $contractCsv = Join-Path $OutputRoot "vod_streams_import_route_apply_contract_$timestamp.csv"
    $summaryJson = Join-Path $OutputRoot "vod_streams_import_route_apply_contract_summary_$timestamp.json"

    $contract | ConvertTo-Json -Depth 20 | Set-Content -Path $contractJson -Encoding UTF8

    [pscustomobject][ordered]@{
        contract_name = $contract.contract_name
        apply_worker_to_build = $contract.apply_worker_to_build
        lane = $contract.source_route.lane
        media_type = $contract.source_route.media_type_guess
        route_type = $contract.source_route.route_type
        actual_file_hint = $contract.source_route.actual_file_hint
        risk_level = $contract.source_route.risk_level
        planned_import = $plannedImport
        source_rows = $sourceRows
        manual_review = $manualReview
        row_preview_status = $rowPreviewStatus
        row_manual_review = $rowManualReview
        row_sampled_rows = $rowSampledRows
        readiness_status = $readinessStatus
        execution_status = $executionStatus
        recommended_apply_limit = $recommendedLimit
        apply_status = $applyStatus
        block_reasons = ($blockReasons -join "|")
    } | Export-Csv -Path $contractCsv -NoTypeInformation

    $summary = [ordered]@{
        status = "pass"
        preview_only = $true
        db_writes = $false
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        registry_csv = $registryPath
        route_found = $true
        route_actual_file_hint = "import_vod_streams.ps1"
        preview_summary_json = $(if ($previewSummaryFile) { $previewSummaryFile.FullName } else { "" })
        row_preview_summary_json = $(if ($rowPreviewSummaryFile) { $rowPreviewSummaryFile.FullName } else { "" })
        readiness_summary_json = $(if ($readinessSummaryFile) { $readinessSummaryFile.FullName } else { "" })
        execution_plan_summary_json = $(if ($executionPlanSummaryFile) { $executionPlanSummaryFile.FullName } else { "" })
        planned_import = $plannedImport
        source_rows = $sourceRows
        manual_review = $manualReview
        row_preview_status = $rowPreviewStatus
        row_manual_review = $rowManualReview
        row_sampled_rows = $rowSampledRows
        readiness_status = $readinessStatus
        execution_status = $executionStatus
        recommended_apply_limit = $recommendedLimit
        apply_status = $applyStatus
        block_reasons = $blockReasons
        contract_json = $contractJson
        contract_csv = $contractCsv
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue "pass" -Payload $summary
    Emit-LocalSignal -SignalName $RouteFoundSignal -SignalValue "true" -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $ReadinessSignal -SignalValue $applyStatus -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $ApplyLimitSignal -SignalValue $recommendedLimit -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status "pass" -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: VOD streams import route apply contract planned. status=pass route_found=True apply_status=$applyStatus recommended_limit=$recommendedLimit db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: contract_csv=$contractCsv contract_json=$contractJson summary_json=$summaryJson"

        Import-Csv $contractCsv | Format-List
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

    Write-Error "FAILED: VOD streams import route apply contract planning failed. $message run_id=$RunId"
    exit 1
}
