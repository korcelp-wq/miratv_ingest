# MiraTV Worker Heartbeat Emitter
# File: tools/workers/emit_worker_heartbeat.ps1
# Purpose:
#   First concrete automation worker for the MiraTV ingest automation contract.
#   Proves structured logging, heartbeat emission, signal emission, kill switch,
#   terminal job status, and local JSONL fallback behavior.
#
# Signals:
#   - worker_heartbeat_status
#   - last_heartbeat_at
#
# Kill switch:
#   - ENABLE_WORKER_RUNTIME
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File "tools/workers/emit_worker_heartbeat.ps1"
#
# Optional:
#   powershell -NoProfile -ExecutionPolicy Bypass -File "tools/workers/emit_worker_heartbeat.ps1" `
#     -WorkerName "worker_runtime" `
#     -Component "worker_runtime" `
#     -Environment "dev"

[CmdletBinding()]
param(
    [string]$WorkerName = "worker_runtime",
    [string]$Component = "worker_runtime",
    [string]$Environment = "prod",
    [string]$KillSwitchName = "ENABLE_WORKER_RUNTIME",
    [int]$HeartbeatIntervalSeconds = 60,
    [int]$StaleAfterSeconds = 300,
    [string]$LogRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:StartedAt = Get-Date
$script:RunId = $null

function Get-ScriptRepoRoot {
    [CmdletBinding()]
    param()

    $scriptDir = Split-Path -Parent $PSCommandPath

    # Expected location:
    #   <repo>\tools\workers\emit_worker_heartbeat.ps1
    # Repo root is two levels up from tools\workers.
    $rootCandidate = Join-Path $scriptDir "..\.."
    $resolved = Resolve-Path -Path $rootCandidate -ErrorAction SilentlyContinue

    if ($null -ne $resolved) {
        return $resolved.Path
    }

    return (Get-Location).Path
}

function Get-DurationMs {
    [CmdletBinding()]
    param(
        [datetime]$Start
    )

    $elapsed = (Get-Date) - $Start
    return [int][math]::Round($elapsed.TotalMilliseconds, 0)
}

$repoRoot = Get-ScriptRepoRoot
$loggingModule = Join-Path $repoRoot "tools\common\Logging.psm1"

if (-not (Test-Path -LiteralPath $loggingModule)) {
    throw "Logging module not found at: $loggingModule"
}

Import-Module $loggingModule -Force

$script:RunId = New-RunId -Prefix "worker-heartbeat"

try {
    $enabled = Test-KillSwitch -Name $KillSwitchName -DefaultEnabled $true

    if (-not $enabled) {
        Write-JobLog `
            -RunId $script:RunId `
            -JobName "emit_worker_heartbeat" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -Status "job_skipped" `
            -EventType "job_skipped" `
            -SourceName "worker_runtime" `
            -DurationMs (Get-DurationMs -Start $script:StartedAt) `
            -Data @{
                kill_switch_name = $KillSwitchName
                kill_switch_enabled = $false
                reason = "worker runtime disabled by kill switch"
            } `
            -LogRoot $LogRoot | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName "emit_worker_heartbeat" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName "worker_heartbeat_status" `
            -P0Item "P0.2" `
            -SignalValue "disabled" `
            -Status "disabled" `
            -AllowedValues "ok|missed|failed|disabled" `
            -SourceTableOrEndpoint "tools/workers/emit_worker_heartbeat.ps1" `
            -Data @{
                kill_switch_name = $KillSwitchName
            } `
            -LogRoot $LogRoot | Out-Null

        Write-Output "SKIPPED: $KillSwitchName is disabled. run_id=$script:RunId"
        exit 0
    }

    Write-JobLog `
        -RunId $script:RunId `
        -JobName "emit_worker_heartbeat" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -Status "job_started" `
        -EventType "job_started" `
        -SourceName "worker_runtime" `
        -Data @{
            kill_switch_name = $KillSwitchName
            heartbeat_interval_seconds = $HeartbeatIntervalSeconds
            stale_after_seconds = $StaleAfterSeconds
        } `
        -LogRoot $LogRoot | Out-Null

    $heartbeatAt = (Get-Date).ToUniversalTime().ToString("o")

    Emit-Heartbeat `
        -RunId $script:RunId `
        -JobName "emit_worker_heartbeat" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -HeartbeatStatus "ok" `
        -HeartbeatIntervalSeconds $HeartbeatIntervalSeconds `
        -StaleAfterSeconds $StaleAfterSeconds `
        -Data @{
            signal_name = "worker_heartbeat_status"
            p0_item = "P0.2"
            kill_switch_name = $KillSwitchName
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "emit_worker_heartbeat" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "worker_heartbeat_status" `
        -P0Item "P0.2" `
        -SignalValue "ok" `
        -Status "ok" `
        -AllowedValues "ok|missed|failed|disabled" `
        -SourceTableOrEndpoint "tools/workers/emit_worker_heartbeat.ps1" `
        -Data @{
            dashboard_panel = "Worker Health"
            widget_key = "worker.heartbeat.status"
            owner = "SRE"
            kill_switch_name = $KillSwitchName
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "emit_worker_heartbeat" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "last_heartbeat_at" `
        -P0Item "P0.2" `
        -SignalValue $heartbeatAt `
        -Status "ok" `
        -AllowedValues "ISO-8601 datetime" `
        -SourceTableOrEndpoint "tools/workers/emit_worker_heartbeat.ps1" `
        -Data @{
            dashboard_panel = "Worker Health"
            widget_key = "worker.heartbeat.last_seen"
            owner = "SRE"
            kill_switch_name = $KillSwitchName
            heartbeat_interval_seconds = $HeartbeatIntervalSeconds
            stale_after_seconds = $StaleAfterSeconds
        } `
        -LogRoot $LogRoot | Out-Null

    Write-JobLog `
        -RunId $script:RunId `
        -JobName "emit_worker_heartbeat" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -Status "job_completed" `
        -EventType "job_completed" `
        -SourceName "worker_runtime" `
        -DurationMs (Get-DurationMs -Start $script:StartedAt) `
        -Data @{
            heartbeat_status = "ok"
            last_heartbeat_at = $heartbeatAt
            kill_switch_name = $KillSwitchName
        } `
        -LogRoot $LogRoot | Out-Null

    Write-Output "OK: heartbeat emitted. run_id=$script:RunId component=$Component worker=$WorkerName heartbeat_at=$heartbeatAt"
    exit 0
}
catch {
    $message = $_.Exception.Message
    $duration = Get-DurationMs -Start $script:StartedAt

    if ([string]::IsNullOrWhiteSpace($script:RunId)) {
        $script:RunId = "worker-heartbeat-failed-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
    }

    try {
        Write-JobLog `
            -RunId $script:RunId `
            -JobName "emit_worker_heartbeat" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -Status "job_failed" `
            -EventType "job_failed" `
            -SourceName "worker_runtime" `
            -DurationMs $duration `
            -ErrorCode "WORKER_HEARTBEAT_FAILED" `
            -ErrorMessage $message `
            -Data @{
                kill_switch_name = $KillSwitchName
            } `
            -LogRoot $LogRoot | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName "emit_worker_heartbeat" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName "worker_heartbeat_status" `
            -P0Item "P0.2" `
            -SignalValue "failed" `
            -Status "failed" `
            -AllowedValues "ok|missed|failed|disabled" `
            -SourceTableOrEndpoint "tools/workers/emit_worker_heartbeat.ps1" `
            -ErrorCode "WORKER_HEARTBEAT_FAILED" `
            -ErrorMessage $message `
            -Data @{
                dashboard_panel = "Worker Health"
                widget_key = "worker.heartbeat.status"
                owner = "SRE"
                kill_switch_name = $KillSwitchName
            } `
            -LogRoot $LogRoot | Out-Null
    }
    catch {
        Write-Error "Heartbeat worker failed and failed to log error: $($_.Exception.Message)"
    }

    Write-Error "FAILED: heartbeat worker failed. run_id=$script:RunId error=$message"
    exit 1
}