<#
.SYNOPSIS
  Plan the VOD streams apply SQL/parameter contract.

.DESCRIPTION
  Read-only planner for the future VOD streams apply worker.

  This worker consumes:
    - latest VOD apply DB target selector summary
    - latest VOD apply mapping fixture summary/report

  It emits the proposed SQL/parameter contract and required safeguards for a future
  bounded apply implementation.

  No provider calls.
  No DB reads.
  No DB writes.
  No real snapshot mutation.

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

$WorkerName = "plan_vod_streams_apply_sql_contract"
$Component = "vod_streams_apply_sql_contract"
$DatabaseTarget = "xpdgxfsp_content"
$SourceName = "vod_apply_db_target_selector"
$KillSwitchName = "ENABLE_VOD_STREAMS_APPLY_SQL_CONTRACT_PLANNER"

$CompletedSignal = "vod_streams_apply_sql_contract_planned_completed"
$TargetTypeSignal = "vod_streams_apply_sql_contract_target_type"
$ParameterCountSignal = "vod_streams_apply_sql_contract_parameter_count"
$ApplyModeSignal = "vod_streams_apply_sql_contract_apply_mode"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\vod_streams_apply_sql_contract"
$LogRoot = Join-Path $RepoRoot "runtime\logs\vod_streams_apply_sql_contract"

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

try {
    Write-LocalJsonLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        db_writes = $false
        provider_calls = $false
    })

    Emit-LocalHeartbeat -Status "running"

    if (-not (Test-WorkerKillSwitch)) {
        $summary = [ordered]@{
            status = "disabled"
            disposition = "disabled_by_kill_switch"
            db_writes = $false
            provider_calls = $false
            run_id = $RunId
        }

        Emit-LocalSignal -SignalName $CompletedSignal -SignalValue "disabled" -Payload $summary
        Write-LocalJsonLog -EventName "job_completed" -Status "disabled" -Data $summary
        Write-Output "SKIPPED: $KillSwitchName is disabled. run_id=$RunId"
        exit 0
    }

    $selectorSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_apply_db_target_selector") -Filter "vod_apply_db_target_selector_summary_*.json"
    $fixtureSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_streams_apply_mapping_fixture") -Filter "vod_streams_apply_mapping_fixture_summary_*.json"

    if ($null -eq $selectorSummaryFile) {
        throw "VOD apply DB target selector summary not found. Run select_vod_apply_db_target_candidate.ps1 first."
    }

    if ($null -eq $fixtureSummaryFile) {
        throw "VOD streams apply mapping fixture summary not found. Run test_vod_streams_apply_mapping_fixture.ps1 first."
    }

    $selectorSummary = Read-JsonFile -Path $selectorSummaryFile.FullName
    $fixtureSummary = Read-JsonFile -Path $fixtureSummaryFile.FullName

    $selectedType = Get-Text -Object $selectorSummary -Name "selected_type" -Default "unknown"
    $selectedConfidence = Get-Text -Object $selectorSummary -Name "selected_confidence" -Default "unknown"
    $reviewRequired = Get-Bool -Object $selectorSummary -Name "review_required" -Default $true
    $selectedFilePath = Get-Text -Object $selectorSummary -Name "selected_file_path" -Default ""

    $fixtureReportCsv = Get-Text -Object $fixtureSummary -Name "report_csv" -Default ""
    $fixtureRows = @()
    if (-not [string]::IsNullOrWhiteSpace($fixtureReportCsv) -and (Test-Path -LiteralPath $fixtureReportCsv)) {
        $fixtureRows = @(Import-Csv -LiteralPath $fixtureReportCsv)
    }

    $parameterNames = @(
        "provider_label",
        "provider_stream_id",
        "provider_category_id",
        "title_raw",
        "title_clean",
        "stream_icon",
        "added",
        "rating",
        "year"
    )

    $requiredParameters = @(
        "provider_label",
        "provider_stream_id",
        "provider_category_id",
        "title_raw"
    )

    $protectedRules = @(
        "do_not_overwrite_enriched_fields_with_blank_provider_values",
        "do_not_delete_existing_vod_rows",
        "do_not_import_without_real_selector_candidate",
        "do_not_import_from_synthetic_candidate",
        "do_not_run_unbounded_legacy_import_vod_streams",
        "do_not_call_provider_from_apply_worker",
        "row_errors_get_disposition_not_worker_failure"
    )

    $targetTable = "xpdgxfsp_content.vod"
    $keyStrategy = "provider + provider_vod_id"
    $writeStrategy = "bounded_upsert_preview_contract"
    $applyMode = "authorized_limited_apply_supported"

    $sqlTemplate = @"
-- APPLY CONTRACT. Execute only through MiraDbSafeAdapter with explicit worker authorization.
-- Named parameters are converted to positional bindings by the safe adapter for dog_open_proc.
INSERT INTO xpdgxfsp_content.vod (
    provider,
    provider_vod_id,
    category_id,
    title,
    clean_search_name,
    provider_poster_url,
    added_at,
    rating,
    release_year,
    updated_at
)
VALUES (
    :provider_label,
    :provider_stream_id,
    :provider_category_id,
    :title_raw,
    :title_clean,
    :stream_icon,
    NULLIF(:added, ''),
    NULLIF(:rating, ''),
    NULLIF(:year, ''),
    NOW()
)
ON DUPLICATE KEY UPDATE
    category_id = VALUES(category_id),
    title = COALESCE(NULLIF(VALUES(title), ''), title),
    clean_search_name = COALESCE(NULLIF(VALUES(clean_search_name), ''), clean_search_name),
    provider_poster_url = COALESCE(NULLIF(VALUES(provider_poster_url), ''), provider_poster_url),
    added_at = COALESCE(VALUES(added_at), added_at),
    rating = COALESCE(VALUES(rating), rating),
    release_year = COALESCE(VALUES(release_year), release_year),
    updated_at = NOW();
"@

    $blockedReasons = @()
    if ($selectedType -ne "governed_delta_worker_route") {
        $blockedReasons += "selected_target_not_governed_delta_worker_route"
    }

    if ($selectedConfidence -ne "high") {
        $blockedReasons += "selected_confidence_not_high"
    }

    if ($reviewRequired) {
        $blockedReasons += "selector_review_required"
    }

    if (@($fixtureRows).Count -eq 0) {
        $blockedReasons += "fixture_rows_missing"
    }

    $contractStatus = "pass"
    $disposition = "sql_contract_planned"
    if (@($blockedReasons).Count -gt 0) {
        $contractStatus = "warning"
        $disposition = "sql_contract_planned_with_review_blocks"
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $contractJson = Join-Path $OutputRoot "vod_streams_apply_sql_contract_$timestamp.json"
    $contractCsv = Join-Path $OutputRoot "vod_streams_apply_sql_contract_$timestamp.csv"
    $parameterCsv = Join-Path $OutputRoot "vod_streams_apply_sql_contract_parameters_$timestamp.csv"
    $sqlTxt = Join-Path $OutputRoot "vod_streams_apply_sql_contract_template_$timestamp.sql.txt"
    $summaryJson = Join-Path $OutputRoot "vod_streams_apply_sql_contract_summary_$timestamp.json"

    $parameterRows = @()
    foreach ($name in $parameterNames) {
        $parameterRows += [pscustomobject][ordered]@{
            parameter_name = $name
            required = ($name -in $requiredParameters)
            source_field = $name
            nullable = -not ($name -in $requiredParameters)
            db_writes = $false
            provider_calls = $false
        }
    }

    $parameterRows | Export-Csv -Path $parameterCsv -NoTypeInformation
    $sqlTemplate | Set-Content -Path $sqlTxt -Encoding UTF8

    $contract = [ordered]@{
        contract_name = "vod_streams_apply_sql_contract_v1"
        status = $contractStatus
        disposition = $disposition
        selected_type = $selectedType
        selected_confidence = $selectedConfidence
        review_required = $reviewRequired
        selected_file_path = $selectedFilePath
        target_table = $targetTable
        key_strategy = $keyStrategy
        write_strategy = $writeStrategy
        apply_mode = $applyMode
        required_parameters = $requiredParameters
        optional_parameters = @($parameterNames | Where-Object { $_ -notin $requiredParameters })
        protected_rules = $protectedRules
        blocked_reasons = $blockedReasons
        fixture_report_csv = $fixtureReportCsv
        sql_template_file = $sqlTxt
        parameter_csv = $parameterCsv
        db_writes = $false
        provider_calls = $false
    }

    $contract | ConvertTo-Json -Depth 20 | Set-Content -Path $contractJson -Encoding UTF8

    [pscustomobject][ordered]@{
        contract_name = $contract.contract_name
        status = $contractStatus
        disposition = $disposition
        selected_type = $selectedType
        selected_confidence = $selectedConfidence
        review_required = $reviewRequired
        target_table = $targetTable
        key_strategy = $keyStrategy
        write_strategy = $writeStrategy
        apply_mode = $applyMode
        parameter_count = @($parameterNames).Count
        required_parameter_count = @($requiredParameters).Count
        blocked_reasons = ($blockedReasons -join "|")
        db_writes = $false
        provider_calls = $false
    } | Export-Csv -Path $contractCsv -NoTypeInformation

    $summary = [ordered]@{
        status = $contractStatus
        disposition = $disposition
        db_writes = $false
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        selected_type = $selectedType
        selected_confidence = $selectedConfidence
        review_required = $reviewRequired
        target_table = $targetTable
        apply_mode = $applyMode
        parameter_count = @($parameterNames).Count
        required_parameter_count = @($requiredParameters).Count
        blocked_reasons = $blockedReasons
        selector_summary_json = $selectorSummaryFile.FullName
        fixture_summary_json = $fixtureSummaryFile.FullName
        contract_csv = $contractCsv
        contract_json = $contractJson
        parameter_csv = $parameterCsv
        sql_template_file = $sqlTxt
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $contractStatus -Payload $summary
    Emit-LocalSignal -SignalName $TargetTypeSignal -SignalValue $selectedType -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $ParameterCountSignal -SignalValue @($parameterNames).Count -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $ApplyModeSignal -SignalValue $applyMode -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $contractStatus -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: VOD streams apply SQL contract planned. status=$contractStatus disposition=$disposition target=$targetTable apply_mode=$applyMode db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: contract_csv=$contractCsv contract_json=$contractJson parameter_csv=$parameterCsv sql_template_file=$sqlTxt summary_json=$summaryJson"
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

    Write-Error "FAILED: VOD streams apply SQL contract planner failed. $message run_id=$RunId"
    exit 1
}

