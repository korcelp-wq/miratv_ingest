# MiraTV Materialization Queue Reliability Worker
# File: tools/workers/check_materialization_queue.ps1
# Purpose:
#   P0.6 materialization queue reliability scaffold + read-only DB-backed mode.
#   Establishes observable materialization queue health checks without mutating queue tables.
#
# Current implementation:
#   - Supports DryRun, SnapshotInput, and DbQuery modes.
#   - DbQuery mode uses tools/common/DbQuery.psm1, which calls dog_open_proc.php.
#   - DbQuery mode discovers queue-like tables and columns before querying them.
#   - Does not mutate database tables.
#
# Queue philosophy:
#   Materialization is allowed to be asynchronous, but the queue must not silently stall.
#   This worker separates:
#     - pending rows
#     - in-progress rows
#     - failed/dead-letter rows
#     - recently completed rows
#     - oldest pending age
#     - requeue rate
#
# Signals:
#   - materialization_queue_oldest_age_minutes
#   - materialization_dead_letter_count
#   - materialization_requeue_rate
#   - materialization_queue_pending_count
#   - materialization_queue_processing_count
#   - materialization_queue_failed_count
#   - materialization_queue_recent_completed_count
#   - materialization_series_port_900_pending_count
#   - materialization_series_port_900_needs_manual_match_count
#   - materialization_series_port_900_failed_count
#   - materialization_episode_lookup_missing_pending_count
#   - worker_heartbeat_status
#
# Kill switch:
#   - ENABLE_MATERIALIZATION_CONSUMERS
#
# Required for DbQuery mode:
#   $env:DOG_OPEN_PROC_ENDPOINT = "https://miratv.club/_workers/api/series/dog_open_proc.php"
#   $env:DOG_OPEN_PROC_TOKEN = "<token>"
#
# Usage:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_materialization_queue.ps1" -Environment "dev"
#
# DbQuery:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_materialization_queue.ps1" -Environment "dev" -Mode "DbQuery"

[CmdletBinding()]
param(
    [string]$WorkerName = "materialization_queue_worker",
    [string]$Component = "materialization_queue_worker",
    [string]$Environment = "prod",
    [string]$KillSwitchName = "ENABLE_MATERIALIZATION_CONSUMERS",

    [ValidateSet("DryRun", "SnapshotInput", "DbQuery")]
    [string]$Mode = "DryRun",

    [string]$InputJsonPath = "",
    [string]$DatabaseKey = "ip",
    [string]$DbQueryEndpoint = "",
    [string]$DbQueryToken = "",
    [int]$QueryTimeoutSec = 30,

    [int]$MaxOldestAgeMinutes = 1440,
    [int]$MaxDeadLetterCount = 0,
    [decimal]$MaxRequeueRate = 0.10,
    [int]$RecentCompletionWindowMinutes = 1440,
    [int]$HeartbeatIntervalSeconds = 1800,
    [int]$StaleAfterSeconds = 7200,
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

function Convert-ToArraySafe {
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

function Get-SnapshotMetricRow {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Snapshot
    )

    if ($null -eq $Snapshot) {
        return $null
    }

    if ($Snapshot.PSObject.Properties.Name -contains "metrics") {
        $rows = Convert-ToArraySafe -Value $Snapshot.metrics
        if ($rows.Count -gt 0) {
            return $rows[0]
        }
    }

    if ($Snapshot.PSObject.Properties.Name -contains "rows") {
        $rows = Convert-ToArraySafe -Value $Snapshot.rows
        if ($rows.Count -gt 0) {
            return $rows[0]
        }
    }

    if ($Snapshot.PSObject.Properties.Name -contains "result") {
        $rows = Convert-ToArraySafe -Value $Snapshot.result
        if ($rows.Count -gt 0) {
            return $rows[0]
        }
    }

    if ($Snapshot.PSObject.Properties.Name -contains "queue") {
        $rows = Convert-ToArraySafe -Value $Snapshot.queue
        if ($rows.Count -gt 0) {
            return $rows[0]
        }
    }

    return $Snapshot
}

function Escape-SqlIdentifier {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($Name -notmatch "^[A-Za-z0-9_]+$") {
        throw "Unsafe SQL identifier: $Name"
    }

    return "``$Name``"
}

function Get-QueueDiscoverySql {
    [CmdletBinding()]
    param()

    return @"
SELECT
    t.TABLE_NAME AS table_name,
    c.COLUMN_NAME AS column_name
FROM information_schema.TABLES t
LEFT JOIN information_schema.COLUMNS c
    ON c.TABLE_SCHEMA = t.TABLE_SCHEMA
   AND c.TABLE_NAME = t.TABLE_NAME
WHERE t.TABLE_SCHEMA = DATABASE()
  AND (
        t.TABLE_NAME = 'content_materialization_queue'
     OR t.TABLE_NAME LIKE '%materialization%queue%'
     OR t.TABLE_NAME LIKE '%materialize%queue%'
     OR t.TABLE_NAME LIKE '%enrichment%queue%'
  )
ORDER BY t.TABLE_NAME, c.ORDINAL_POSITION
"@
}

function Get-PreferredQueueTable {
    [CmdletBinding()]
    param(
        [hashtable]$TableMap
    )

    $preferred = @(
        "content_materialization_queue",
        "materialization_queue",
        "content_enrichment_queue"
    )

    foreach ($candidate in $preferred) {
        if ($TableMap.ContainsKey($candidate)) {
            return $candidate
        }
    }

    foreach ($key in $TableMap.Keys) {
        return [string]$key
    }

    return ""
}

function Get-PreferredColumn {
    [CmdletBinding()]
    param(
        [string[]]$ColumnNames,
        [string[]]$PreferredNames
    )

    foreach ($candidate in $PreferredNames) {
        if ($ColumnNames -contains $candidate) {
            return $candidate
        }
    }

    return ""
}

function Get-QueueMetricSql {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TableName,

        [Parameter(Mandatory = $true)]
        [string[]]$ColumnNames,

        [int]$RecentCompletionWindowMinutes = 1440
    )

    $safeTable = Escape-SqlIdentifier -Name $TableName

    $statusColumn = Get-PreferredColumn -ColumnNames $ColumnNames -PreferredNames @(
        "status",
        "queue_status",
        "state"
    )

    $createdColumn = Get-PreferredColumn -ColumnNames $ColumnNames -PreferredNames @(
        "created_at",
        "queued_at",
        "requested_at",
        "inserted_at"
    )

    $updatedColumn = Get-PreferredColumn -ColumnNames $ColumnNames -PreferredNames @(
        "updated_at",
        "last_updated_at",
        "processed_at",
        "completed_at",
        "finished_at",
        "last_attempt_at"
    )

    $attemptColumn = Get-PreferredColumn -ColumnNames $ColumnNames -PreferredNames @(
        "attempt_count", "attempts", "retry_count", "tries"
    )

    $triggerReasonColumn = Get-PreferredColumn -ColumnNames $ColumnNames -PreferredNames @(
        "trigger_reason",
        "reason",
        "queue_reason",
        "materialization_reason"
    )

    $statusExpr = "LOWER(COALESCE($([string](Escape-SqlIdentifier -Name $statusColumn)), 'unknown'))"
    if ([string]::IsNullOrWhiteSpace($statusColumn)) {
        $statusExpr = "'unknown'"
    }

    $createdExpr = "NULL"
    if (-not [string]::IsNullOrWhiteSpace($createdColumn)) {
        $createdExpr = [string](Escape-SqlIdentifier -Name $createdColumn)
    }

    $updatedExpr = "NULL"
    if (-not [string]::IsNullOrWhiteSpace($updatedColumn)) {
        $updatedExpr = [string](Escape-SqlIdentifier -Name $updatedColumn)
    }

    $attemptExpr = "0"
    if (-not [string]::IsNullOrWhiteSpace($attemptColumn)) {
        $attemptExpr = "COALESCE($([string](Escape-SqlIdentifier -Name $attemptColumn)), 0)"
    }

    $triggerReasonExpr = "''"
    if (-not [string]::IsNullOrWhiteSpace($triggerReasonColumn)) {
        $triggerReasonExpr = "LOWER(COALESCE($([string](Escape-SqlIdentifier -Name $triggerReasonColumn)), ''))"
    }

    return @"
SELECT
    '$TableName' AS queue_table,
    COUNT(*) AS total_rows,
    SUM(
        CASE
            WHEN $statusExpr IN ('pending', 'queued', 'new', 'ready', 'not_run')
            THEN 1
            ELSE 0
        END
    ) AS pending_count,
    SUM(
        CASE
            WHEN $statusExpr IN ('pending', 'queued', 'new', 'ready', 'not_run')
             AND $triggerReasonExpr = 'series_port_900_image_repair'
            THEN 1
            ELSE 0
        END
    ) AS series_port_900_pending_count,
    SUM(
        CASE
            WHEN $statusExpr IN ('needs_manual_match', 'manual_match', 'needs_manual', 'manual_required')
             AND $triggerReasonExpr = 'series_port_900_image_repair'
            THEN 1
            ELSE 0
        END
    ) AS series_port_900_needs_manual_match_count,
    SUM(
        CASE
            WHEN $statusExpr IN ('failed', 'error', 'dead_letter', 'deadletter', 'blocked')
             AND $triggerReasonExpr = 'series_port_900_image_repair'
            THEN 1
            ELSE 0
        END
    ) AS series_port_900_failed_count,
    SUM(
        CASE
            WHEN $statusExpr IN ('pending', 'queued', 'new', 'ready', 'not_run')
             AND $triggerReasonExpr = 'episode_lookup_missing'
            THEN 1
            ELSE 0
        END
    ) AS episode_lookup_missing_pending_count,
    SUM(
        CASE
            WHEN $statusExpr IN ('running', 'processing', 'in_progress', 'started', 'working')
            THEN 1
            ELSE 0
        END
    ) AS in_progress_count,
    SUM(
        CASE
            WHEN $statusExpr IN ('failed', 'error', 'dead_letter', 'deadletter', 'blocked')
            THEN 1
            ELSE 0
        END
    ) AS failed_count,
    SUM(
        CASE
            WHEN $statusExpr IN ('dead_letter', 'deadletter')
            THEN 1
            ELSE 0
        END
    ) AS dead_letter_count,
    SUM(
        CASE
            WHEN $statusExpr IN ('complete', 'completed', 'done', 'success', 'succeeded')
             AND $updatedExpr IS NOT NULL
             AND $updatedExpr >= DATE_SUB(NOW(), INTERVAL $RecentCompletionWindowMinutes MINUTE)
            THEN 1
            ELSE 0
        END
    ) AS completed_recent_count,
    COALESCE(MAX($attemptExpr), 0) AS max_attempts,
    SUM(CASE WHEN $attemptExpr > 1 THEN 1 ELSE 0 END) AS requeued_rows,
    CASE
        WHEN COUNT(*) > 0 THEN ROUND(SUM(CASE WHEN $attemptExpr > 1 THEN 1 ELSE 0 END) / COUNT(*), 6)
        ELSE 0
    END AS requeue_rate,
    COALESCE(
        MAX(
            CASE
                WHEN $statusExpr IN ('pending', 'queued', 'new', 'ready', 'not_run')
                 AND $createdExpr IS NOT NULL
                THEN TIMESTAMPDIFF(MINUTE, $createdExpr, NOW())
                ELSE 0
            END
        ),
        0
    ) AS oldest_age_minutes
FROM $safeTable
"@
}

function Get-QueueMetricDbRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [string]$DatabaseKey = "ip",

        [string]$Endpoint = "",

        [string]$Token = "",

        [int]$TimeoutSec = 30,

        [int]$RecentCompletionWindowMinutes = 1440
    )

    $dbQueryModule = Join-Path $RepoRoot "tools\common\DbQuery.psm1"

    if (-not (Test-Path -LiteralPath $dbQueryModule)) {
        throw "DbQuery module not found at: $dbQueryModule"
    }

    Import-Module $dbQueryModule -Force

    $discoveryResult = Invoke-ReadOnlyDbQuery `
        -DatabaseKey $DatabaseKey `
        -Sql (Get-QueueDiscoverySql) `
        -Endpoint $Endpoint `
        -Token $Token `
        -TimeoutSec $TimeoutSec

    $discoveryRows = Convert-ToArraySafe -Value $discoveryResult.rows
    $tableMap = @{}

    foreach ($row in $discoveryRows) {
        $tableName = Get-PropertyValue -Object $row -Names @("table_name", "TABLE_NAME")
        $columnName = Get-PropertyValue -Object $row -Names @("column_name", "COLUMN_NAME")

        if ($null -eq $tableName -or [string]::IsNullOrWhiteSpace([string]$tableName)) {
            continue
        }

        $tableNameText = ([string]$tableName).Trim()

        if ($tableNameText -notmatch "^[A-Za-z0-9_]+$") {
            continue
        }

        if (-not $tableMap.ContainsKey($tableNameText)) {
            $tableMap[$tableNameText] = New-Object System.Collections.Generic.List[string]
        }

        if ($null -ne $columnName -and -not [string]::IsNullOrWhiteSpace([string]$columnName)) {
            $columnNameText = ([string]$columnName).Trim()
            if ($columnNameText -match "^[A-Za-z0-9_]+$") {
                $tableMap[$tableNameText].Add($columnNameText) | Out-Null
            }
        }
    }

    $queueTable = Get-PreferredQueueTable -TableMap $tableMap

    if ([string]::IsNullOrWhiteSpace($queueTable)) {
        return [pscustomobject]@{
            queue_table = "not_found"
            total_rows = 0
            pending_count = 0
            series_port_900_pending_count = 0
            series_port_900_needs_manual_match_count = 0
            series_port_900_failed_count = 0
            episode_lookup_missing_pending_count = 0
            in_progress_count = 0
            failed_count = 0
            dead_letter_count = 0
            completed_recent_count = 0
            max_attempts = 0
            requeued_rows = 0
            requeue_rate = 0
            oldest_age_minutes = 0
        }
    }

    $columns = @($tableMap[$queueTable].ToArray())

    $sql = Get-QueueMetricSql `
        -TableName $queueTable `
        -ColumnNames $columns `
        -RecentCompletionWindowMinutes $RecentCompletionWindowMinutes

    $queryResult = Invoke-ReadOnlyDbQuery `
        -DatabaseKey $DatabaseKey `
        -Sql $sql `
        -Endpoint $Endpoint `
        -Token $Token `
        -TimeoutSec $TimeoutSec

    if ($null -eq $queryResult) {
        throw "DbQuery returned null result."
    }

    if (-not ($queryResult.PSObject.Properties.Name -contains "rows")) {
        throw "DbQuery result did not include rows."
    }

    $rows = Convert-ToArraySafe -Value $queryResult.rows

    if ($rows.Count -eq 0) {
        throw "DbQuery returned zero rows for materialization queue query."
    }

    return $rows[0]
}

function Get-QueueMetrics {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$MetricRow,

        [string]$Mode,

        [int]$MaxOldestAgeMinutes,

        [int]$MaxDeadLetterCount,

        [decimal]$MaxRequeueRate,

        [string]$SourceName
    )

    $status = "dry_run"
    $queueStatus = "not_run"
    $queueTable = "not_run"
    $totalRows = 0
    $pendingCount = 0
    $seriesPort900PendingCount = 0
    $seriesPort900NeedsManualMatchCount = 0
    $seriesPort900FailedCount = 0
    $episodeLookupMissingPendingCount = 0
    $inProgressCount = 0
    $failedCount = 0
    $deadLetterCount = 0
    $completedRecentCount = 0
    $maxAttempts = 0
    $requeuedRows = 0
    $requeueRate = [decimal]0
    $oldestAgeMinutes = 0
    $validationNote = "local-first scaffold; no DB query performed"

    if ($null -ne $MetricRow) {
        $queueTableRaw = Get-PropertyValue -Object $MetricRow -Names @("queue_table", "table_name", "queue_name")
        if ($null -ne $queueTableRaw -and -not [string]::IsNullOrWhiteSpace([string]$queueTableRaw)) {
            $queueTable = ([string]$queueTableRaw).Trim()
        }

        $totalRows = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @("total_rows", "row_count"))
        $pendingCount = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @("pending_count", "pending_rows"))
        $seriesPort900PendingCount = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @("series_port_900_pending_count"))
        $seriesPort900NeedsManualMatchCount = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @("series_port_900_needs_manual_match_count"))
        $seriesPort900FailedCount = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @("series_port_900_failed_count"))
        $episodeLookupMissingPendingCount = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @("episode_lookup_missing_pending_count"))
        $inProgressCount = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @("in_progress_count", "running_count", "processing_count"))
        $failedCount = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @("failed_count", "error_count"))
        $deadLetterCount = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @("dead_letter_count", "deadletter_count"))
        $completedRecentCount = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @("completed_recent_count", "recent_completed_count"))
        $maxAttempts = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @("max_attempts", "max_attempt_count"))
        $requeuedRows = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @("requeued_rows", "requeue_rows"))
        $requeueRate = Convert-ToDecimalSafe -Value (Get-PropertyValue -Object $MetricRow -Names @("requeue_rate", "requeue_ratio"))
        $oldestAgeMinutes = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @("oldest_age_minutes", "oldest_pending_age_minutes"))

        if ($totalRows -gt 0 -and $requeueRate -eq 0 -and $requeuedRows -gt 0) {
            $requeueRate = [decimal]::Round(([decimal]$requeuedRows / [decimal]$totalRows), 6)
        }

        $status = "ok"
        $queueStatus = "pass"
        $validationNote = "materialization queue metrics are within configured thresholds"

        if ($queueTable -eq "not_found") {
            $status = "warning"
            $queueStatus = "warning"
            $validationNote = "materialization queue table was not found"
        }
        elseif ($deadLetterCount -gt $MaxDeadLetterCount) {
            $status = "warning"
            $queueStatus = "warning"
            $validationNote = "dead letter count exceeds configured threshold"
        }
        elseif ($oldestAgeMinutes -gt $MaxOldestAgeMinutes) {
            $status = "warning"
            $queueStatus = "warning"
            $validationNote = "oldest pending materialization age exceeds configured threshold"
        }
        elseif ($requeueRate -gt $MaxRequeueRate) {
            $status = "warning"
            $queueStatus = "warning"
            $validationNote = "materialization requeue rate exceeds configured threshold"
        }
    }

    return [ordered]@{
        status = $status
        materialization_queue_status = $queueStatus
        queue_table = $queueTable
        total_rows = $totalRows
        pending_count = $pendingCount
        series_port_900_pending_count = $seriesPort900PendingCount
        series_port_900_needs_manual_match_count = $seriesPort900NeedsManualMatchCount
        series_port_900_failed_count = $seriesPort900FailedCount
        episode_lookup_missing_pending_count = $episodeLookupMissingPendingCount
        in_progress_count = $inProgressCount
        failed_count = $failedCount
        dead_letter_count = $deadLetterCount
        completed_recent_count = $completedRecentCount
        max_attempts = $maxAttempts
        requeued_rows = $requeuedRows
        requeue_rate = $requeueRate
        oldest_age_minutes = $oldestAgeMinutes
        max_oldest_age_minutes = $MaxOldestAgeMinutes
        max_dead_letter_count = $MaxDeadLetterCount
        max_requeue_rate = $MaxRequeueRate
        source_name = $SourceName
        mode = $Mode
        validation_note = $validationNote
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
            -AllowedValues "0+" `
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
            database_key = $DatabaseKey
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

    $metricRow = $null
    $sourceName = "dry_run_no_db_query"

    if ($Mode -eq "SnapshotInput") {
        if ([string]::IsNullOrWhiteSpace($InputJsonPath)) {
            throw "InputJsonPath is required when Mode=SnapshotInput."
        }

        $resolvedInput = Resolve-RepoRelativePath -RepoRoot $repoRoot -Path $InputJsonPath
        $snapshot = Read-QueueSnapshot -Path $resolvedInput
        $metricRow = Get-SnapshotMetricRow -Snapshot $snapshot
        $sourceName = "snapshot_input"
    }
    elseif ($Mode -eq "DbQuery") {
        $metricRow = Get-QueueMetricDbRow `
            -RepoRoot $repoRoot `
            -DatabaseKey $DatabaseKey `
            -Endpoint $DbQueryEndpoint `
            -Token $DbQueryToken `
            -TimeoutSec $QueryTimeoutSec `
            -RecentCompletionWindowMinutes $RecentCompletionWindowMinutes

        $sourceName = "dog_open_proc:content.materialization_queue"
    }

    $metrics = Get-QueueMetrics `
        -MetricRow $metricRow `
        -Mode $Mode `
        -MaxOldestAgeMinutes $MaxOldestAgeMinutes `
        -MaxDeadLetterCount $MaxDeadLetterCount `
        -MaxRequeueRate $MaxRequeueRate `
        -SourceName $sourceName

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
            source_name = $metrics.source_name
            queue_table = $metrics.queue_table
            pending_count = $metrics.pending_count
            max_oldest_age_minutes = $metrics.max_oldest_age_minutes
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
            source_name = $metrics.source_name
            queue_table = $metrics.queue_table
            failed_count = $metrics.failed_count
            max_dead_letter_count = $metrics.max_dead_letter_count
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
            source_name = $metrics.source_name
            queue_table = $metrics.queue_table
            requeued_rows = $metrics.requeued_rows
            total_rows = $metrics.total_rows
            max_requeue_rate = $metrics.max_requeue_rate
        } `
        -LogRoot $LogRoot | Out-Null

    $additionalMaterializationSignals = @(
        @{
            SignalName = "materialization_queue_pending_count"
            WidgetKey = "materialization.queue.pending_count"
            Value = [int]$metrics.pending_count
            AllowedValues = "0+"
            Extra = @{
                total_rows = $metrics.total_rows
                queue_table = $metrics.queue_table
                validation_note = $metrics.validation_note
            }
        },
        @{
            SignalName = "materialization_queue_processing_count"
            WidgetKey = "materialization.queue.processing_count"
            Value = [int]$metrics.in_progress_count
            AllowedValues = "0+"
            Extra = @{
                queue_table = $metrics.queue_table
                validation_note = $metrics.validation_note
            }
        },
        @{
            SignalName = "materialization_queue_failed_count"
            WidgetKey = "materialization.queue.failed_count"
            Value = [int]$metrics.failed_count
            AllowedValues = "0+"
            Extra = @{
                dead_letter_count = $metrics.dead_letter_count
                queue_table = $metrics.queue_table
                validation_note = $metrics.validation_note
            }
        },
        @{
            SignalName = "materialization_queue_recent_completed_count"
            WidgetKey = "materialization.queue.recent_completed_count"
            Value = [int]$metrics.completed_recent_count
            AllowedValues = "0+"
            Extra = @{
                queue_table = $metrics.queue_table
                recent_completion_window_minutes = $RecentCompletionWindowMinutes
                validation_note = $metrics.validation_note
            }
        },
        @{
            SignalName = "materialization_series_port_900_pending_count"
            WidgetKey = "materialization.series_port_900.pending_count"
            Value = [int]$metrics.series_port_900_pending_count
            AllowedValues = "0+"
            Extra = @{
                trigger_reason = "series_port_900_image_repair"
                queue_table = $metrics.queue_table
                validation_note = $metrics.validation_note
            }
        },
        @{
            SignalName = "materialization_series_port_900_needs_manual_match_count"
            WidgetKey = "materialization.series_port_900.needs_manual_match_count"
            Value = [int]$metrics.series_port_900_needs_manual_match_count
            AllowedValues = "0+"
            Extra = @{
                trigger_reason = "series_port_900_image_repair"
                queue_table = $metrics.queue_table
                validation_note = $metrics.validation_note
            }
        },
        @{
            SignalName = "materialization_series_port_900_failed_count"
            WidgetKey = "materialization.series_port_900.failed_count"
            Value = [int]$metrics.series_port_900_failed_count
            AllowedValues = "0+"
            Extra = @{
                trigger_reason = "series_port_900_image_repair"
                queue_table = $metrics.queue_table
                validation_note = $metrics.validation_note
            }
        },
        @{
            SignalName = "materialization_episode_lookup_missing_pending_count"
            WidgetKey = "materialization.episode_lookup_missing.pending_count"
            Value = [int]$metrics.episode_lookup_missing_pending_count
            AllowedValues = "0+"
            Extra = @{
                trigger_reason = "episode_lookup_missing"
                queue_table = $metrics.queue_table
                validation_note = "parked lane; do not consume until episode identity work resumes"
            }
        }
    )

    foreach ($signal in $additionalMaterializationSignals) {
        $signalData = @{
            dashboard_panel = "Materialization"
            widget_key = $signal.WidgetKey
            owner = "Content Ops"
            kill_switch_name = $KillSwitchName
            mode = $Mode
            source_name = $metrics.source_name
            queue_table = $metrics.queue_table
        }

        foreach ($key in $signal.Extra.Keys) {
            $signalData[$key] = $signal.Extra[$key]
        }

        Emit-Signal `
            -RunId $script:RunId `
            -JobName "check_materialization_queue" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName $signal.SignalName `
            -P0Item "P0.6" `
            -SignalValue ([string]$signal.Value) `
            -ValueNum ([decimal]$signal.Value) `
            -Status ([string]$metrics.status) `
            -AllowedValues $signal.AllowedValues `
            -SourceTableOrEndpoint "tools/workers/check_materialization_queue.ps1" `
            -Data $signalData `
            -LogRoot $LogRoot | Out-Null
    }

    Write-JobLog `
        -RunId $script:RunId `
        -JobName "check_materialization_queue" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -Status "job_completed" `
        -EventType "job_completed" `
        -SourceName ([string]$metrics.source_name) `
        -SourceRowCount ([int]$metrics.total_rows) `
        -RowsInserted 0 `
        -RowsUpdated 0 `
        -RowsSkipped ([int]$metrics.total_rows) `
        -RowsFailed 0 `
        -DurationMs (Get-DurationMs -Start $script:StartedAt) `
        -Data @{
            materialization_queue_status = $metrics.materialization_queue_status
            queue_table = $metrics.queue_table
            total_rows = $metrics.total_rows
            pending_count = $metrics.pending_count
            series_port_900_pending_count = $metrics.series_port_900_pending_count
            series_port_900_needs_manual_match_count = $metrics.series_port_900_needs_manual_match_count
            series_port_900_failed_count = $metrics.series_port_900_failed_count
            episode_lookup_missing_pending_count = $metrics.episode_lookup_missing_pending_count
            in_progress_count = $metrics.in_progress_count
            failed_count = $metrics.failed_count
            dead_letter_count = $metrics.dead_letter_count
            completed_recent_count = $metrics.completed_recent_count
            max_attempts = $metrics.max_attempts
            requeued_rows = $metrics.requeued_rows
            requeue_rate = $metrics.requeue_rate
            oldest_age_minutes = $metrics.oldest_age_minutes
            max_oldest_age_minutes = $metrics.max_oldest_age_minutes
            max_dead_letter_count = $metrics.max_dead_letter_count
            max_requeue_rate = $metrics.max_requeue_rate
            source_name = $metrics.source_name
            mode = $Mode
            validation_note = $metrics.validation_note
            note = "read-only materialization queue check; no DB writes performed"
        } `
        -LogRoot $LogRoot | Out-Null

    Write-Output "OK: materialization queue check completed. result=$($metrics.materialization_queue_status) queue_table=$($metrics.queue_table) pending_count=$($metrics.pending_count) port900_pending=$($metrics.series_port_900_pending_count) port900_manual=$($metrics.series_port_900_needs_manual_match_count) episode_lookup_pending=$($metrics.episode_lookup_missing_pending_count) oldest_age_minutes=$($metrics.oldest_age_minutes) dead_letter_count=$($metrics.dead_letter_count) requeue_rate=$($metrics.requeue_rate) mode=$Mode run_id=$script:RunId"
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
            -ErrorCode "MATERIALIZATION_QUEUE_FAILED" `
            -ErrorMessage $message `
            -Data @{
                kill_switch_name = $KillSwitchName
                mode = $Mode
                database_key = $DatabaseKey
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
            -SignalValue "0" `
            -Status "failed" `
            -AllowedValues "0+" `
            -SourceTableOrEndpoint "tools/workers/check_materialization_queue.ps1" `
            -ErrorCode "MATERIALIZATION_QUEUE_FAILED" `
            -ErrorMessage $message `
            -Data @{
                dashboard_panel = "Materialization"
                widget_key = "materialization.queue.oldest_age_minutes"
                owner = "Content Ops"
                kill_switch_name = $KillSwitchName
                mode = $Mode
            } `
            -LogRoot $LogRoot | Out-Null
    }
    catch {
        Write-Error "Materialization queue worker failed and failed to log error: $($_.Exception.Message)"
    }

    Write-Error "FAILED: materialization queue worker failed. run_id=$script:RunId error=$message"
    exit 1
}


