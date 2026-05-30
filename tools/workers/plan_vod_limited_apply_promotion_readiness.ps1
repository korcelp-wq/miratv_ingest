<#
.SYNOPSIS
  Plan VOD limited apply promotion readiness.

.DESCRIPTION
  Read-only promotion readiness gate.

  This worker reviews the governed VOD apply path and reports whether the system is
  ready to promote from dry-run adapter preview to any DB read/write capability.

  It intentionally does not connect to DB, does not read DB, does not write DB, and
  does not call providers.

  Expected current result:
    apply_ready = false
    disposition = promotion_blocked
    blockers include no real candidate and schema/db adapter not promoted

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

$WorkerName = "plan_vod_limited_apply_promotion_readiness"
$Component = "vod_limited_apply_promotion_readiness"
$DatabaseTarget = "xpdgxfsp_content"
$SourceName = "apply_vod_streams_delta_limited"
$KillSwitchName = "ENABLE_VOD_LIMITED_APPLY_PROMOTION_READINESS_PLANNER"

$CompletedSignal = "vod_limited_apply_promotion_readiness_completed"
$DispositionSignal = "vod_limited_apply_promotion_readiness_disposition"
$ApplyReadySignal = "vod_limited_apply_promotion_readiness_apply_ready"
$BlockerCountSignal = "vod_limited_apply_promotion_readiness_blocker_count"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\vod_limited_apply_promotion_readiness"
$LogRoot = Join-Path $RepoRoot "runtime\logs\vod_limited_apply_promotion_readiness"

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
        db_reads = $false
        db_writes = $false
        provider_calls = $false
    })

    Emit-LocalHeartbeat -Status "running"

    if (-not (Test-WorkerKillSwitch)) {
        $summary = [ordered]@{
            status = "disabled"
            disposition = "disabled_by_kill_switch"
            apply_ready = $false
            db_reads = $false
            db_writes = $false
            provider_calls = $false
            run_id = $RunId
        }

        Emit-LocalSignal -SignalName $CompletedSignal -SignalValue "disabled" -Payload $summary
        Emit-LocalSignal -SignalName $DispositionSignal -SignalValue "disabled_by_kill_switch" -Payload ([ordered]@{ run_id = $RunId })
        Write-LocalJsonLog -EventName "job_completed" -Status "disabled" -Data $summary
        Write-Output "SKIPPED: $KillSwitchName is disabled. run_id=$RunId"
        exit 0
    }

    $applySummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_streams_delta_limited_apply") -Filter "vod_streams_delta_limited_apply_summary_*.json"
    $decisionSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\provider_snapshot_import_decision_gate") -Filter "provider_snapshot_import_decision_gate_summary_*.json"
    $governedSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\provider_snapshot_governed_import_runner") -Filter "provider_snapshot_governed_import_runner_summary_*.json"
    $adapterFixtureSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\mira_db_safe_adapter_fixture") -Filter "mira_db_safe_adapter_fixture_summary_*.json"
    $adapterIntegrationSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_apply_safe_adapter_integration_fixture") -Filter "vod_apply_safe_adapter_integration_fixture_summary_*.json"
    $schemaSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_apply_db_schema_contract") -Filter "vod_apply_db_schema_contract_summary_*.json"
    $schemaLiveReadSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_apply_db_schema_live_read") -Filter "vod_apply_db_schema_live_read_summary_*.json"

    $applySummary = Read-JsonFile -Path $(if ($applySummaryFile) { $applySummaryFile.FullName } else { "" })
    $decisionSummary = Read-JsonFile -Path $(if ($decisionSummaryFile) { $decisionSummaryFile.FullName } else { "" })
    $governedSummary = Read-JsonFile -Path $(if ($governedSummaryFile) { $governedSummaryFile.FullName } else { "" })
    $adapterFixtureSummary = Read-JsonFile -Path $(if ($adapterFixtureSummaryFile) { $adapterFixtureSummaryFile.FullName } else { "" })
    $adapterIntegrationSummary = Read-JsonFile -Path $(if ($adapterIntegrationSummaryFile) { $adapterIntegrationSummaryFile.FullName } else { "" })
    $schemaSummary = Read-JsonFile -Path $(if ($schemaSummaryFile) { $schemaSummaryFile.FullName } else { "" })
    $schemaLiveReadSummary = Read-JsonFile -Path $(if ($schemaLiveReadSummaryFile) { $schemaLiveReadSummaryFile.FullName } else { "" })

    $blockers = @()
    $passedChecks = @()

    $applyDisposition = Get-Text -Object $applySummary -Name "disposition" -Default "missing"
    $applyDbWrites = Get-Bool -Object $applySummary -Name "db_writes" -Default $false
    $applyActualWriteCount = Get-IntValue -Object $applySummary -Name "actual_write_count" -Default 0
    $applyCandidateFound = Get-Bool -Object $applySummary -Name "candidate_found" -Default $false
    $applyDryRunAdapterCount = Get-IntValue -Object $applySummary -Name "dry_run_adapter_count" -Default 0

    if ($applySummaryFile) { $passedChecks += "apply_summary_present" } else { $blockers += "apply_summary_missing" }
    if (-not $applyDbWrites -and $applyActualWriteCount -eq 0) { $passedChecks += "apply_worker_no_db_writes" } else { $blockers += "apply_worker_wrote_db_unexpected" }
    if ($applyCandidateFound) { $passedChecks += "real_candidate_seen" } else { $blockers += "no_real_vod_candidate_yet" }
    if ($applyDisposition -eq "dry_run_adapter_preview_completed") { $passedChecks += "apply_adapter_dry_run_path_exercised_by_real_candidate" } else { $blockers += "real_apply_adapter_path_not_exercised_current_selector_is_$applyDisposition" }

    $decisionDisposition = Get-Text -Object $decisionSummary -Name "disposition" -Default "missing"
    $decisionDbWrites = Get-Bool -Object $decisionSummary -Name "db_writes" -Default $false

    if ($decisionSummaryFile) { $passedChecks += "decision_summary_present" } else { $blockers += "decision_summary_missing" }
    if (-not $decisionDbWrites) { $passedChecks += "decision_gate_no_db_writes" } else { $blockers += "decision_gate_wrote_db_unexpected" }
    if ($decisionDisposition -eq "noop_ready" -or $decisionDisposition -eq "dry_run_adapter_preview_completed") { $passedChecks += "decision_disposition_safe" } else { $blockers += "decision_disposition_unexpected_$decisionDisposition" }

    $governedDisposition = Get-Text -Object $governedSummary -Name "disposition" -Default "missing"
    $governedDbWrites = Get-Bool -Object $governedSummary -Name "db_writes" -Default $false

    if ($governedSummaryFile) { $passedChecks += "governed_runner_summary_present" } else { $blockers += "governed_runner_summary_missing" }
    if (-not $governedDbWrites) { $passedChecks += "governed_runner_no_db_writes" } else { $blockers += "governed_runner_wrote_db_unexpected" }
    if ($governedDisposition -eq "noop_ready" -or $governedDisposition -eq "dry_run_adapter_preview_completed") { $passedChecks += "governed_runner_disposition_safe" } else { $blockers += "governed_runner_disposition_unexpected_$governedDisposition" }

    $adapterFixtureStatus = Get-Text -Object $adapterFixtureSummary -Name "status" -Default "missing"
    $adapterFixtureFailCount = Get-IntValue -Object $adapterFixtureSummary -Name "fail_count" -Default 999

    if ($adapterFixtureStatus -eq "pass" -and $adapterFixtureFailCount -eq 0) { $passedChecks += "adapter_fixture_passed" } else { $blockers += "adapter_fixture_not_green" }

    $integrationStatus = Get-Text -Object $adapterIntegrationSummary -Name "status" -Default "missing"
    $integrationUnexpectedWriteCount = Get-IntValue -Object $adapterIntegrationSummary -Name "unexpected_write_count" -Default 999
    $integrationDryRunCount = Get-IntValue -Object $adapterIntegrationSummary -Name "dry_run_count" -Default 0

    if ($integrationStatus -eq "pass" -and $integrationUnexpectedWriteCount -eq 0) { $passedChecks += "adapter_integration_fixture_passed" } else { $blockers += "adapter_integration_fixture_not_green" }
    if ($integrationDryRunCount -gt 0) { $passedChecks += "fixture_adapter_dry_run_proven" } else { $blockers += "fixture_adapter_dry_run_not_proven" }

    $schemaReadiness = Get-Text -Object $schemaSummary -Name "schema_readiness" -Default "missing"
    if ($schemaReadiness -eq "schema_contract_planned_db_validation_needed") { $passedChecks += "schema_contract_planned" } else { $blockers += "schema_contract_missing_or_unexpected" }

    $schemaLiveDisposition = Get-Text -Object $schemaLiveReadSummary -Name "disposition" -Default "missing"
    $schemaLiveValid = Get-Bool -Object $schemaLiveReadSummary -Name "schema_valid" -Default $false
    $schemaLiveDbReads = Get-Bool -Object $schemaLiveReadSummary -Name "db_reads" -Default $false
    $schemaLiveDbWrites = Get-Bool -Object $schemaLiveReadSummary -Name "db_writes" -Default $true
    $schemaLiveProviderCalls = Get-Bool -Object $schemaLiveReadSummary -Name "provider_calls" -Default $true
    $schemaLiveKeyFound = Get-Bool -Object $schemaLiveReadSummary -Name "key_found" -Default $false

    if (
        $schemaLiveReadSummaryFile -and
        $schemaLiveDisposition -eq "schema_live_read_validated" -and
        $schemaLiveValid -and
        $schemaLiveDbReads -and
        -not $schemaLiveDbWrites -and
        -not $schemaLiveProviderCalls -and
        $schemaLiveKeyFound
    ) {
        $passedChecks += "schema_live_read_validated"
    }
    else {
        $blockers += "db_schema_validation_not_executed"
    }

    $blockers += "safe_adapter_schema_check_not_promoted"
    $blockers += "safe_adapter_apply_mode_not_implemented"
    $blockers += "no_real_db_write_authorization_gate_enabled"

    $applyReady = $false
    $disposition = "promotion_blocked"
    $status = "warning"

    if (@($blockers).Count -eq 0) {
        $applyReady = $true
        $disposition = "promotion_ready"
        $status = "pass"
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $reportCsv = Join-Path $OutputRoot "vod_limited_apply_promotion_readiness_$timestamp.csv"
    $reportJson = Join-Path $OutputRoot "vod_limited_apply_promotion_readiness_$timestamp.json"
    $summaryJson = Join-Path $OutputRoot "vod_limited_apply_promotion_readiness_summary_$timestamp.json"

    $row = [pscustomobject][ordered]@{
        disposition = $disposition
        apply_ready = $applyReady
        blocker_count = @($blockers).Count
        passed_check_count = @($passedChecks).Count
        apply_disposition = $applyDisposition
        decision_disposition = $decisionDisposition
        governed_disposition = $governedDisposition
        apply_dry_run_adapter_count = $applyDryRunAdapterCount
        db_reads = $false
        db_writes = $false
        provider_calls = $false
        blockers = ($blockers -join "|")
        passed_checks = ($passedChecks -join "|")
    }

    $row | Export-Csv -Path $reportCsv -NoTypeInformation
    $row | ConvertTo-Json -Depth 20 | Set-Content -Path $reportJson -Encoding UTF8

    $summary = [ordered]@{
        status = $status
        disposition = $disposition
        apply_ready = $applyReady
        blocker_count = @($blockers).Count
        passed_check_count = @($passedChecks).Count
        db_reads = $false
        db_writes = $false
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        blockers = $blockers
        passed_checks = $passedChecks
        apply_summary_json = $(if ($applySummaryFile) { $applySummaryFile.FullName } else { "" })
        decision_summary_json = $(if ($decisionSummaryFile) { $decisionSummaryFile.FullName } else { "" })
        governed_summary_json = $(if ($governedSummaryFile) { $governedSummaryFile.FullName } else { "" })
        adapter_fixture_summary_json = $(if ($adapterFixtureSummaryFile) { $adapterFixtureSummaryFile.FullName } else { "" })
        adapter_integration_summary_json = $(if ($adapterIntegrationSummaryFile) { $adapterIntegrationSummaryFile.FullName } else { "" })
        schema_summary_json = $(if ($schemaSummaryFile) { $schemaSummaryFile.FullName } else { "" })
        schema_live_read_summary_json = $(if ($schemaLiveReadSummaryFile) { $schemaLiveReadSummaryFile.FullName } else { "" })
        report_csv = $reportCsv
        report_json = $reportJson
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $status -Payload $summary
    Emit-LocalSignal -SignalName $DispositionSignal -SignalValue $disposition -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $ApplyReadySignal -SignalValue $applyReady -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $BlockerCountSignal -SignalValue @($blockers).Count -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: VOD limited apply promotion readiness planned. status=$status disposition=$disposition apply_ready=$applyReady blockers=$(@($blockers).Count) db_reads=False db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: report_csv=$reportCsv report_json=$reportJson summary_json=$summaryJson"
        Import-Csv $reportCsv | Format-List
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

    Write-Error "FAILED: VOD limited apply promotion readiness failed. $message run_id=$RunId"
    exit 1
}

