# MiraTV Materialization Queue Reliability Worker
# File: tools/workers/check_materialization_queue.ps1
# Purpose:
#   P0.6 materialization queue reliability scaffold.
#   Establishes observable checks for queue age, dead-letter count, requeue rate,
#   and stalled materialization behavior before DB-backed enforcement.
#
# Current implementation:
#   - Local-first, no DB writes yet.
#   - Supports DryRun and SnapshotInput modes.
#   - Emits materialization queue and worker heartbeat signals.
#   - Does not mutate queue tables or retry/dead-letter records.
#   - Designed to be extended with DB/query bridge checks later.
#
# Signals:
#   - materialization_queue_oldest_age_minutes
#   - materialization_dead_letter_count
#   - materialization_requeue_rate
#   - worker_heartbeat_status
#
# Kill switch:
#   - ENABLE_MATERIALIZATION_CONSUMERS
#
# Usage:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_materialization_queue.ps1" -Environment "dev"
#
# Optional snapshot input:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_materialization_queue.ps1" `
#     -Environment "dev" `
#     -Mode "SnapshotInput" `
#     -InputJsonPath "runtime/samples/materialization_queue_snapshot.json"

[CmdletBinding()]
param(
    [string]$WorkerName = "materialization_queue_worker",
    [string]$Component = "materialization_queue_worker",
    [string]$Environment = "prod",
    [string]$KillSwitchName = "ENABLE_MATERIALIZATION_CONSUMERS",

    [ValidateSet("DryRun", "SnapshotInput")]
    [string]$Mode = "DryRun",

    [string]$InputJsonPath = "",
    [string]$QueueName = "",
    [int]$MaxOldestAgeMinutes = 60,
    [int]$MaxDeadLetterCount = 0,
    [decimal]$MaxRequeueRate = 0.10,
    [int]$HeartbeatIntervalSeconds = 300,
    [int]$StaleAfterSeconds = 900,
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

function Resolve-RepoRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return Join-Path $RepoRoot $Path
}

function Read-QueueSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Input snapshot not found: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Input snapshot is empty: $Path"
    }

    return $raw | ConvertFrom-Json -ErrorAction Stop
}

function Convert-ToArray {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        return @($Value)
    }

    return @($Value)
}

function Get-PropertyValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Object,

        [string[]]$Names
    )

    if ($null -eq $Object) {
        return $null
    }

    foreach ($name in $Names) {
        if ($Object.PSObject.Properties.Name -contains $name) {
            return $Object.$name
        }
    }

    return $null
}

function Convert-ToIntSafe {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value,

        [int]$DefaultValue = 0
    )

    if ($null -eq $Value) {
        return $DefaultValue
    }

    $parsed = 0

    if ([int]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed
    }

    return $DefaultValue
}

function Convert-ToDecimalSafe {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value,

        [decimal]$DefaultValue = 0
    )

    if ($null -eq $Value) {
        return $DefaultValue
    }

    $parsed = [decimal]0

    if ([decimal]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed
    }

    return $DefaultValue
}

function Get-QueueRows {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Snapshot
    )

    if ($null -eq $Snapshot) {
        return @()
    }

    if ($Snapshot.PSObject.Properties.Name -contains "queues") {
        return Convert-ToArray -Value $Snapshot.queues
    }

    if ($Snapshot.PSObject.Properties.Name -contains "items") {
        return Convert-ToArray -Value $Snapshot.items
    }

    if ($Snapshot.PSObject.Properties.Name -contains "queue_rows") {
        return Convert-ToArray -Value $Snapshot.queue_rows
    }

    if ($Snapshot.PSObject.Properties.Name -contains "results") {
        return Convert-ToArray -Value $Snapshot.results
    }

    return Convert-ToArray -Value $Snapshot
}

function Get-QueueMetrics {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Snapshot,

        [string]$QueueName,

        [int]$MaxOldestAgeMinutes,

        [int]$MaxDeadLetterCount,

        [decimal]$MaxRequeueRate
    )

    $rows = Get-QueueRows -Snapshot $Snapshot

    if (-not [string]::IsNullOrWhiteSpace($QueueName)) {
        $rows = @(
            $rows | Where-Object {
                $queueRaw = Get-PropertyValue -Object $_ -Names @("queue_name", "queue", "name")
                ([string]$queueRaw).Trim().ToLowerInvariant() -eq $QueueName.Trim().ToLowerInvariant()
            }
        )
    }

    $totalQueues = @($rows).Count
    $oldestAgeMinutes = 0
    $deadLetterCount = 0
    $requeueRate = [decimal]0
    $pendingCount = 0
    $processingCount = 0
    $failedCount = 0
    $completedCount = 0
    $stalledCount = 0
    $warningQueues = 0
    $failedQueues = 0
    $queueSummaries = @()

    foreach ($row in $rows) {
        $queueRaw = Get-PropertyValue -Object $row -Names @("queue_name", "queue", "name")
        $queue = "unknown"

        if ($null -ne $queueRaw -and -not [string]::IsNullOrWhiteSpace([string]$queueRaw)) {
            $queue = ([string]$queueRaw).Trim().ToLowerInvariant()
        }

        $rowOldestAge = Convert-ToIntSafe -Value (Get-PropertyValue -Object $row -Names @("oldest_age_minutes", "queue_oldest_age_minutes", "oldest_pending_age_minutes")) -DefaultValue 0
        $rowDeadLetter = Convert-ToIntSafe -Value (Get-PropertyValue -Object $row -Names @("dead_letter_count", "deadletter_count", "dlq_count")) -DefaultValue 0
        $rowRequeueRate = Convert-ToDecimalSafe -Value (Get-PropertyValue -Object $row -Names @("requeue_rate", "retry_rate", "requeued_rate")) -DefaultValue 0
        $rowPending = Convert-ToIntSafe -Value (Get-PropertyValue -Object $row -Names @("pending_count", "queued_count", "ready_count")) -DefaultValue 0
        $rowProcessing = Convert-ToIntSafe -Value (Get-PropertyValue -Object $row -Names @("processing_count", "running_count", "in_progress_count")) -DefaultValue 0
        $rowFailed = Convert-ToIntSafe -Value (Get-PropertyValue -Object $row -Names @("failed_count", "error_count")) -DefaultValue 0
        $rowCompleted = Convert-ToIntSafe -Value (Get-PropertyValue -Object $row -Names @("completed_count", "done_count", "success_count")) -DefaultValue 0
        $rowStalled = Convert-ToIntSafe -Value (Get-PropertyValue -Object $row -Names @("stalled_count", "stuck_count")) -DefaultValue 0

        if ($rowOldestAge -gt $oldestAgeMinutes) {
            $oldestAgeMinutes = $rowOldestAge
        }

        $deadLetterCount += $rowDeadLetter
        $pendingCount += $rowPending
        $processingCount += $rowProcessing
        $failedCount += $rowFailed
        $completedCount += $rowCompleted
        $stalledCount += $rowStalled

        if ($rowRequeueRate -gt $requeueRate) {
            $requeueRate = $rowRequeueRate
        }

        $queueStatus = "pass"
        $queueNote = "queue metrics within configured thresholds"

        if ($rowDeadLetter -gt $MaxDeadLetterCount -or $rowStalled -gt 0) {
            $queueStatus = "fail"
            $queueNote = "dead-letter or stalled queue items detected"
            $failedQueues++
        }
        elseif ($rowOldestAge -gt $MaxOldestAgeMinutes -or $rowRequeueRate -gt $MaxRequeueRate -or $rowFailed -gt 0) {
            $queueStatus = "warning"
            $queueNote = "queue warning threshold exceeded"
            $warningQueues++
        }

        $queueSummaries += [ordered]@{
            queue_name = $queue
            status = $queueStatus
            oldest_age_minutes = $rowOldestAge
            dead_letter_count = $rowDeadLetter
            requeue_rate = $rowRequeueRate
            pending_count = $rowPending
            processing_count = $rowProcessing
            failed_count = $rowFailed
            completed_count = $rowCompleted
            stalled_count = $rowStalled
            note = $queueNote
        }
    }

    $status = "dry_run"
    $queueResult = "not_run"
    $note = "local-first scaffold; no DB query performed"

    if ($null -ne $Snapshot) {
        $status = "pass"
        $queueResult = "pass"
        $note = "materialization queue metrics within configured thresholds"

        if ($totalQueues -eq 0) {
            $status = "warning"
            $queueResult = "warning"
            $note = "no queue rows found for evaluated scope"
        }
        elseif ($failedQueues -gt 0) {
            $status = "fail"
            $queueResult = "fail"
            $note = "one or more hard queue reliability thresholds exceeded"
        }
        elseif ($warningQueues -gt 0) {
            $status = "warning"
            $queueResult = "warning"
            $note = "one or more queue warning thresholds exceeded"
        }
    }

    return [ordered]@{
        status = $status
        queue_result = $queueResult
        oldest_age_minutes = $oldestAgeMinutes
        dead_letter_count = $deadLetterCount
        requeue_rate = $requeueRate
        max_oldest_age_minutes = $MaxOldestAgeMinutes
        max_dead_letter_count = $MaxDeadLetterCount
        max_requeue_rate = $MaxRequeueRate
        total_queues = $totalQueues
        pending_count = $pendingCount
        processing_count = $processingCount
        failed_count = $failedCount
        completed_count = $completedCount
        stalled_count = $stalledCount
        warning_queues = $warningQueues
        failed_queues = $failedQueues
        queue_name = $QueueName
        queue_summaries = $queueSummaries
        validation_note = $note
    }
}

$repoRoot = Get-ScriptRepoRoot
$loggingModule = Join-Path $repoRoot "tools\common\Logging.psm1"

if (-not (Test-Path -LiteralPath $loggingModule)) {
    throw "Logging module not found at: $loggingModule"
}

Import-Module $loggingModule -Force

$script:RunId = New-RunId -Prefix "materialization-queue"

try {
    $enabled = Test-KillSwitch -Name $KillSwitchName -DefaultEnabled $true

    if (-not $enabled) {
        Write-JobLog `
            -RunId $script:RunId `
            -JobName "check_materialization_queue" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -Status "job_skipped" `
            -EventType "job_skipped" `
            -SourceName "materialization_queue" `
            -DurationMs (Get-DurationMs -Start $script:StartedAt) `
            -Data @{
                kill_switch_name = $KillSwitchName
                kill_switch_enabled = $false
                reason = "materialization consumers disabled by kill switch"
                mode = $Mode
            } `
            -LogRoot $LogRoot | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName "check_materialization_queue" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName "materialization_queue_oldest_age_minutes" `
            -P0Item "P0.6" `
            -SignalValue "disabled" `
            -Status "disabled" `
            -AllowedValues "0+|disabled|failed" `
            -SourceTableOrEndpoint "tools/workers/check_materialization_queue.ps1" `
            -Data @{
                dashboard_panel = "Materialization"
                widget_key = "materialization.queue.oldest_age_minutes"
                owner = "Content Ops"
                kill_switch_name = $KillSwitchName
            } `
            -LogRoot $LogRoot | Out-Null

        Write-Output "SKIPPED: $KillSwitchName is disabled. run_id=$script:RunId"
        exit 0
    }

    Write-JobLog `
        -RunId $script:RunId `
        -JobName "check_materialization_queue" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -Status "job_started" `
        -EventType "job_started" `
        -SourceName "materialization_queue" `
        -Data @{
            kill_switch_name = $KillSwitchName
            mode = $Mode
            queue_name = $QueueName
            max_oldest_age_minutes = $MaxOldestAgeMinutes
            max_dead_letter_count = $MaxDeadLetterCount
            max_requeue_rate = $MaxRequeueRate
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Heartbeat `
        -RunId $script:RunId `
        -JobName "check_materialization_queue" `
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
        -JobName "check_materialization_queue" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "worker_heartbeat_status" `
        -P0Item "P0.2" `
        -SignalValue "ok" `
        -Status "ok" `
        -AllowedValues "ok|missed|failed|disabled" `
        -SourceTableOrEndpoint "tools/workers/check_materialization_queue.ps1" `
        -Data @{
            dashboard_panel = "Worker Health"
            widget_key = "worker.heartbeat.status"
            owner = "SRE"
            kill_switch_name = $KillSwitchName
        } `
        -LogRoot $LogRoot | Out-Null

    $snapshot = $null

    if ($Mode -eq "SnapshotInput") {
        if ([string]::IsNullOrWhiteSpace($InputJsonPath)) {
            throw "InputJsonPath is required when Mode=SnapshotInput."
        }

        $resolvedInput = Resolve-RepoRelativePath -RepoRoot $repoRoot -Path $InputJsonPath
        $snapshot = Read-QueueSnapshot -Path $resolvedInput
    }

    $metrics = Get-QueueMetrics `
        -Snapshot $snapshot `
        -QueueName $QueueName `
        -MaxOldestAgeMinutes $MaxOldestAgeMinutes `
        -MaxDeadLetterCount $MaxDeadLetterCount `
        -MaxRequeueRate $MaxRequeueRate

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "check_materialization_queue" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "materialization_queue_oldest_age_minutes" `
        -P0Item "P0.6" `
        -SignalValue ([string]$metrics.oldest_age_minutes) `
        -ValueNum ([decimal]$metrics.oldest_age_minutes) `
        -Status ([string]$metrics.status) `
        -AllowedValues "0+" `
        -SourceTableOrEndpoint "tools/workers/check_materialization_queue.ps1" `
        -Data @{
            dashboard_panel = "Materialization"
            widget_key = "materialization.queue.oldest_age_minutes"
            owner = "Content Ops"
            kill_switch_name = $KillSwitchName
            mode = $Mode
            queue_name = $QueueName
            max_oldest_age_minutes = $metrics.max_oldest_age_minutes
            total_queues = $metrics.total_queues
            pending_count = $metrics.pending_count
            processing_count = $metrics.processing_count
            validation_note = $metrics.validation_note
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "check_materialization_queue" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "materialization_dead_letter_count" `
        -P0Item "P0.6" `
        -SignalValue ([string]$metrics.dead_letter_count) `
        -ValueNum ([decimal]$metrics.dead_letter_count) `
        -Status ([string]$metrics.status) `
        -AllowedValues "0+" `
        -SourceTableOrEndpoint "tools/workers/check_materialization_queue.ps1" `
        -Data @{
            dashboard_panel = "Materialization"
            widget_key = "materialization.queue.dead_letter_count"
            owner = "Content Ops"
            kill_switch_name = $KillSwitchName
            mode = $Mode
            queue_name = $QueueName
            max_dead_letter_count = $metrics.max_dead_letter_count
            failed_queues = $metrics.failed_queues
            failed_count = $metrics.failed_count
            stalled_count = $metrics.stalled_count
            validation_note = $metrics.validation_note
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "check_materialization_queue" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "materialization_requeue_rate" `
        -P0Item "P0.6" `
        -SignalValue ([string]$metrics.requeue_rate) `
        -ValueNum ([decimal]$metrics.requeue_rate) `
        -Status ([string]$metrics.status) `
        -AllowedValues "0..1" `
        -SourceTableOrEndpoint "tools/workers/check_materialization_queue.ps1" `
        -Data @{
            dashboard_panel = "Materialization"
            widget_key = "materialization.queue.requeue_rate"
            owner = "Content Ops"
            kill_switch_name = $KillSwitchName
            mode = $Mode
            queue_name = $QueueName
            max_requeue_rate = $metrics.max_requeue_rate
            warning_queues = $metrics.warning_queues
            validation_note = $metrics.validation_note
        } `
        -LogRoot $LogRoot | Out-Null

    Write-JobLog `
        -RunId $script:RunId `
        -JobName "check_materialization_queue" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -Status "job_completed" `
        -EventType "job_completed" `
        -SourceName "materialization_queue" `
        -SourceRowCount ([int]$metrics.total_queues) `
        -RowsInserted 0 `
        -RowsUpdated 0 `
        -RowsSkipped ([int]$metrics.total_queues) `
        -RowsFailed ([int]$metrics.failed_queues) `
        -DurationMs (Get-DurationMs -Start $script:StartedAt) `
        -Data @{
            queue_result = $metrics.queue_result
            oldest_age_minutes = $metrics.oldest_age_minutes
            dead_letter_count = $metrics.dead_letter_count
            requeue_rate = $metrics.requeue_rate
            total_queues = $metrics.total_queues
            pending_count = $metrics.pending_count
            processing_count = $metrics.processing_count
            failed_count = $metrics.failed_count
            completed_count = $metrics.completed_count
            stalled_count = $metrics.stalled_count
            warning_queues = $metrics.warning_queues
            failed_queues = $metrics.failed_queues
            queue_name = $QueueName
            mode = $Mode
            validation_note = $metrics.validation_note
            note = "local-first scaffold; no DB query performed"
        } `
        -LogRoot $LogRoot | Out-Null

    Write-Output "OK: materialization queue check completed. result=$($metrics.queue_result) oldest_age_minutes=$($metrics.oldest_age_minutes) dead_letter_count=$($metrics.dead_letter_count) requeue_rate=$($metrics.requeue_rate) mode=$Mode run_id=$script:RunId"
    exit 0
}
catch {
    $message = $_.Exception.Message
    $duration = Get-DurationMs -Start $script:StartedAt

    if ([string]::IsNullOrWhiteSpace($script:RunId)) {
        $script:RunId = "materialization-queue-failed-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
    }

    try {
        Write-JobLog `
            -RunId $script:RunId `
            -JobName "check_materialization_queue" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -Status "job_failed" `
            -EventType "job_failed" `
            -SourceName "materialization_queue" `
            -DurationMs $duration `
            -ErrorCode "MATERIALIZATION_QUEUE_CHECK_FAILED" `
            -ErrorMessage $message `
            -Data @{
                kill_switch_name = $KillSwitchName
                mode = $Mode
                queue_name = $QueueName
            } `
            -LogRoot $LogRoot | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName "check_materialization_queue" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName "materialization_queue_oldest_age_minutes" `
            -P0Item "P0.6" `
            -SignalValue "failed" `
            -Status "failed" `
            -AllowedValues "0+|disabled|failed" `
            -SourceTableOrEndpoint "tools/workers/check_materialization_queue.ps1" `
            -ErrorCode "MATERIALIZATION_QUEUE_CHECK_FAILED" `
            -ErrorMessage $message `
            -Data @{
                dashboard_panel = "Materialization"
                widget_key = "materialization.queue.oldest_age_minutes"
                owner = "Content Ops"
                kill_switch_name = $KillSwitchName
                mode = $Mode
                queue_name = $QueueName
            } `
            -LogRoot $LogRoot | Out-Null
    }
    catch {
        Write-Error "Materialization queue worker failed and failed to log error: $($_.Exception.Message)"
    }

    Write-Error "FAILED: materialization queue worker failed. run_id=$script:RunId error=$message"
    exit 1
}