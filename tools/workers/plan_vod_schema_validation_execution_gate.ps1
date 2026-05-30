<#
.SYNOPSIS
  Plan VOD schema validation execution gate.

.DESCRIPTION
  Read-only planner for the next promoted DB-read-only schema validation step.

  This worker consumes:
    - latest VOD apply DB schema contract summary
    - latest VOD limited apply promotion readiness summary
    - latest VOD PowerShell DB adapter contract summary

  It produces the exact guarded command plan for a future schema_check execution:
    - DB reads only
    - DB writes forbidden
    - provider calls forbidden
    - must use MiraDbSafeAdapter schema_check mode
    - must require explicit AllowDbRead
    - must not enable apply mode

  This worker does not connect to the database.
  This worker does not read from the database.
  This worker does not write to the database.
  This worker does not call providers.
  This worker does not mutate snapshots.

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

$WorkerName = "plan_vod_schema_validation_execution_gate"
$Component = "vod_schema_validation_execution_gate"
$DatabaseTarget = "xpdgxfsp_content"
$SourceName = "vod_apply_db_schema_contract"
$KillSwitchName = "ENABLE_VOD_SCHEMA_VALIDATION_EXECUTION_GATE_PLANNER"

$CompletedSignal = "vod_schema_validation_execution_gate_planned_completed"
$DispositionSignal = "vod_schema_validation_execution_gate_disposition"
$DbReadAllowedSignal = "vod_schema_validation_execution_gate_db_read_allowed"
$DbWriteAllowedSignal = "vod_schema_validation_execution_gate_db_write_allowed"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\vod_schema_validation_execution_gate"
$LogRoot = Join-Path $RepoRoot "runtime\logs\vod_schema_validation_execution_gate"

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
        db_reads = $false
        db_writes = $false
        provider_calls = $false
    })

    Emit-LocalHeartbeat -Status "running"

    if (-not (Test-WorkerKillSwitch)) {
        $summary = [ordered]@{
            status = "disabled"
            disposition = "disabled_by_kill_switch"
            db_read_allowed_for_future_step = $false
            db_write_allowed = $false
            provider_calls = $false
            run_id = $RunId
        }

        Emit-LocalSignal -SignalName $CompletedSignal -SignalValue "disabled" -Payload $summary
        Emit-LocalSignal -SignalName $DispositionSignal -SignalValue "disabled_by_kill_switch" -Payload ([ordered]@{ run_id = $RunId })
        Write-LocalJsonLog -EventName "job_completed" -Status "disabled" -Data $summary
        Write-Output "SKIPPED: $KillSwitchName is disabled. run_id=$RunId"
        exit 0
    }

    $schemaSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_apply_db_schema_contract") -Filter "vod_apply_db_schema_contract_summary_*.json"
    $promotionSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_limited_apply_promotion_readiness") -Filter "vod_limited_apply_promotion_readiness_summary_*.json"
    $adapterContractSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_powershell_db_adapter_contract") -Filter "vod_powershell_db_adapter_contract_summary_*.json"

    if ($null -eq $schemaSummaryFile) {
        throw "Schema contract summary not found. Run test_vod_apply_db_schema_contract.ps1 first."
    }

    if ($null -eq $promotionSummaryFile) {
        throw "Promotion readiness summary not found. Run plan_vod_limited_apply_promotion_readiness.ps1 first."
    }

    if ($null -eq $adapterContractSummaryFile) {
        throw "Adapter contract summary not found. Run plan_vod_powershell_db_adapter_contract.ps1 first."
    }

    $schemaSummary = Read-JsonFile -Path $schemaSummaryFile.FullName
    $promotionSummary = Read-JsonFile -Path $promotionSummaryFile.FullName
    $adapterContractSummary = Read-JsonFile -Path $adapterContractSummaryFile.FullName

    $targetTable = Get-Text -Object $schemaSummary -Name "target_table" -Default "unknown"
    $schemaReadiness = Get-Text -Object $schemaSummary -Name "schema_readiness" -Default "unknown"
    $requiredUniqueKey = Get-Text -Object $schemaSummary -Name "required_unique_key" -Default ""
    $validationQueriesJson = Get-Text -Object $schemaSummary -Name "validation_queries_json" -Default ""
    if ([string]::IsNullOrWhiteSpace($validationQueriesJson)) {
        $validationQueriesJson = Get-Text -Object $schemaSummary -Name "validation_queries_file" -Default ""
    }

    $promotionApplyReady = Get-Bool -Object $promotionSummary -Name "apply_ready" -Default $false
    $promotionDisposition = Get-Text -Object $promotionSummary -Name "disposition" -Default "unknown"

    $adapterName = Get-Text -Object $adapterContractSummary -Name "adapter_name" -Default "Invoke-MiraDbQuerySafe"
    $adapterModulePath = Get-Text -Object $adapterContractSummary -Name "adapter_module_path" -Default "tools\common\MiraDbSafeAdapter.psm1"

    $dbReadAllowedForFutureStep = $true
    $dbWriteAllowed = $false
    $providerCallsAllowed = $false

    $blockers = @()
    $passedChecks = @()

    if ($targetTable -eq "xpdgxfsp_content.vod") { $passedChecks += "target_table_contract_present" } else { $blockers += "target_table_unexpected_$targetTable" }
    if ($schemaReadiness -eq "schema_contract_planned_db_validation_needed") { $passedChecks += "schema_contract_ready_for_validation" } else { $blockers += "schema_contract_not_ready_$schemaReadiness" }
    if ($requiredUniqueKey -eq "mac_user_id|provider_label|provider_stream_id") { $passedChecks += "required_unique_key_contract_present" } else { $blockers += "required_unique_key_unexpected" }
    if (-not [string]::IsNullOrWhiteSpace($validationQueriesJson)) { $passedChecks += "validation_query_template_present" } else { $blockers += "validation_query_template_missing" }
    if ($adapterName -eq "Invoke-MiraDbQuerySafe") { $passedChecks += "safe_adapter_contract_present" } else { $blockers += "safe_adapter_contract_missing" }
    if (-not $promotionApplyReady -and $promotionDisposition -eq "promotion_blocked") { $passedChecks += "apply_promotion_remains_blocked" } else { $blockers += "apply_promotion_not_blocked_unexpected" }

    $executionPlanRows = @(
        [pscustomobject][ordered]@{
            step_order = 1
            step_name = "load_safe_adapter_module"
            mode = "schema_check"
            db_reads_allowed = $false
            db_writes_allowed = $false
            command_or_query = "Import-Module $adapterModulePath -Force"
            purpose = "load adapter only"
        },
        [pscustomobject][ordered]@{
            step_order = 2
            step_name = "schema_columns_check"
            mode = "schema_check"
            db_reads_allowed = $true
            db_writes_allowed = $false
            command_or_query = "SHOW COLUMNS FROM xpdgxfsp_content.vod;"
            purpose = "verify required columns"
        },
        [pscustomobject][ordered]@{
            step_order = 3
            step_name = "schema_indexes_check"
            mode = "schema_check"
            db_reads_allowed = $true
            db_writes_allowed = $false
            command_or_query = "SHOW INDEX FROM xpdgxfsp_content.vod;"
            purpose = "verify required unique key or equivalent index"
        },
        [pscustomobject][ordered]@{
            step_order = 4
            step_name = "write_mode_remains_disabled"
            mode = "schema_check"
            db_reads_allowed = $false
            db_writes_allowed = $false
            command_or_query = "Do not run apply mode"
            purpose = "preserve no-write boundary"
        }
    )

    $status = "pass"
    $disposition = "schema_validation_execution_gate_planned"
    if (@($blockers).Count -gt 0) {
        $status = "warning"
        $disposition = "schema_validation_execution_gate_planned_with_blocks"
        $dbReadAllowedForFutureStep = $false
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $planCsv = Join-Path $OutputRoot "vod_schema_validation_execution_gate_$timestamp.csv"
    $planJson = Join-Path $OutputRoot "vod_schema_validation_execution_gate_$timestamp.json"
    $summaryJson = Join-Path $OutputRoot "vod_schema_validation_execution_gate_summary_$timestamp.json"
    $commandTxt = Join-Path $OutputRoot "vod_schema_validation_execution_gate_command_$timestamp.ps1.txt"

    $executionPlanRows | Export-Csv -Path $planCsv -NoTypeInformation
    $executionPlanRows | ConvertTo-Json -Depth 20 | Set-Content -Path $planJson -Encoding UTF8

    @"
# Future schema validation command plan.
# This file is intentionally a .txt plan, not an executable worker.
# It documents the next DB-read-only promotion step.

cd C:\miraTV_ingest_clean

# Future worker to build:
# tools\workers\test_vod_apply_db_schema_live_read.ps1

# Required constraints:
# - Mode: schema_check
# - AllowDbRead: explicit
# - DB writes: forbidden
# - Provider calls: forbidden
# - Apply mode: forbidden

# Expected validation queries:
SHOW COLUMNS FROM xpdgxfsp_content.vod;
SHOW INDEX FROM xpdgxfsp_content.vod;

# Required key:
mac_user_id|provider_label|provider_stream_id
"@ | Set-Content -Path $commandTxt -Encoding UTF8

    $summary = [ordered]@{
        status = $status
        disposition = $disposition
        db_reads = $false
        db_writes = $false
        provider_calls = $false
        db_read_allowed_for_future_step = $dbReadAllowedForFutureStep
        db_write_allowed = $dbWriteAllowed
        provider_calls_allowed = $providerCallsAllowed
        worker_name = $WorkerName
        run_id = $RunId
        target_table = $targetTable
        required_unique_key = $requiredUniqueKey
        adapter_name = $adapterName
        adapter_module_path = $adapterModulePath
        blockers = $blockers
        passed_checks = $passedChecks
        schema_summary_json = $schemaSummaryFile.FullName
        promotion_summary_json = $promotionSummaryFile.FullName
        adapter_contract_summary_json = $adapterContractSummaryFile.FullName
        plan_csv = $planCsv
        plan_json = $planJson
        command_txt = $commandTxt
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $status -Payload $summary
    Emit-LocalSignal -SignalName $DispositionSignal -SignalValue $disposition -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $DbReadAllowedSignal -SignalValue $dbReadAllowedForFutureStep -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $DbWriteAllowedSignal -SignalValue $dbWriteAllowed -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: VOD schema validation execution gate planned. status=$status disposition=$disposition future_db_read_allowed=$dbReadAllowedForFutureStep db_writes_allowed=False provider_calls_allowed=False run_id=$RunId"
        Write-Output "FILES: plan_csv=$planCsv plan_json=$planJson command_txt=$commandTxt summary_json=$summaryJson"
        Import-Csv $planCsv | Format-Table -AutoSize
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

    Write-Error "FAILED: VOD schema validation execution gate planner failed. $message run_id=$RunId"
    exit 1
}
