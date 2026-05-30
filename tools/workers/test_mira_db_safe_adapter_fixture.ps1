<#
.SYNOPSIS
  Test the Mira DB safe adapter skeleton with fixture input.

.DESCRIPTION
  Fixture-only test worker for tools/common/MiraDbSafeAdapter.psm1.

  Validates:
    - dry-run preview passes
    - unsafe SQL is blocked
    - missing required parameters are blocked
    - apply mode is refused
    - schema_check mode is refused unless later promoted

  No DB connections.
  No DB reads.
  No DB writes.
  No provider calls.

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

$WorkerName = "test_mira_db_safe_adapter_fixture"
$Component = "mira_db_safe_adapter_fixture"
$DatabaseTarget = "none"
$SourceName = "tools_common_mira_db_safe_adapter"
$KillSwitchName = "ENABLE_MIRA_DB_SAFE_ADAPTER_FIXTURE_TEST"

$CompletedSignal = "mira_db_safe_adapter_fixture_test_completed"
$DispositionSignal = "mira_db_safe_adapter_fixture_test_disposition"
$PassCountSignal = "mira_db_safe_adapter_fixture_test_pass_count"
$BlockedCountSignal = "mira_db_safe_adapter_fixture_test_blocked_count"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\mira_db_safe_adapter_fixture"
$LogRoot = Join-Path $RepoRoot "runtime\logs\mira_db_safe_adapter_fixture"
$ModulePath = Join-Path $RepoRoot "tools\common\MiraDbSafeAdapter.psm1"

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

try {
    Write-LocalJsonLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        fixture_only = $true
        db_reads = $false
        db_writes = $false
        provider_calls = $false
        module_path = $ModulePath
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

    if (-not (Test-Path -LiteralPath $ModulePath)) {
        throw "Required module not found: $ModulePath"
    }

    Import-Module $ModulePath -Force

    $safeSql = @"
INSERT INTO xpdgxfsp_content.vod (
    mac_user_id,
    provider_label,
    provider_stream_id,
    provider_category_id,
    name,
    updated_at
)
VALUES (
    :mac_user_id,
    :provider_label,
    :provider_stream_id,
    :provider_category_id,
    :title_raw,
    NOW()
)
ON DUPLICATE KEY UPDATE
    name = COALESCE(NULLIF(VALUES(name), ''), name),
    updated_at = NOW();
"@

    $parameters = @{
        mac_user_id = 6
        provider_label = "eldervpn"
        provider_stream_id = "999001"
        provider_category_id = "120"
        title_raw = "EN| Fixture Movie Example"
    }

    $required = @(
        "mac_user_id",
        "provider_label",
        "provider_stream_id",
        "provider_category_id",
        "title_raw"
    )

    $tests = @()

    $tests += [pscustomobject][ordered]@{
        test_name = "dry_run_safe_sql"
        result = Invoke-MiraDbQuerySafe -Mode "dry_run" -Sql $safeSql -Parameters $parameters -RequiredParameterNames $required -Limit 25
        expected_status = "pass"
        expected_disposition = "dry_run_preview"
    }

    $tests += [pscustomobject][ordered]@{
        test_name = "unsafe_sql_blocked"
        result = Invoke-MiraDbQuerySafe -Mode "dry_run" -Sql "DROP TABLE xpdgxfsp_content.vod;" -Parameters $parameters -RequiredParameterNames $required
        expected_status = "blocked"
        expected_disposition = "blocked_unsafe_sql"
    }

    $missingParams = @{
        mac_user_id = 6
        provider_label = "eldervpn"
        provider_category_id = "120"
        title_raw = "EN| Missing Stream ID"
    }

    $tests += [pscustomobject][ordered]@{
        test_name = "missing_required_parameter_blocked"
        result = Invoke-MiraDbQuerySafe -Mode "dry_run" -Sql $safeSql -Parameters $missingParams -RequiredParameterNames $required
        expected_status = "blocked"
        expected_disposition = "blocked_missing_required_parameters"
    }

    $tests += [pscustomobject][ordered]@{
        test_name = "apply_mode_refused"
        result = Invoke-MiraDbQuerySafe -Mode "apply" -Sql $safeSql -Parameters $parameters -RequiredParameterNames $required
        expected_status = "blocked"
        expected_disposition = "blocked_apply_requires_explicit_db_write"
    }

    $tests += [pscustomobject][ordered]@{
        test_name = "schema_check_refused_without_db_read"
        result = Invoke-MiraDbQuerySafe -Mode "schema_check" -Sql "SHOW COLUMNS FROM xpdgxfsp_content.vod;" -Parameters @{} -RequiredParameterNames @()
        expected_status = "blocked"
        expected_disposition = "blocked_schema_check_requires_explicit_db_read"
    }

    $resultRows = @()
    foreach ($test in $tests) {
        $actualStatus = [string]$test.result.status
        $actualDisposition = [string]$test.result.disposition
        $passed = ($actualStatus -eq $test.expected_status -and $actualDisposition -eq $test.expected_disposition)

        $resultRows += [pscustomobject][ordered]@{
            test_name = $test.test_name
            passed = $passed
            expected_status = $test.expected_status
            actual_status = $actualStatus
            expected_disposition = $test.expected_disposition
            actual_disposition = $actualDisposition
            db_reads = [bool]$test.result.db_reads
            db_writes = [bool]$test.result.db_writes
            provider_calls = [bool]$test.result.provider_calls
        }
    }

    $passCount = @($resultRows | Where-Object { $_.passed -eq $true }).Count
    $failCount = @($resultRows | Where-Object { $_.passed -ne $true }).Count
    $blockedCount = @($resultRows | Where-Object { $_.actual_status -eq "blocked" }).Count

    $status = "pass"
    $disposition = "adapter_fixture_passed"
    if ($failCount -gt 0) {
        $status = "fail"
        $disposition = "adapter_fixture_failed"
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $reportCsv = Join-Path $OutputRoot "mira_db_safe_adapter_fixture_$timestamp.csv"
    $reportJson = Join-Path $OutputRoot "mira_db_safe_adapter_fixture_$timestamp.json"
    $summaryJson = Join-Path $OutputRoot "mira_db_safe_adapter_fixture_summary_$timestamp.json"

    $resultRows | Export-Csv -Path $reportCsv -NoTypeInformation
    $resultRows | ConvertTo-Json -Depth 20 | Set-Content -Path $reportJson -Encoding UTF8

    $summary = [ordered]@{
        status = $status
        disposition = $disposition
        fixture_only = $true
        db_reads = $false
        db_writes = $false
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        module_path = $ModulePath
        total_tests = @($resultRows).Count
        pass_count = $passCount
        fail_count = $failCount
        blocked_count = $blockedCount
        report_csv = $reportCsv
        report_json = $reportJson
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $status -Payload $summary
    Emit-LocalSignal -SignalName $DispositionSignal -SignalValue $disposition -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $PassCountSignal -SignalValue $passCount -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $BlockedCountSignal -SignalValue $blockedCount -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: Mira DB safe adapter fixture completed. status=$status disposition=$disposition pass=$passCount fail=$failCount blocked=$blockedCount db_reads=False db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: report_csv=$reportCsv report_json=$reportJson summary_json=$summaryJson"
        $resultRows | Format-Table -AutoSize
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

    Write-Error "FAILED: Mira DB safe adapter fixture failed. $message run_id=$RunId"
    exit 1
}
