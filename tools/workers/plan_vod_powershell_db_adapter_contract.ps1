<#
.SYNOPSIS
  Plan the governed PowerShell DB adapter contract for VOD apply.

.DESCRIPTION
  Read-only contract planner.

  This worker consumes:
    - latest VOD apply adapter selection summary
    - latest VOD apply DB schema contract summary
    - latest PowerShell DB connection path inventory summary

  It emits the contract for a future small governed PowerShell DB adapter:
    - allowed modes
    - required inputs
    - schema validation sequence
    - dry-run behavior
    - apply behavior gates
    - forbidden operations
    - logging/signal requirements

  It does not connect to the database.
  It does not read from the database.
  It does not write to the database.
  It does not call providers.
  It does not mutate snapshots.

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

$WorkerName = "plan_vod_powershell_db_adapter_contract"
$Component = "vod_powershell_db_adapter_contract"
$DatabaseTarget = "xpdgxfsp_content"
$SourceName = "vod_apply_adapter_selection"
$KillSwitchName = "ENABLE_VOD_POWERSHELL_DB_ADAPTER_CONTRACT_PLANNER"

$CompletedSignal = "vod_powershell_db_adapter_contract_planned_completed"
$AdapterNameSignal = "vod_powershell_db_adapter_contract_adapter_name"
$ReadinessSignal = "vod_powershell_db_adapter_contract_readiness"
$DbWriteAllowedSignal = "vod_powershell_db_adapter_contract_db_write_allowed"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\vod_powershell_db_adapter_contract"
$LogRoot = Join-Path $RepoRoot "runtime\logs\vod_powershell_db_adapter_contract"

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
            db_reads = $false
            db_writes = $false
            provider_calls = $false
            run_id = $RunId
        }

        Emit-LocalSignal -SignalName $CompletedSignal -SignalValue "disabled" -Payload $summary
        Write-LocalJsonLog -EventName "job_completed" -Status "disabled" -Data $summary
        Write-Output "SKIPPED: $KillSwitchName is disabled. run_id=$RunId"
        exit 0
    }

    $adapterSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_apply_adapter_selection") -Filter "vod_apply_adapter_selection_summary_*.json"
    $schemaSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_apply_db_schema_contract") -Filter "vod_apply_db_schema_contract_summary_*.json"
    $connectionInventorySummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\powershell_db_connection_path_inventory") -Filter "powershell_db_connection_path_inventory_summary_*.json"

    if ($null -eq $adapterSummaryFile) {
        throw "VOD apply adapter selection summary not found. Run plan_vod_apply_adapter_selection.ps1 first."
    }

    if ($null -eq $schemaSummaryFile) {
        throw "VOD apply DB schema contract summary not found. Run test_vod_apply_db_schema_contract.ps1 first."
    }

    if ($null -eq $connectionInventorySummaryFile) {
        throw "PowerShell DB connection inventory summary not found. Run inventory_powershell_db_connection_paths.ps1 first."
    }

    $adapterSummary = Read-JsonFile -Path $adapterSummaryFile.FullName
    $schemaSummary = Read-JsonFile -Path $schemaSummaryFile.FullName
    $connectionInventorySummary = Read-JsonFile -Path $connectionInventorySummaryFile.FullName

    $selectedAdapter = Get-Text -Object $adapterSummary -Name "selected_adapter" -Default "unknown"
    $adapterReadiness = Get-Text -Object $adapterSummary -Name "readiness" -Default "unknown"
    $targetTable = Get-Text -Object $schemaSummary -Name "target_table" -Default "unknown"
    $schemaReadiness = Get-Text -Object $schemaSummary -Name "schema_readiness" -Default "unknown"
    $requiredUniqueKey = Get-Text -Object $schemaSummary -Name "required_unique_key" -Default ""
    $connectionCandidateCount = Get-IntValue -Object $connectionInventorySummary -Name "candidate_count" -Default 0
    $connectionHighConfidenceCount = Get-IntValue -Object $connectionInventorySummary -Name "high_confidence_count" -Default 0
    $connectionSelectedHint = Get-Text -Object $connectionInventorySummary -Name "selected_hint" -Default "manual_review"

    $adapterName = "Invoke-MiraDbQuerySafe"
    $adapterModulePath = "tools\common\MiraDbSafeAdapter.psm1"
    $firstConsumerWorker = "tools\workers\apply_vod_streams_delta_limited.ps1"
    $readiness = "adapter_contract_planned_implementation_needed"
    $dbWriteAllowed = $false

    $blockedReasons = @()

    if ($selectedAdapter -ne "new_safe_powershell_db_adapter") {
        $blockedReasons += "selected_adapter_not_new_safe_powershell_db_adapter"
    }

    if ($adapterReadiness -ne "adapter_selected_schema_validation_needed") {
        $blockedReasons += "adapter_readiness_not_schema_validation_needed"
    }

    if ($targetTable -ne "xpdgxfsp_content.vod") {
        $blockedReasons += "target_table_not_xpdgxfsp_content_vod"
    }

    if ($schemaReadiness -ne "schema_contract_planned_db_validation_needed") {
        $blockedReasons += "schema_readiness_not_validation_needed"
    }

    if ($requiredUniqueKey -ne "mac_user_id|provider_label|provider_stream_id") {
        $blockedReasons += "required_unique_key_mismatch"
    }

    if ($connectionHighConfidenceCount -gt 0) {
        $blockedReasons += "existing_high_confidence_db_adapter_requires_review_before_new_adapter"
    }

    $contractRows = @(
        [pscustomobject][ordered]@{
            contract_area = "adapter_name"
            requirement = $adapterName
            enforcement = "module function"
            required_before_apply = $true
            db_reads_now = $false
            db_writes_now = $false
        },
        [pscustomobject][ordered]@{
            contract_area = "module_path"
            requirement = $adapterModulePath
            enforcement = "single reusable helper"
            required_before_apply = $true
            db_reads_now = $false
            db_writes_now = $false
        },
        [pscustomobject][ordered]@{
            contract_area = "allowed_modes"
            requirement = "schema_check|dry_run|apply"
            enforcement = "mandatory Mode parameter"
            required_before_apply = $true
            db_reads_now = $false
            db_writes_now = $false
        },
        [pscustomobject][ordered]@{
            contract_area = "default_mode"
            requirement = "dry_run"
            enforcement = "Apply must be explicit"
            required_before_apply = $true
            db_reads_now = $false
            db_writes_now = $false
        },
        [pscustomobject][ordered]@{
            contract_area = "schema_validation"
            requirement = "validate target table, required columns, and unique key before apply"
            enforcement = "schema_check mode must pass"
            required_before_apply = $true
            db_reads_now = $false
            db_writes_now = $false
        },
        [pscustomobject][ordered]@{
            contract_area = "authorization"
            requirement = "real selector candidate_found=True selected_lane=vod_streams next_worker=apply_vod_streams_delta_limited.ps1"
            enforcement = "apply worker gate before adapter call"
            required_before_apply = $true
            db_reads_now = $false
            db_writes_now = $false
        },
        [pscustomobject][ordered]@{
            contract_area = "bounded_write"
            requirement = "Limit max 100 rows until promoted"
            enforcement = "adapter refuses unbounded apply"
            required_before_apply = $true
            db_reads_now = $false
            db_writes_now = $false
        },
        [pscustomobject][ordered]@{
            contract_area = "forbidden_sql"
            requirement = "DELETE|DROP|TRUNCATE|ALTER|unbounded UPDATE"
            enforcement = "statement scanner before execute"
            required_before_apply = $true
            db_reads_now = $false
            db_writes_now = $false
        },
        [pscustomobject][ordered]@{
            contract_area = "row_disposition"
            requirement = "each row returns written|dry_run_preview|skipped|rejected|failed"
            enforcement = "row-level result object"
            required_before_apply = $true
            db_reads_now = $false
            db_writes_now = $false
        },
        [pscustomobject][ordered]@{
            contract_area = "credential_handling"
            requirement = "use existing environment/config source; never hardcode secrets"
            enforcement = "adapter parameter/env lookup"
            required_before_apply = $true
            db_reads_now = $false
            db_writes_now = $false
        }
    )

    $modeRows = @(
        [pscustomobject][ordered]@{
            mode = "schema_check"
            db_reads_allowed = $true
            db_writes_allowed = $false
            purpose = "verify table, columns, unique key"
        },
        [pscustomobject][ordered]@{
            mode = "dry_run"
            db_reads_allowed = $false
            db_writes_allowed = $false
            purpose = "bind and preview SQL/parameters only"
        },
        [pscustomobject][ordered]@{
            mode = "apply"
            db_reads_allowed = $true
            db_writes_allowed = $true
            purpose = "future bounded apply only after all gates pass"
        }
    )

    $status = "pass"
    $disposition = "adapter_contract_planned"

    if (@($blockedReasons).Count -gt 0) {
        $status = "warning"
        $disposition = "adapter_contract_planned_with_review_blocks"
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $contractCsv = Join-Path $OutputRoot "vod_powershell_db_adapter_contract_$timestamp.csv"
    $modeCsv = Join-Path $OutputRoot "vod_powershell_db_adapter_contract_modes_$timestamp.csv"
    $contractJson = Join-Path $OutputRoot "vod_powershell_db_adapter_contract_$timestamp.json"
    $summaryJson = Join-Path $OutputRoot "vod_powershell_db_adapter_contract_summary_$timestamp.json"

    $contractRows | Export-Csv -Path $contractCsv -NoTypeInformation
    $modeRows | Export-Csv -Path $modeCsv -NoTypeInformation

    $contract = [ordered]@{
        contract_name = "vod_powershell_db_adapter_contract_v1"
        status = $status
        disposition = $disposition
        adapter_name = $adapterName
        adapter_module_path = $adapterModulePath
        first_consumer_worker = $firstConsumerWorker
        readiness = $readiness
        db_write_allowed = $dbWriteAllowed
        selected_adapter = $selectedAdapter
        target_table = $targetTable
        required_unique_key = $requiredUniqueKey
        connection_inventory_candidate_count = $connectionCandidateCount
        connection_inventory_high_confidence_count = $connectionHighConfidenceCount
        connection_inventory_selected_hint = $connectionSelectedHint
        blocked_reasons = $blockedReasons
        db_reads = $false
        db_writes = $false
        provider_calls = $false
    }

    $contract | ConvertTo-Json -Depth 20 | Set-Content -Path $contractJson -Encoding UTF8

    $summary = [ordered]@{
        status = $status
        disposition = $disposition
        db_reads = $false
        db_writes = $false
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        adapter_name = $adapterName
        adapter_module_path = $adapterModulePath
        first_consumer_worker = $firstConsumerWorker
        readiness = $readiness
        db_write_allowed = $dbWriteAllowed
        selected_adapter = $selectedAdapter
        target_table = $targetTable
        required_unique_key = $requiredUniqueKey
        connection_inventory_candidate_count = $connectionCandidateCount
        connection_inventory_high_confidence_count = $connectionHighConfidenceCount
        connection_inventory_selected_hint = $connectionSelectedHint
        blocked_reasons = $blockedReasons
        adapter_summary_json = $adapterSummaryFile.FullName
        schema_summary_json = $schemaSummaryFile.FullName
        connection_inventory_summary_json = $connectionInventorySummaryFile.FullName
        contract_csv = $contractCsv
        mode_csv = $modeCsv
        contract_json = $contractJson
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $status -Payload $summary
    Emit-LocalSignal -SignalName $AdapterNameSignal -SignalValue $adapterName -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $ReadinessSignal -SignalValue $readiness -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $DbWriteAllowedSignal -SignalValue $dbWriteAllowed -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: VOD PowerShell DB adapter contract planned. status=$status disposition=$disposition adapter=$adapterName readiness=$readiness db_reads=False db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: contract_csv=$contractCsv mode_csv=$modeCsv contract_json=$contractJson summary_json=$summaryJson"
        Import-Csv $contractCsv | Format-Table -AutoSize
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

    Write-Error "FAILED: VOD PowerShell DB adapter contract planner failed. $message run_id=$RunId"
    exit 1
}
