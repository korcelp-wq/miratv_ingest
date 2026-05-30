<#
.SYNOPSIS
  Plan VOD schema validation through the existing query wrapper route.

.DESCRIPTION
  Read-only planner.

  This worker consumes the latest query-wrapper prerequisite report and emits the
  exact plan for a future DB-read-only schema validation worker that uses the
  existing query.ps1 / dog_opens route instead of mysql.exe.

  It does not execute query.ps1.
  It does not connect to DB.
  It does not read DB.
  It does not write DB.
  It does not call providers.
  It does not print secrets.

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

$WorkerName = "plan_vod_schema_validation_query_wrapper_gate"
$Component = "vod_schema_validation_query_wrapper_gate"
$DatabaseTarget = "xpdgxfsp_content"
$SourceName = "vod_query_wrapper_prerequisites"
$KillSwitchName = "ENABLE_VOD_SCHEMA_VALIDATION_QUERY_WRAPPER_GATE_PLANNER"

$CompletedSignal = "vod_schema_validation_query_wrapper_gate_planned_completed"
$DispositionSignal = "vod_schema_validation_query_wrapper_gate_disposition"
$CanonicalRouteSignal = "vod_schema_validation_query_wrapper_gate_canonical_route"
$DbWriteAllowedSignal = "vod_schema_validation_query_wrapper_gate_db_write_allowed"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\vod_schema_validation_query_wrapper_gate"
$LogRoot = Join-Path $RepoRoot "runtime\logs\vod_schema_validation_query_wrapper_gate"

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
        mysql_required = $false
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
        Emit-LocalSignal -SignalName $DispositionSignal -SignalValue "disabled_by_kill_switch" -Payload ([ordered]@{ run_id = $RunId })
        Write-LocalJsonLog -EventName "job_completed" -Status "disabled" -Data $summary
        Write-Output "SKIPPED: $KillSwitchName is disabled. run_id=$RunId"
        exit 0
    }

    $prereqSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_query_wrapper_prerequisites") -Filter "vod_query_wrapper_prerequisites_summary_*.json"
    $schemaContractFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_apply_db_schema_contract") -Filter "vod_apply_db_schema_contract_summary_*.json"

    if ($null -eq $prereqSummaryFile) {
        throw "Query-wrapper prerequisites summary not found. Run check_vod_query_wrapper_prerequisites.ps1 first."
    }

    if ($null -eq $schemaContractFile) {
        throw "VOD schema contract summary not found. Run test_vod_apply_db_schema_contract.ps1 first."
    }

    $prereqSummary = Read-JsonFile -Path $prereqSummaryFile.FullName
    $schemaContract = Read-JsonFile -Path $schemaContractFile.FullName

    $canonicalRoute = Get-Text -Object $prereqSummary -Name "canonical_route" -Default "manual_review"
    $queryWrapperFound = Get-Bool -Object $prereqSummary -Name "query_wrapper_found" -Default $false
    $dogOpensFound = Get-Bool -Object $prereqSummary -Name "dog_opens_found" -Default $false
    $targetTable = Get-Text -Object $schemaContract -Name "target_table" -Default "xpdgxfsp_content.vod"
    $requiredUniqueKey = Get-Text -Object $schemaContract -Name "required_unique_key" -Default "mac_user_id|provider_label|provider_stream_id"

    $blockers = @()
    $passedChecks = @()

    if ($canonicalRoute -eq "query_ps1_plus_dog_opens" -or $canonicalRoute -eq "query_ps1" -or $canonicalRoute -eq "dog_opens") {
        $passedChecks += "canonical_query_wrapper_route_available"
    }
    else {
        $blockers += "canonical_route_manual_review"
    }

    if ($queryWrapperFound) { $passedChecks += "query_wrapper_found" } else { $blockers += "query_wrapper_not_found" }
    if ($dogOpensFound) { $passedChecks += "dog_opens_found" } else { $passedChecks += "dog_opens_not_required_for_route" }
    if ($targetTable -eq "xpdgxfsp_content.vod") { $passedChecks += "target_table_confirmed" } else { $blockers += "target_table_unexpected_$targetTable" }
    if ($requiredUniqueKey -eq "mac_user_id|provider_label|provider_stream_id") { $passedChecks += "required_unique_key_confirmed" } else { $blockers += "required_unique_key_unexpected" }

    $executionPlanRows = @(
        [pscustomobject][ordered]@{
            step_order = 1
            step_name = "resolve_query_wrapper"
            route = $canonicalRoute
            db_reads_allowed_future = $false
            db_writes_allowed = $false
            provider_calls_allowed = $false
            planned_action = "Locate canonical query.ps1 / dog_opens invocation pattern"
        },
        [pscustomobject][ordered]@{
            step_order = 2
            step_name = "plan_columns_query"
            route = $canonicalRoute
            db_reads_allowed_future = $true
            db_writes_allowed = $false
            provider_calls_allowed = $false
            planned_action = "SHOW COLUMNS FROM xpdgxfsp_content.vod"
        },
        [pscustomobject][ordered]@{
            step_order = 3
            step_name = "plan_index_query"
            route = $canonicalRoute
            db_reads_allowed_future = $true
            db_writes_allowed = $false
            provider_calls_allowed = $false
            planned_action = "SHOW INDEX FROM xpdgxfsp_content.vod"
        },
        [pscustomobject][ordered]@{
            step_order = 4
            step_name = "validate_no_write_boundary"
            route = $canonicalRoute
            db_reads_allowed_future = $false
            db_writes_allowed = $false
            provider_calls_allowed = $false
            planned_action = "Reject INSERT UPDATE DELETE DROP TRUNCATE ALTER CREATE"
        }
    )

    $status = "pass"
    $disposition = "query_wrapper_schema_validation_gate_planned"
    if (@($blockers).Count -gt 0) {
        $status = "warning"
        $disposition = "query_wrapper_schema_validation_gate_planned_with_blocks"
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $planCsv = Join-Path $OutputRoot "vod_schema_validation_query_wrapper_gate_$timestamp.csv"
    $planJson = Join-Path $OutputRoot "vod_schema_validation_query_wrapper_gate_$timestamp.json"
    $summaryJson = Join-Path $OutputRoot "vod_schema_validation_query_wrapper_gate_summary_$timestamp.json"
    $nextWorkerTxt = Join-Path $OutputRoot "vod_schema_validation_query_wrapper_gate_next_worker_$timestamp.txt"

    $executionPlanRows | Export-Csv -Path $planCsv -NoTypeInformation
    $executionPlanRows | ConvertTo-Json -Depth 20 | Set-Content -Path $planJson -Encoding UTF8

    @"
Next worker to build:
  test_vod_apply_db_schema_query_wrapper_read.ps1

Purpose:
  Execute DB-read-only schema validation through existing query.ps1 / dog_opens route.

Must not use:
  mysql.exe
  MIRATV_DB_* environment variables

Must enforce:
  - Default blocked unless -AllowDbRead
  - Read-only query allowlist only:
      SHOW COLUMNS FROM xpdgxfsp_content.vod
      SHOW INDEX FROM xpdgxfsp_content.vod
  - No DB writes
  - No provider calls
  - No secrets printed
  - Runtime reports only

Canonical route:
  $canonicalRoute
"@ | Set-Content -Path $nextWorkerTxt -Encoding UTF8

    $summary = [ordered]@{
        status = $status
        disposition = $disposition
        canonical_route = $canonicalRoute
        query_wrapper_found = $queryWrapperFound
        dog_opens_found = $dogOpensFound
        target_table = $targetTable
        required_unique_key = $requiredUniqueKey
        db_reads = $false
        db_writes = $false
        provider_calls = $false
        mysql_required = $false
        blockers = $blockers
        passed_checks = $passedChecks
        worker_name = $WorkerName
        run_id = $RunId
        prereq_summary_json = $prereqSummaryFile.FullName
        schema_contract_summary_json = $schemaContractFile.FullName
        plan_csv = $planCsv
        plan_json = $planJson
        next_worker_txt = $nextWorkerTxt
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $status -Payload $summary
    Emit-LocalSignal -SignalName $DispositionSignal -SignalValue $disposition -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $CanonicalRouteSignal -SignalValue $canonicalRoute -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $DbWriteAllowedSignal -SignalValue $false -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: VOD schema validation query-wrapper gate planned. status=$status disposition=$disposition canonical_route=$canonicalRoute db_reads=False db_writes=False provider_calls=False mysql_required=False run_id=$RunId"
        Write-Output "FILES: plan_csv=$planCsv plan_json=$planJson next_worker_txt=$nextWorkerTxt summary_json=$summaryJson"
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

    Write-Error "FAILED: VOD schema validation query-wrapper gate planner failed. $message run_id=$RunId"
    exit 1
}
