<#
.SYNOPSIS
  Classify master-control routines by function, work style, and maturity.

.DESCRIPTION
  Read-only worker that consumes the latest unified import route registry and classifies
  each route by what it does first, then how mature/clear the idea appears.

  Primary classification:
    - function_family

  Secondary classification:
    - work_style
    - track_guess
    - maturity_stage
    - clarity_level

  This avoids relying on creation date, filename, or "grinder" naming because the old
  system evolved chaotically and some ideas matured at different times.

  No provider calls.
  No DB reads.
  No DB writes.
  No imports.

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

$WorkerName = "classify_master_control_worker_functions"
$Component = "master_control_worker_function_classification"
$DatabaseTarget = "none"
$SourceName = "unified_import_route_registry"
$KillSwitchName = "ENABLE_MASTER_CONTROL_WORKER_FUNCTION_CLASSIFIER"

$CompletedSignal = "master_control_worker_functions_classified_completed"
$FunctionCountSignal = "master_control_worker_functions_total_count"
$ReviewCountSignal = "master_control_worker_functions_review_count"
$CanonicalCountSignal = "master_control_worker_functions_canonical_candidate_count"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\master_control_worker_functions"
$LogRoot = Join-Path $RepoRoot "runtime\logs\master_control_worker_functions"

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

function Get-LatestRegistryCsv {
    if (-not [string]::IsNullOrWhiteSpace($RouteRegistryCsv)) {
        if (-not (Test-Path -LiteralPath $RouteRegistryCsv)) {
            throw "Route registry CSV not found: $RouteRegistryCsv"
        }
        return (Resolve-Path -LiteralPath $RouteRegistryCsv).Path
    }

    $registryRoot = Join-Path $RepoRoot "runtime\reports\unified_import_route_registry"
    if (-not (Test-Path -LiteralPath $registryRoot)) {
        throw "Unified route registry folder not found. Run normalize_master_control_manifest_to_import_route_registry.ps1 first."
    }

    $latest = Get-ChildItem -LiteralPath $registryRoot -Filter "unified_import_route_registry_*.csv" -File |
        Where-Object { $_.Name -notmatch "_summary_" } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $latest) {
        throw "No unified_import_route_registry_*.csv file found. Run normalize_master_control_manifest_to_import_route_registry.ps1 first."
    }

    return $latest.FullName
}

function Get-Field {
    param([object]$Row, [string]$Name, [string]$Default = "")

    if ($null -eq $Row) {
        return $Default
    }

    $property = $Row.PSObject.Properties |
        Where-Object { $_.Name -ieq $Name } |
        Select-Object -First 1

    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }

    return [string]$property.Value
}

function Get-CombinedText {
    param([object]$Row)

    return (
        (Get-Field $Row "lane") + " " +
        (Get-Field $Row "source_lane_name") + " " +
        (Get-Field $Row "actual_file_hint") + " " +
        (Get-Field $Row "uploaded_file") + " " +
        (Get-Field $Row "current_relative_path") + " " +
        (Get-Field $Row "current_absolute_path") + " " +
        (Get-Field $Row "role") + " " +
        (Get-Field $Row "execution_type") + " " +
        (Get-Field $Row "purpose") + " " +
        (Get-Field $Row "route_type") + " " +
        (Get-Field $Row "operation_guess") + " " +
        (Get-Field $Row "clean_repo_target") + " " +
        (Get-Field $Row "migration_status") + " " +
        (Get-Field $Row "contract_gap") + " " +
        (Get-Field $Row "recommended_next_action")
    ).ToLowerInvariant()
}

function Get-FunctionFamily {
    param([object]$Row)

    $text = Get-CombinedText -Row $Row

    if ($text -match "signal|dashboard|contract|manifest|route registry|registry|readiness|preflight|gate|disposition|governance") { return "platform_governance" }
    if ($text -match "ai|openai|ollama|tmdb|metadata|poster|backdrop|enrich|update information|clean_search|materialize.*metadata") { return "enrich_metadata" }
    if ($text -match "provider api|pull provider|pull live|pull vod|pull series|pull epg|download provider|snapshot") { return "acquire_provider_data" }
    if ($text -match "array-shaped|arrays|nested|bracket|separate|split.*array|raw payload") { return "separate_raw_payload_shapes" }
    if ($text -match "router|route raw|route payload|routing") { return "route_payload" }
    if ($text -match "normaliz|canonical|clean name|clean_search") { return "normalize_payload" }
    if ($text -match "grinder|grind|extract primary|extract episode|extract season|fragment") { return "grind_extract_records" }
    if ($text -match "cleanup|cleaner|quarantine|move processed|processed folder") { return "clean_or_quarantine_files" }
    if ($text -match "upload|ftp|raw_store|incoming path") { return "upload_artifacts" }
    if ($text -match "server_side_ingest|ingest_series|remote import|server-side ingest|php endpoint|server:/") { return "server_side_ingest" }
    if ($text -match "import_.*\.ps1|provider_payload_import|import live|import vod|import series|import epg|import locally acquired") { return "import_to_database_or_server" }
    if ($text -match "materialize|materialization") { return "materialize_catalog" }
    if ($text -match "query_content|query helper|query_helper|query file") { return "query_helper" }
    if ($text -match "state marker|\.last|last-state") { return "state_tracking" }
    if ($text -match "trigger|orchestrator|runner|batch") { return "orchestrate_workflow" }
    if ($text -match "diagnostic|report|inventory|summary") { return "diagnostic_or_report" }

    return "unknown_review"
}

function Get-WorkStyle {
    param([object]$Row, [string]$FunctionFamily)

    $text = Get-CombinedText -Row $Row

    if ($FunctionFamily -eq "platform_governance") { return "platform_control" }
    if ($FunctionFamily -eq "enrich_metadata") {
        if ($text -match "tmdb") { return "tmdb_enrichment" }
        if ($text -match "ai|openai|ollama") { return "ai_arbitration_or_legacy_ai" }
        return "local_first_enrichment"
    }

    if ($text -match "delta|snapshot|provider-noise|bounded|disposition|readiness|preflight|contract") { return "delta_or_snapshot_based" }
    if ($text -match "server:/|\.php|server_side|endpoint|remote") { return "server_endpoint_or_remote_trigger" }
    if ($text -match "ftp|upload") { return "upload_worker" }
    if ($text -match "query_content|query_helper") { return "query_helper" }
    if ($text -match "router") { return "router" }
    if ($text -match "normaliz") { return "normalizer" }
    if ($text -match "grinder|grind|nested|bracket|array") { return "brute_force_or_shape_processor" }
    if ($text -match "import_.*\.ps1|provider_payload_import") { return "legacy_import_wrapper" }
    if ($text -match "trigger|runner|orchestrator|\.bat") { return "wrapper_or_orchestrator" }

    return "manual_or_unknown"
}

function Get-TrackGuess {
    param([object]$Row, [string]$FunctionFamily, [string]$WorkStyle)

    $text = Get-CombinedText -Row $Row

    if ($FunctionFamily -eq "platform_governance") { return "platform_track" }
    if ($FunctionFamily -eq "enrich_metadata") { return "local_first_enrichment_track" }

    if ($text -match "snapshot|delta|provider-noise|bounded writes|enqueue|row-disposition|provider inventory snapshot") {
        return "new_method_track"
    }

    if ($WorkStyle -in @("router", "normalizer", "server_endpoint_or_remote_trigger", "upload_worker", "query_helper")) {
        return "hybrid_track"
    }

    if ($WorkStyle -in @("brute_force_or_shape_processor", "legacy_import_wrapper", "wrapper_or_orchestrator")) {
        return "legacy_track"
    }

    return "unknown_track"
}

function Get-MaturityStage {
    param([object]$Row, [string]$FunctionFamily, [string]$WorkStyle, [string]$TrackGuess)

    $text = Get-CombinedText -Row $Row

    if ($FunctionFamily -eq "platform_governance") { return "platformized" }
    if ($text -match "needs governed|needs contract|rewrite_required|review_before_migration|candidate.*review") { return "needs_governed_rebuild_or_review" }
    if ($text -match "rebuild_as_delta|bounded writes|dry-run planning|provider inventory snapshot") { return "mature_concept_needs_apply_worker" }
    if ($text -match "current_system_evidence") { return "working_legacy_evidence" }
    if ($text -match "server_worker_contract_review|php logging") { return "server_capability_needs_adapter" }
    if ($FunctionFamily -eq "enrich_metadata" -and $WorkStyle -match "tmdb") { return "mature_external_reference_strategy" }
    if ($FunctionFamily -eq "enrich_metadata" -and $WorkStyle -match "ai") { return "legacy_ai_experiment_or_arbitration_candidate" }
    if ($FunctionFamily -eq "unknown_review") { return "unknown_review" }

    return "partially_mature"
}

function Get-ClarityLevel {
    param([object]$Row, [string]$FunctionFamily, [string]$WorkStyle, [string]$MaturityStage)

    $text = Get-CombinedText -Row $Row

    if ($FunctionFamily -ne "unknown_review" -and $WorkStyle -ne "manual_or_unknown" -and $MaturityStage -ne "unknown_review") {
        if ($text -match "purpose") { return "clear" }
        return "mostly_clear"
    }

    if ($FunctionFamily -ne "unknown_review" -or $WorkStyle -ne "manual_or_unknown") {
        return "partial"
    }

    return "unclear"
}

function Get-EnrichmentStrategy {
    param([object]$Row, [string]$FunctionFamily)

    if ($FunctionFamily -ne "enrich_metadata") {
        return "not_enrichment"
    }

    $text = Get-CombinedText -Row $Row
    $hasAi = ($text -match "ai|openai|ollama|chat|completion|embedding")
    $hasTmdb = ($text -match "tmdb")
    $hasProvider = ($text -match "provider|playlist|get_vod_info|get_series_info")
    $hasLocal = ($text -match "local|clean_search|metadata|catalog|array|normaliz|existing")

    if ($hasTmdb -and $hasAi) { return "mixed_ai_tmdb" }
    if ($hasTmdb) { return "tmdb_primary" }
    if ($hasAi) { return "ai_legacy_or_arbitration" }
    if ($hasLocal -and $hasProvider) { return "local_provider_fallback" }
    if ($hasLocal) { return "local_first_unknown_enrichment" }

    return "unknown_review"
}

function Get-CanonicalCandidate {
    param(
        [string]$FunctionFamily,
        [string]$WorkStyle,
        [string]$TrackGuess,
        [string]$MaturityStage,
        [string]$ClarityLevel
    )

    if ($FunctionFamily -eq "platform_governance") { return $true }
    if ($TrackGuess -eq "new_method_track" -and $MaturityStage -ne "unknown_review") { return $true }
    if ($FunctionFamily -eq "enrich_metadata" -and $MaturityStage -notmatch "legacy_ai") { return $true }
    if ($FunctionFamily -eq "import_to_database_or_server" -and $TrackGuess -eq "new_method_track") { return $true }

    return $false
}

function Get-ReplacementCandidate {
    param(
        [string]$FunctionFamily,
        [string]$WorkStyle,
        [string]$TrackGuess,
        [string]$MaturityStage
    )

    if ($TrackGuess -eq "legacy_track" -and $FunctionFamily -in @("grind_extract_records", "import_to_database_or_server", "orchestrate_workflow")) {
        return $true
    }

    if ($MaturityStage -match "needs_governed_rebuild_or_review|server_capability_needs_adapter") {
        return $true
    }

    return $false
}

function Get-RecommendedAction {
    param(
        [string]$FunctionFamily,
        [string]$WorkStyle,
        [string]$TrackGuess,
        [string]$MaturityStage,
        [string]$EnrichmentStrategy,
        [bool]$CanonicalCandidate,
        [bool]$ReplacementCandidate
    )

    if ($FunctionFamily -eq "platform_governance") {
        return "keep_as_platform_control"
    }

    if ($FunctionFamily -eq "enrich_metadata") {
        if ($EnrichmentStrategy -eq "tmdb_primary") { return "promote_tmdb_as_primary_enrichment" }
        if ($EnrichmentStrategy -eq "mixed_ai_tmdb") { return "split_tmdb_primary_ai_arbitration_fallback" }
        if ($EnrichmentStrategy -eq "ai_legacy_or_arbitration") { return "keep_ai_only_as_arbitration_or_manual_fallback" }
        return "inspect_and_convert_to_local_first_enrichment"
    }

    if ($FunctionFamily -eq "import_to_database_or_server") {
        if ($TrackGuess -eq "new_method_track") { return "promote_after_limited_apply_validation" }
        return "replace_with_governed_delta_import_or_enqueue_worker"
    }

    if ($FunctionFamily -eq "server_side_ingest") {
        return "wrap_with_php_logging_signal_killswitch_adapter_before_canonical_use"
    }

    if ($FunctionFamily -eq "upload_artifacts") {
        return "rewrite_with_secure_upload_bounded_retry"
    }

    if ($FunctionFamily -eq "query_helper") {
        return "register_as_adapter_dependency_after_inspection"
    }

    if ($FunctionFamily -in @("grind_extract_records", "separate_raw_payload_shapes")) {
        return "compare_against_faster_shape_processor_then_retire_legacy_after_validation"
    }

    if ($FunctionFamily -in @("route_payload", "normalize_payload")) {
        return "preserve_if_output_contract_is_still_needed"
    }

    if ($FunctionFamily -eq "acquire_provider_data") {
        return "compare_against_provider_snapshot_spine_and_retire_duplicate"
    }

    if ($FunctionFamily -eq "clean_or_quarantine_files") {
        return "wrap_as_safe_cleanup_with_dry_run"
    }

    if ($FunctionFamily -eq "orchestrate_workflow") {
        return "replace_with_governed_runner_or_keep_as_reference"
    }

    if ($FunctionFamily -eq "unknown_review") {
        return "manual_review"
    }

    return "manual_review"
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

    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($row in $registryRows) {
        $functionFamily = Get-FunctionFamily -Row $row
        $workStyle = Get-WorkStyle -Row $row -FunctionFamily $functionFamily
        $trackGuess = Get-TrackGuess -Row $row -FunctionFamily $functionFamily -WorkStyle $workStyle
        $maturityStage = Get-MaturityStage -Row $row -FunctionFamily $functionFamily -WorkStyle $workStyle -TrackGuess $trackGuess
        $clarityLevel = Get-ClarityLevel -Row $row -FunctionFamily $functionFamily -WorkStyle $workStyle -MaturityStage $maturityStage
        $enrichmentStrategy = Get-EnrichmentStrategy -Row $row -FunctionFamily $functionFamily
        $canonical = Get-CanonicalCandidate -FunctionFamily $functionFamily -WorkStyle $workStyle -TrackGuess $trackGuess -MaturityStage $maturityStage -ClarityLevel $clarityLevel
        $replacement = Get-ReplacementCandidate -FunctionFamily $functionFamily -WorkStyle $workStyle -TrackGuess $trackGuess -MaturityStage $maturityStage
        $recommended = Get-RecommendedAction -FunctionFamily $functionFamily -WorkStyle $workStyle -TrackGuess $trackGuess -MaturityStage $maturityStage -EnrichmentStrategy $enrichmentStrategy -CanonicalCandidate $canonical -ReplacementCandidate $replacement

        $needsReview = $false
        if ($functionFamily -eq "unknown_review" -or $workStyle -eq "manual_or_unknown" -or $clarityLevel -in @("partial", "unclear") -or $recommended -eq "manual_review") {
            $needsReview = $true
        }

        if ((Get-Field $row "needs_review") -eq "True") {
            $needsReview = $true
        }

        $rows.Add([pscustomobject][ordered]@{
            route_key = Get-Field $row "route_key"
            lane = Get-Field $row "lane"
            source_lane_name = Get-Field $row "source_lane_name"
            step_order = Get-Field $row "step_order"
            sub_order = Get-Field $row "sub_order"
            actual_file_hint = Get-Field $row "actual_file_hint"
            current_relative_path = Get-Field $row "current_relative_path"
            current_absolute_path = Get-Field $row "current_absolute_path"
            role = Get-Field $row "role"
            execution_type = Get-Field $row "execution_type"
            purpose = Get-Field $row "purpose"
            route_type = Get-Field $row "route_type"
            media_type_guess = Get-Field $row "media_type_guess"
            operation_guess = Get-Field $row "operation_guess"
            function_family = $functionFamily
            work_style = $workStyle
            track_guess = $trackGuess
            maturity_stage = $maturityStage
            clarity_level = $clarityLevel
            enrichment_strategy = $enrichmentStrategy
            canonical_candidate = $canonical
            replacement_candidate = $replacement
            needs_review = $needsReview
            recommended_action = $recommended
            prior_recommended_next_action = Get-Field $row "recommended_next_action"
            risk_level = Get-Field $row "risk_level"
            clean_repo_target = Get-Field $row "clean_repo_target"
            migration_status = Get-Field $row "migration_status"
            contract_gap = Get-Field $row "contract_gap"
            secret_risk = Get-Field $row "secret_risk"
        }) | Out-Null
    }

    $totalCount = @($rows).Count
    $reviewCount = @($rows | Where-Object { $_.needs_review -eq $true }).Count
    $canonicalCount = @($rows | Where-Object { $_.canonical_candidate -eq $true }).Count
    $replacementCount = @($rows | Where-Object { $_.replacement_candidate -eq $true }).Count
    $unknownCount = @($rows | Where-Object { $_.function_family -eq "unknown_review" }).Count
    $importCount = @($rows | Where-Object { $_.function_family -eq "import_to_database_or_server" }).Count
    $enrichmentCount = @($rows | Where-Object { $_.function_family -eq "enrich_metadata" }).Count
    $platformCount = @($rows | Where-Object { $_.function_family -eq "platform_governance" }).Count
    $legacyTrackCount = @($rows | Where-Object { $_.track_guess -eq "legacy_track" }).Count
    $hybridTrackCount = @($rows | Where-Object { $_.track_guess -eq "hybrid_track" }).Count
    $newMethodTrackCount = @($rows | Where-Object { $_.track_guess -eq "new_method_track" }).Count
    $platformTrackCount = @($rows | Where-Object { $_.track_guess -eq "platform_track" }).Count
    $enrichmentTrackCount = @($rows | Where-Object { $_.track_guess -eq "local_first_enrichment_track" }).Count

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $functionsCsv = Join-Path $OutputRoot "master_control_worker_functions_$timestamp.csv"
    $functionsJson = Join-Path $OutputRoot "master_control_worker_functions_$timestamp.json"
    $summaryJson = Join-Path $OutputRoot "master_control_worker_functions_summary_$timestamp.json"

    $rows | Export-Csv -Path $functionsCsv -NoTypeInformation
    $rows | ConvertTo-Json -Depth 20 | Set-Content -Path $functionsJson -Encoding UTF8

    $summary = [ordered]@{
        status = "pass"
        preview_only = $true
        db_writes = $false
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        source_registry_csv = $registryPath
        total_count = $totalCount
        review_count = $reviewCount
        canonical_candidate_count = $canonicalCount
        replacement_candidate_count = $replacementCount
        unknown_review_count = $unknownCount
        import_function_count = $importCount
        enrichment_function_count = $enrichmentCount
        platform_function_count = $platformCount
        legacy_track_guess_count = $legacyTrackCount
        hybrid_track_guess_count = $hybridTrackCount
        new_method_track_guess_count = $newMethodTrackCount
        platform_track_guess_count = $platformTrackCount
        local_first_enrichment_track_guess_count = $enrichmentTrackCount
        functions_csv = $functionsCsv
        functions_json = $functionsJson
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue "pass" -Payload $summary
    Emit-LocalSignal -SignalName $FunctionCountSignal -SignalValue $totalCount -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $ReviewCountSignal -SignalValue $reviewCount -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $CanonicalCountSignal -SignalValue $canonicalCount -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status "pass" -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: master control worker functions classified. status=pass total=$totalCount import=$importCount enrichment=$enrichmentCount platform=$platformCount canonical=$canonicalCount replacement=$replacementCount review=$reviewCount db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: functions_csv=$functionsCsv functions_json=$functionsJson summary_json=$summaryJson"
        $rows |
            Select-Object -First 35 function_family, work_style, track_guess, maturity_stage, actual_file_hint, lane, recommended_action |
            Format-Table -AutoSize
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

    Write-Error "FAILED: master control worker function classification failed. $message run_id=$RunId"
    exit 1
}
