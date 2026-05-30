<#
.SYNOPSIS
  Plan VOD apply adapter selection.

.DESCRIPTION
  Read-only adapter selector/planner.

  This worker consumes:
    - latest VOD apply DB target selector summary
    - latest VOD streams apply SQL contract summary
    - latest SQL parameter binding fixture summary

  It recommends the safest future adapter strategy for real bounded VOD apply:
    - direct_sql_adapter
    - php_endpoint_adapter
    - cvi_or_dog_opens_adapter
    - new_safe_powershell_db_adapter

  It does not connect to the database.
  It does not write to the database.
  It does not call providers.
  It does not mutate real snapshots.

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

$WorkerName = "plan_vod_apply_adapter_selection"
$Component = "vod_apply_adapter_selection"
$DatabaseTarget = "xpdgxfsp_content"
$SourceName = "vod_streams_apply_sql_contract"
$KillSwitchName = "ENABLE_VOD_APPLY_ADAPTER_SELECTION_PLANNER"

$CompletedSignal = "vod_apply_adapter_selection_planned_completed"
$SelectedAdapterSignal = "vod_apply_adapter_selection_selected_adapter"
$ReadinessSignal = "vod_apply_adapter_selection_readiness"
$ReviewRequiredSignal = "vod_apply_adapter_selection_review_required"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\vod_apply_adapter_selection"
$LogRoot = Join-Path $RepoRoot "runtime\logs\vod_apply_adapter_selection"

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

function Get-IntValue {
    param([object]$Object, [string]$Name, [int]$Default = 0)

    $text = Get-Text -Object $Object -Name $Name -Default ""
    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }

    $value = 0
    if ([int]::TryParse($text, [ref]$value)) { return $value }

    return $Default
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
    $sqlContractSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_streams_apply_sql_contract") -Filter "vod_streams_apply_sql_contract_summary_*.json"
    $bindingSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_streams_sql_parameter_binding_fixture") -Filter "vod_streams_sql_parameter_binding_fixture_summary_*.json"

    if ($null -eq $selectorSummaryFile) {
        throw "VOD apply DB target selector summary not found. Run select_vod_apply_db_target_candidate.ps1 first."
    }

    if ($null -eq $sqlContractSummaryFile) {
        throw "VOD streams apply SQL contract summary not found. Run plan_vod_streams_apply_sql_contract.ps1 first."
    }

    if ($null -eq $bindingSummaryFile) {
        throw "VOD streams SQL parameter binding fixture summary not found. Run test_vod_streams_sql_parameter_binding_fixture.ps1 first."
    }

    $selectorSummary = Read-JsonFile -Path $selectorSummaryFile.FullName
    $sqlContractSummary = Read-JsonFile -Path $sqlContractSummaryFile.FullName
    $bindingSummary = Read-JsonFile -Path $bindingSummaryFile.FullName

    $selectedTargetType = Get-Text -Object $selectorSummary -Name "selected_type" -Default "unknown"
    $selectedConfidence = Get-Text -Object $selectorSummary -Name "selected_confidence" -Default "unknown"
    $targetReviewRequired = Get-Bool -Object $selectorSummary -Name "review_required" -Default $true

    $targetTable = Get-Text -Object $sqlContractSummary -Name "target_table" -Default "unknown"
    $applyMode = Get-Text -Object $sqlContractSummary -Name "apply_mode" -Default "unknown"
    $parameterCount = Get-IntValue -Object $sqlContractSummary -Name "parameter_count" -Default 0
    $requiredParameterCount = Get-IntValue -Object $sqlContractSummary -Name "required_parameter_count" -Default 0

    $bindableCount = Get-IntValue -Object $bindingSummary -Name "bindable_count" -Default 0
    $bindingRejectedCount = Get-IntValue -Object $bindingSummary -Name "rejected_count" -Default 0

    $adapterCandidates = @()

    $adapterCandidates += [pscustomobject][ordered]@{
        adapter_name = "new_safe_powershell_db_adapter"
        rank = 1
        recommendation = "preferred"
        reason = "matches governed delta worker route and current PowerShell worker architecture; can enforce limit, dry-run, row disposition, and selector authorization"
        required_controls = "Apply switch;Limit guard;real selector authorization;parameter binding;row dispositions;transaction optional later"
        db_writes_now = $false
        provider_calls = $false
    }

    $adapterCandidates += [pscustomobject][ordered]@{
        adapter_name = "direct_sql_adapter"
        rank = 2
        recommendation = "candidate_after_db_schema_validation"
        reason = "SQL contract exists, but schema/unique-key validation is still required before real writes"
        required_controls = "schema check;unique key check;parameterized SQL;dry-run preview"
        db_writes_now = $false
        provider_calls = $false
    }

    $adapterCandidates += [pscustomobject][ordered]@{
        adapter_name = "php_endpoint_adapter"
        rank = 3
        recommendation = "not_preferred_for_first_vod_apply"
        reason = "inventory high-confidence PHP endpoints were mostly unrelated artwork/search-name endpoints, not VOD apply"
        required_controls = "new or verified endpoint;token handling;server logging;bounded writes"
        db_writes_now = $false
        provider_calls = $false
    }

    $adapterCandidates += [pscustomobject][ordered]@{
        adapter_name = "cvi_or_dog_opens_adapter"
        rank = 4
        recommendation = "manual_review_only"
        reason = "manifest shows query/dog_opens exists elsewhere, but no canonical VOD apply query file was selected"
        required_controls = "locate exact query;parameter contract;bounded write proof"
        db_writes_now = $false
        provider_calls = $false
    }

    $adapterCandidates += [pscustomobject][ordered]@{
        adapter_name = "legacy_import_vod_streams_wrapper"
        rank = 5
        recommendation = "do_not_use_for_first_real_apply"
        reason = "legacy wrapper is marked endpoint/import-token risk and unbounded; current design explicitly avoids it"
        required_controls = "replace with governed delta apply"
        db_writes_now = $false
        provider_calls = $false
    }

    $selectedAdapter = "new_safe_powershell_db_adapter"
    $readiness = "planned_not_apply_ready"
    $reviewRequired = $true
    $blockedReasons = @()

    if ($selectedTargetType -ne "governed_delta_worker_route") {
        $blockedReasons += "selected_target_type_not_governed_delta_worker_route"
    }

    if ($selectedConfidence -ne "high") {
        $blockedReasons += "selected_target_confidence_not_high"
    }

    if ($targetReviewRequired) {
        $blockedReasons += "target_selector_review_required"
    }

    if ($targetTable -ne "xpdgxfsp_content.vod") {
        $blockedReasons += "target_table_not_confirmed_as_xpdgxfsp_content_vod"
    }

    if ($parameterCount -lt 5 -or $requiredParameterCount -lt 5) {
        $blockedReasons += "parameter_contract_incomplete"
    }

    if ($bindableCount -lt 1) {
        $blockedReasons += "no_bindable_fixture_row"
    }

    if (@($blockedReasons).Count -eq 0) {
        $readiness = "adapter_selected_schema_validation_needed"
        $reviewRequired = $false
    }

    $status = "pass"
    $disposition = "adapter_selection_planned"
    if (@($blockedReasons).Count -gt 0) {
        $status = "warning"
        $disposition = "adapter_selection_planned_with_blocks"
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $candidateCsv = Join-Path $OutputRoot "vod_apply_adapter_selection_candidates_$timestamp.csv"
    $selectionCsv = Join-Path $OutputRoot "vod_apply_adapter_selection_$timestamp.csv"
    $selectionJson = Join-Path $OutputRoot "vod_apply_adapter_selection_$timestamp.json"
    $summaryJson = Join-Path $OutputRoot "vod_apply_adapter_selection_summary_$timestamp.json"

    $adapterCandidates | Export-Csv -Path $candidateCsv -NoTypeInformation

    $selectionRow = [pscustomobject][ordered]@{
        disposition = $disposition
        selected_adapter = $selectedAdapter
        readiness = $readiness
        review_required = $reviewRequired
        selected_target_type = $selectedTargetType
        selected_confidence = $selectedConfidence
        target_table = $targetTable
        apply_mode = $applyMode
        parameter_count = $parameterCount
        required_parameter_count = $requiredParameterCount
        bindable_count = $bindableCount
        binding_rejected_count = $bindingRejectedCount
        blocked_reasons = ($blockedReasons -join "|")
        next_worker_to_build = "test_vod_apply_db_schema_contract.ps1"
        db_writes = $false
        provider_calls = $false
    }

    $selectionRow | Export-Csv -Path $selectionCsv -NoTypeInformation
    $selectionRow | ConvertTo-Json -Depth 20 | Set-Content -Path $selectionJson -Encoding UTF8

    $summary = [ordered]@{
        status = $status
        disposition = $disposition
        db_writes = $false
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        selected_adapter = $selectedAdapter
        readiness = $readiness
        review_required = $reviewRequired
        selected_target_type = $selectedTargetType
        selected_confidence = $selectedConfidence
        target_table = $targetTable
        apply_mode = $applyMode
        parameter_count = $parameterCount
        required_parameter_count = $requiredParameterCount
        bindable_count = $bindableCount
        binding_rejected_count = $bindingRejectedCount
        blocked_reasons = $blockedReasons
        next_worker_to_build = "test_vod_apply_db_schema_contract.ps1"
        selector_summary_json = $selectorSummaryFile.FullName
        sql_contract_summary_json = $sqlContractSummaryFile.FullName
        binding_summary_json = $bindingSummaryFile.FullName
        candidate_csv = $candidateCsv
        selection_csv = $selectionCsv
        selection_json = $selectionJson
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $status -Payload $summary
    Emit-LocalSignal -SignalName $SelectedAdapterSignal -SignalValue $selectedAdapter -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $ReadinessSignal -SignalValue $readiness -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $ReviewRequiredSignal -SignalValue $reviewRequired -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: VOD apply adapter selection planned. status=$status disposition=$disposition selected_adapter=$selectedAdapter readiness=$readiness db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: candidate_csv=$candidateCsv selection_csv=$selectionCsv selection_json=$selectionJson summary_json=$summaryJson"
        Import-Csv $selectionCsv | Format-List
        "`nADAPTER CANDIDATES:"
        Import-Csv $candidateCsv | Format-Table -AutoSize
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

    Write-Error "FAILED: VOD apply adapter selection planner failed. $message run_id=$RunId"
    exit 1
}
