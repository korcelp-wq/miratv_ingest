<#
.SYNOPSIS
  Run governed provider snapshot refresh and import preflight gate.

.DESCRIPTION
  Governed no-DB-write runner that executes:
    1. run_provider_snapshot_spine.ps1
    2. run_provider_snapshot_import_preflight_gate.ps1

  This is the controlled end-to-end gate before any future import worker.
  It allows provider calls only through the snapshot spine.
  It does not read or write the database.
  It does not import anything.

.CONTRACT-MARKERS
  Write-JobLog
  Emit-Signal
  Emit-Heartbeat
  Test-KillSwitch
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [int]$MacUserId = 6,
    [string]$ProviderLabel = "",
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "run_provider_snapshot_governed_refresh_gate"
$Component = "provider_snapshot_governed_refresh_gate"
$DatabaseTarget = "none"
$SourceName = "provider_snapshot_spine_and_preflight"
$KillSwitchName = "ENABLE_PROVIDER_SNAPSHOT_GOVERNED_REFRESH_GATE"

$CompletedSignal = "provider_snapshot_governed_refresh_gate_completed"
$PassCountSignal = "provider_snapshot_governed_refresh_gate_pass_count"
$FailCountSignal = "provider_snapshot_governed_refresh_gate_fail_count"
$StepCountSignal = "provider_snapshot_governed_refresh_gate_step_count"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\provider_snapshot_governed_refresh_gate"
$LogRoot = Join-Path $RepoRoot "runtime\logs\provider_snapshot_governed_refresh_gate"

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

function Invoke-GateStep {
    param(
        [int]$Order,
        [string]$Name,
        [string]$RelativePath,
        [string[]]$ExtraArgs = @()
    )

    $stepStarted = Get-Date
    $scriptPath = Join-Path $RepoRoot $RelativePath

    if (-not (Test-Path -LiteralPath $scriptPath)) {
        return [pscustomobject][ordered]@{
            step_order     = $Order
            step_name      = $Name
            path           = $RelativePath
            status         = "fail"
            exit_code      = 9001
            duration_ms    = Get-DurationMs -Start $stepStarted
            provider_calls = $false
            db_writes      = $false
            reason         = "script_missing"
        }
    }

    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $scriptPath,
        "-Environment", $Environment
    )

    if ($null -ne $ExtraArgs -and $ExtraArgs.Count -gt 0) {
        $args += $ExtraArgs
    }

    $output = & pwsh @args 2>&1
    $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    $durationMs = Get-DurationMs -Start $stepStarted
    $status = if ($exitCode -eq 0) { "pass" } else { "fail" }

    $tail = ""
    if ($null -ne $output) {
        $tail = (($output | Select-Object -Last 8) -join " | ")
    }

    return [pscustomobject][ordered]@{
        step_order     = $Order
        step_name      = $Name
        path           = $RelativePath
        status         = $status
        exit_code      = $exitCode
        duration_ms    = $durationMs
        provider_calls = ($Name -eq "run_provider_snapshot_spine")
        db_writes      = $false
        reason         = $tail
    }
}

try {
    Write-LocalJsonLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        preview_only = $true
        db_writes = $false
        provider_calls = $true
        mac_user_id = $MacUserId
        provider_label = $ProviderLabel
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

    $steps = @(
        [pscustomobject]@{
            Order = 1
            Name = "run_provider_snapshot_spine"
            Path = "tools\workers\run_provider_snapshot_spine.ps1"
            ExtraArgs = @("-MacUserId", [string]$MacUserId, "-ProviderLabel", $ProviderLabel)
        },
        [pscustomobject]@{
            Order = 2
            Name = "run_provider_snapshot_import_preflight_gate"
            Path = "tools\workers\run_provider_snapshot_import_preflight_gate.ps1"
            ExtraArgs = @()
        }
    )

    $results = @()

    foreach ($step in $steps) {
        $result = Invoke-GateStep -Order $step.Order -Name $step.Name -RelativePath $step.Path -ExtraArgs $step.ExtraArgs
        $results += $result

        Write-LocalJsonLog -EventName "step_completed" -Status $result.status -Data $result
        Emit-LocalHeartbeat -Status $result.status

        if ($result.status -ne "pass") {
            break
        }
    }

    $stepCount = @($results).Count
    $passCount = @($results | Where-Object { $_.status -eq "pass" }).Count
    $failCount = @($results | Where-Object { $_.status -eq "fail" }).Count
    $overallStatus = if ($failCount -gt 0) { "fail" } else { "pass" }
    $disposition = if ($overallStatus -eq "pass") { "governed_refresh_gate_passed" } else { "governed_refresh_gate_failed" }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $reportCsv = Join-Path $OutputRoot "provider_snapshot_governed_refresh_gate_report_$timestamp.csv"
    $summaryJson = Join-Path $OutputRoot "provider_snapshot_governed_refresh_gate_summary_$timestamp.json"

    $results | Export-Csv -Path $reportCsv -NoTypeInformation

    $summary = [ordered]@{
        status = $overallStatus
        disposition = $disposition
        preview_only = $true
        db_writes = $false
        provider_calls = $true
        worker_name = $WorkerName
        run_id = $RunId
        mac_user_id = $MacUserId
        provider_label = $ProviderLabel
        step_count = $stepCount
        pass_count = $passCount
        fail_count = $failCount
        report_csv = $reportCsv
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $overallStatus -Payload $summary
    Emit-LocalSignal -SignalName $PassCountSignal -SignalValue $passCount -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $FailCountSignal -SignalValue $failCount -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $StepCountSignal -SignalValue $stepCount -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $overallStatus -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: provider snapshot governed refresh gate completed. status=$overallStatus disposition=$disposition step_count=$stepCount pass_count=$passCount fail_count=$failCount db_writes=False provider_calls=True run_id=$RunId"
        Write-Output "FILES: report_csv=$reportCsv summary_json=$summaryJson"
        $results | Format-Table step_order, step_name, status, exit_code, duration_ms, provider_calls, db_writes -AutoSize
    }

    if ($overallStatus -eq "pass") {
        exit 0
    }

    exit 1
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

    Write-Error "FAILED: provider snapshot governed refresh gate failed. $message run_id=$RunId"
    exit 1
}

