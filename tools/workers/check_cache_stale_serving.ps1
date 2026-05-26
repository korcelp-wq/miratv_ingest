# MiraTV Cache Stale-Serving Check Worker
# File: tools/workers/check_cache_stale_serving.ps1
# Purpose:
#   P0.4 cache stale-serving gate scaffold + read-only DB-backed mode.
#   Establishes observable cache health checks without mutating cache tables.
#
# Current implementation:
#   - Supports DryRun, SnapshotInput, and DbQuery modes.
#   - DbQuery mode uses tools/common/DbQuery.psm1, which calls dog_open_proc.php.
#   - DbQuery mode discovers cache-like tables and their actual timestamp/status columns before querying them.
#   - Does not mutate cache tables.
#
# Why this version exists:
#   Some cache/materialized tables do not share the same timestamp column names.
#   The previous DB mode assumed updated_at existed everywhere and could trigger a bridge-side HTTP 500.
#   This version uses information_schema first, then queries only columns that actually exist.
#
# Signals:
#   - cache_stale_serving_status
#   - cache_stale_ratio
#   - worker_heartbeat_status
#
# Kill switch:
#   - ENABLE_ASYNC_CACHE_REFRESH
#
# Required for DbQuery mode:
#   $env:DOG_OPEN_PROC_ENDPOINT = "https://miratv.club/_workers/api/series/dog_open_proc.php"
#   $env:DOG_OPEN_PROC_TOKEN = "<token>"
#
# Usage:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_cache_stale_serving.ps1" -Environment "dev"
#
# DbQuery:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_cache_stale_serving.ps1" -Environment "dev" -Mode "DbQuery"

[CmdletBinding()]
param(
    [string]$WorkerName = "cache_reader",
    [string]$Component = "cache_reader",
    [string]$Environment = "prod",
    [string]$KillSwitchName = "ENABLE_ASYNC_CACHE_REFRESH",

    [ValidateSet("DryRun", "SnapshotInput", "DbQuery")]
    [string]$Mode = "DryRun",

    [string]$InputJsonPath = "",
    [string]$DatabaseKey = "content",
    [string]$DbQueryEndpoint = "",
    [string]$DbQueryToken = "",
    [int]$QueryTimeoutSec = 30,

    [int]$FreshWindowMinutes = 30,
    [int]$ServeableStaleWindowMinutes = 1440,
    [decimal]$MaxStaleRatio = 0.80,
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

function Read-CacheSnapshot {
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

function Convert-ToDateTimeSafe {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    $text = ([string]$Value).Trim()

    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $parsed = [datetime]::MinValue

    if ([datetime]::TryParse($text, [ref]$parsed)) {
        return $parsed
    }

    return $null
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

    if ($Snapshot.PSObject.Properties.Name -contains "caches") {
        $rows = Convert-ToArraySafe -Value $Snapshot.caches
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

function Get-CacheDiscoverySql {
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
        t.TABLE_NAME LIKE '%cache%'
     OR t.TABLE_NAME LIKE '%materialized%'
     OR t.TABLE_NAME LIKE '%snapshot%'
     OR t.TABLE_NAME LIKE '%metadata_ext%'
  )
ORDER BY t.TABLE_NAME, c.ORDINAL_POSITION
"@
}

function Get-CacheRowSql {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TableName,

        [string]$TimestampColumn = "",

        [string]$ActiveColumn = "",

        [int]$FreshWindowMinutes = 30,

        [int]$ServeableStaleWindowMinutes = 1440
    )

    $safeTable = Escape-SqlIdentifier -Name $TableName

    $activeExpression = "COUNT(*)"
    if (-not [string]::IsNullOrWhiteSpace($ActiveColumn)) {
        $safeActive = Escape-SqlIdentifier -Name $ActiveColumn
        $activeExpression = "SUM(CASE WHEN COALESCE($safeActive, 1) = 1 THEN 1 ELSE 0 END)"
    }

    if ([string]::IsNullOrWhiteSpace($TimestampColumn)) {
        return @"
SELECT
    '$TableName' AS cache_table,
    COUNT(*) AS total_rows,
    $activeExpression AS active_rows,
    0 AS stale_rows,
    0 AS serveable_stale_rows,
    0 AS expired_rows,
    COUNT(*) AS missing_timestamp_rows,
    NULL AS newest_cache_timestamp,
    NULL AS oldest_cache_timestamp
FROM $safeTable
"@
    }

    $safeTimestamp = Escape-SqlIdentifier -Name $TimestampColumn

    return @"
SELECT
    '$TableName' AS cache_table,
    COUNT(*) AS total_rows,
    $activeExpression AS active_rows,
    SUM(
        CASE
            WHEN $safeTimestamp IS NULL THEN 1
            WHEN $safeTimestamp < DATE_SUB(NOW(), INTERVAL $FreshWindowMinutes MINUTE) THEN 1
            ELSE 0
        END
    ) AS stale_rows,
    SUM(
        CASE
            WHEN $safeTimestamp IS NOT NULL
             AND $safeTimestamp < DATE_SUB(NOW(), INTERVAL $FreshWindowMinutes MINUTE)
             AND $safeTimestamp >= DATE_SUB(NOW(), INTERVAL $ServeableStaleWindowMinutes MINUTE)
            THEN 1
            ELSE 0
        END
    ) AS serveable_stale_rows,
    SUM(
        CASE
            WHEN $safeTimestamp IS NOT NULL
             AND $safeTimestamp < DATE_SUB(NOW(), INTERVAL $ServeableStaleWindowMinutes MINUTE)
            THEN 1
            ELSE 0
        END
    ) AS expired_rows,
    SUM(CASE WHEN $safeTimestamp IS NULL THEN 1 ELSE 0 END) AS missing_timestamp_rows,
    MAX($safeTimestamp) AS newest_cache_timestamp,
    MIN($safeTimestamp) AS oldest_cache_timestamp
FROM $safeTable
"@
}

function Get-PreferredTimestampColumn {
    [CmdletBinding()]
    param(
        [string[]]$ColumnNames
    )

    $preferred = @(
        "updated_at",
        "last_updated_at",
        "last_refresh_at",
        "last_refreshed_at",
        "refreshed_at",
        "materialized_at",
        "cached_at",
        "last_seen_at",
        "created_at"
    )

    foreach ($candidate in $preferred) {
        if ($ColumnNames -contains $candidate) {
            return $candidate
        }
    }

    return ""
}

function Get-PreferredActiveColumn {
    [CmdletBinding()]
    param(
        [string[]]$ColumnNames
    )

    $preferred = @(
        "is_active",
        "active",
        "is_available",
        "available"
    )

    foreach ($candidate in $preferred) {
        if ($ColumnNames -contains $candidate) {
            return $candidate
        }
    }

    return ""
}

function Get-CacheMetricDbRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [string]$DatabaseKey = "content",

        [string]$Endpoint = "",

        [string]$Token = "",

        [int]$TimeoutSec = 30,

        [int]$FreshWindowMinutes = 30,

        [int]$ServeableStaleWindowMinutes = 1440
    )

    $dbQueryModule = Join-Path $RepoRoot "tools\common\DbQuery.psm1"

    if (-not (Test-Path -LiteralPath $dbQueryModule)) {
        throw "DbQuery module not found at: $dbQueryModule"
    }

    Import-Module $dbQueryModule -Force

    $discoveryResult = Invoke-ReadOnlyDbQuery `
        -DatabaseKey $DatabaseKey `
        -Sql (Get-CacheDiscoverySql) `
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

    $knownTables = @(
        "home_ppv_event_schedule_cache",
        "live_channel_version_pool",
        "live_247_artwork_cache",
        "vod_metadata_ext",
        "series_metadata_ext"
    )

    $candidateTables = @()

    foreach ($tableName in $knownTables) {
        if ($tableMap.ContainsKey($tableName)) {
            $candidateTables += $tableName
        }
    }

    if ($candidateTables.Count -eq 0) {
        return [pscustomobject]@{
            cache_scope = "known_app_caches"
            cache_table_count = 0
            total_rows = 0
            active_rows = 0
            stale_rows = 0
            serveable_stale_rows = 0
            expired_rows = 0
            missing_timestamp_rows = 0
            refresh_needed_rows = 0
            stale_ratio = 0
            newest_cache_timestamp = $null
            oldest_cache_timestamp = $null
        }
    }

    $cacheTableCount = 0
    $totalRows = 0
    $activeRows = 0
    $staleRows = 0
    $serveableStaleRows = 0
    $expiredRows = 0
    $missingTimestampRows = 0
    $refreshNeededRows = 0
    $newestCacheTimestamp = $null
    $oldestCacheTimestamp = $null

    foreach ($tableName in $candidateTables) {
        $columns = @($tableMap[$tableName].ToArray())
        $timestampColumn = Get-PreferredTimestampColumn -ColumnNames $columns
        $activeColumn = Get-PreferredActiveColumn -ColumnNames $columns

        $sql = Get-CacheRowSql `
            -TableName $tableName `
            -TimestampColumn $timestampColumn `
            -ActiveColumn $activeColumn `
            -FreshWindowMinutes $FreshWindowMinutes `
            -ServeableStaleWindowMinutes $ServeableStaleWindowMinutes

        $queryResult = Invoke-ReadOnlyDbQuery `
            -DatabaseKey $DatabaseKey `
            -Sql $sql `
            -Endpoint $Endpoint `
            -Token $Token `
            -TimeoutSec $TimeoutSec

        $rows = Convert-ToArraySafe -Value $queryResult.rows

        if ($rows.Count -eq 0) {
            continue
        }

        $row = $rows[0]
        $cacheTableCount += 1
        $rowTotal = Convert-ToIntSafe -Value (Get-PropertyValue -Object $row -Names @("total_rows"))
        $rowActive = Convert-ToIntSafe -Value (Get-PropertyValue -Object $row -Names @("active_rows"))
        $rowStale = Convert-ToIntSafe -Value (Get-PropertyValue -Object $row -Names @("stale_rows"))
        $rowServeable = Convert-ToIntSafe -Value (Get-PropertyValue -Object $row -Names @("serveable_stale_rows"))
        $rowExpired = Convert-ToIntSafe -Value (Get-PropertyValue -Object $row -Names @("expired_rows"))
        $rowMissing = Convert-ToIntSafe -Value (Get-PropertyValue -Object $row -Names @("missing_timestamp_rows"))

        $totalRows += $rowTotal
        $activeRows += $rowActive
        $staleRows += $rowStale
        $serveableStaleRows += $rowServeable
        $expiredRows += $rowExpired
        $missingTimestampRows += $rowMissing

        if ($rowStale -gt 0) {
            $refreshNeededRows += 1
        }

        $rowNewest = Convert-ToDateTimeSafe -Value (Get-PropertyValue -Object $row -Names @("newest_cache_timestamp"))
        $rowOldest = Convert-ToDateTimeSafe -Value (Get-PropertyValue -Object $row -Names @("oldest_cache_timestamp"))

        if ($null -ne $rowNewest) {
            if ($null -eq $newestCacheTimestamp -or $rowNewest -gt $newestCacheTimestamp) {
                $newestCacheTimestamp = $rowNewest
            }
        }

        if ($null -ne $rowOldest) {
            if ($null -eq $oldestCacheTimestamp -or $rowOldest -lt $oldestCacheTimestamp) {
                $oldestCacheTimestamp = $rowOldest
            }
        }
    }

    $staleRatio = [decimal]0

    if ($totalRows -gt 0 -and $staleRows -gt 0) {
        $staleRatio = [decimal]::Round(([decimal]$staleRows / [decimal]$totalRows), 6)
    }

    return [pscustomobject]@{
        cache_scope = "known_app_caches"
        cache_table_count = $cacheTableCount
        total_rows = $totalRows
        active_rows = $activeRows
        stale_rows = $staleRows
        serveable_stale_rows = $serveableStaleRows
        expired_rows = $expiredRows
        missing_timestamp_rows = $missingTimestampRows
        refresh_needed_rows = $refreshNeededRows
        stale_ratio = $staleRatio
        newest_cache_timestamp = $newestCacheTimestamp
        oldest_cache_timestamp = $oldestCacheTimestamp
    }
}

function Get-CacheMetrics {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$MetricRow,

        [string]$Mode,

        [decimal]$MaxStaleRatio,

        [string]$SourceName
    )

    $status = "dry_run"
    $cacheStaleServingStatus = "not_run"
    $servedFrom = "dry_run"
    $cacheScope = "known_app_caches"
    $cacheTableCount = 0
    $totalRows = 0
    $activeRows = 0
    $staleRows = 0
    $serveableStaleRows = 0
    $expiredRows = 0
    $missingTimestampRows = 0
    $refreshNeededRows = 0
    $staleRatio = [decimal]0
    $newestCacheTimestamp = $null
    $oldestCacheTimestamp = $null
    $validationNote = "local-first scaffold; no DB query performed"

    if ($null -ne $MetricRow) {
        $cacheScopeRaw = Get-PropertyValue -Object $MetricRow -Names @("cache_scope", "scope", "screen_type")
        if ($null -ne $cacheScopeRaw -and -not [string]::IsNullOrWhiteSpace([string]$cacheScopeRaw)) {
            $cacheScope = ([string]$cacheScopeRaw).Trim()
        }

        $cacheTableCount = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @("cache_table_count", "table_count"))
        $totalRows = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @("total_rows", "row_count", "cache_row_count"))
        $activeRows = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @("active_rows", "fresh_rows"))
        $staleRows = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @("stale_rows", "stale_cache_rows"))
        $serveableStaleRows = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @("serveable_stale_rows", "stale_serveable_rows", "servable_stale_rows"))
        $expiredRows = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @("expired_rows", "expired_cache_rows"))
        $missingTimestampRows = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @("missing_timestamp_rows", "missing_cache_timestamp_rows"))
        $refreshNeededRows = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @("refresh_needed_rows", "refresh_needed_count"))
        $staleRatio = Convert-ToDecimalSafe -Value (Get-PropertyValue -Object $MetricRow -Names @("stale_ratio", "cache_stale_ratio"))

        $newestCacheTimestamp = Convert-ToDateTimeSafe -Value (Get-PropertyValue -Object $MetricRow -Names @("newest_cache_timestamp", "max_updated_at"))
        $oldestCacheTimestamp = Convert-ToDateTimeSafe -Value (Get-PropertyValue -Object $MetricRow -Names @("oldest_cache_timestamp", "min_updated_at"))

        if ($totalRows -gt 0 -and $staleRatio -eq 0 -and $staleRows -gt 0) {
            $staleRatio = [decimal]::Round(([decimal]$staleRows / [decimal]$totalRows), 6)
        }

        $status = "ok"
        $cacheStaleServingStatus = "pass"
        $servedFrom = "cache_active"
        $validationNote = "cache rows are fresh or stale-serving is within configured bounds"

        if ($cacheTableCount -le 0) {
            $status = "warning"
            $cacheStaleServingStatus = "warning"
            $servedFrom = "no_cache_tables_found"
            $validationNote = "no known app cache tables were found"
        }
        elseif ($totalRows -le 0) {
            $status = "warning"
            $cacheStaleServingStatus = "warning"
            $servedFrom = "cache_empty"
            $validationNote = "known app cache tables exist but have no cache rows"
        }
        elseif ($expiredRows -gt 0 -and $serveableStaleRows -le 0) {
            $status = "warning"
            $cacheStaleServingStatus = "warning"
            $servedFrom = "cache_expired"
            $validationNote = "expired cache rows exist without serveable stale fallback"
        }
        elseif ($staleRatio -gt $MaxStaleRatio) {
            $status = "warning"
            $cacheStaleServingStatus = "warning"
            $servedFrom = "cache_stale_refreshing"
            $validationNote = "stale cache ratio exceeds configured threshold"
        }
        elseif ($staleRows -gt 0) {
            $status = "ok"
            $cacheStaleServingStatus = "pass"
            $servedFrom = "cache_stale_refreshing"
            $validationNote = "stale cache rows exist but remain within serveable threshold"
        }
    }

    return [ordered]@{
        status = $status
        cache_stale_serving_status = $cacheStaleServingStatus
        served_from = $servedFrom
        cache_scope = $cacheScope
        cache_table_count = $cacheTableCount
        total_rows = $totalRows
        active_rows = $activeRows
        stale_rows = $staleRows
        serveable_stale_rows = $serveableStaleRows
        expired_rows = $expiredRows
        missing_timestamp_rows = $missingTimestampRows
        refresh_needed_rows = $refreshNeededRows
        stale_ratio = $staleRatio
        max_stale_ratio = $MaxStaleRatio
        newest_cache_timestamp = $newestCacheTimestamp
        oldest_cache_timestamp = $oldestCacheTimestamp
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

$script:RunId = New-RunId -Prefix "cache-stale-serving"

try {
    $enabled = Test-KillSwitch -Name $KillSwitchName -DefaultEnabled $true

    if (-not $enabled) {
        Write-JobLog `
            -RunId $script:RunId `
            -JobName "check_cache_stale_serving" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -Status "job_skipped" `
            -EventType "job_skipped" `
            -SourceName "cache_stale_serving" `
            -DurationMs (Get-DurationMs -Start $script:StartedAt) `
            -Data @{
                kill_switch_name = $KillSwitchName
                kill_switch_enabled = $false
                reason = "async cache refresh disabled by kill switch"
                mode = $Mode
            } `
            -LogRoot $LogRoot | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName "check_cache_stale_serving" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName "cache_stale_serving_status" `
            -P0Item "P0.4" `
            -SignalValue "disabled" `
            -Status "disabled" `
            -AllowedValues "pass|warning|fail|not_run|disabled" `
            -SourceTableOrEndpoint "tools/workers/check_cache_stale_serving.ps1" `
            -Data @{
                dashboard_panel = "Cache Health"
                widget_key = "cache.stale_serving.status"
                owner = "SRE"
                kill_switch_name = $KillSwitchName
            } `
            -LogRoot $LogRoot | Out-Null

        Write-Output "SKIPPED: $KillSwitchName is disabled. run_id=$script:RunId"
        exit 0
    }

    Write-JobLog `
        -RunId $script:RunId `
        -JobName "check_cache_stale_serving" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -Status "job_started" `
        -EventType "job_started" `
        -SourceName "cache_stale_serving" `
        -Data @{
            kill_switch_name = $KillSwitchName
            mode = $Mode
            database_key = $DatabaseKey
            fresh_window_minutes = $FreshWindowMinutes
            serveable_stale_window_minutes = $ServeableStaleWindowMinutes
            max_stale_ratio = $MaxStaleRatio
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Heartbeat `
        -RunId $script:RunId `
        -JobName "check_cache_stale_serving" `
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
        -JobName "check_cache_stale_serving" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "worker_heartbeat_status" `
        -P0Item "P0.2" `
        -SignalValue "ok" `
        -Status "ok" `
        -AllowedValues "ok|missed|failed|disabled" `
        -SourceTableOrEndpoint "tools/workers/check_cache_stale_serving.ps1" `
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
        $snapshot = Read-CacheSnapshot -Path $resolvedInput
        $metricRow = Get-SnapshotMetricRow -Snapshot $snapshot
        $sourceName = "snapshot_input"
    }
    elseif ($Mode -eq "DbQuery") {
        $metricRow = Get-CacheMetricDbRow `
            -RepoRoot $repoRoot `
            -DatabaseKey $DatabaseKey `
            -Endpoint $DbQueryEndpoint `
            -Token $DbQueryToken `
            -TimeoutSec $QueryTimeoutSec `
            -FreshWindowMinutes $FreshWindowMinutes `
            -ServeableStaleWindowMinutes $ServeableStaleWindowMinutes

        $sourceName = "dog_open_proc:content.known_app_caches"
    }

    $metrics = Get-CacheMetrics `
        -MetricRow $metricRow `
        -Mode $Mode `
        -MaxStaleRatio $MaxStaleRatio `
        -SourceName $sourceName

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "check_cache_stale_serving" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "cache_stale_serving_status" `
        -P0Item "P0.4" `
        -SignalValue ([string]$metrics.cache_stale_serving_status) `
        -Status ([string]$metrics.status) `
        -AllowedValues "pass|warning|fail|not_run|disabled" `
        -SourceTableOrEndpoint "tools/workers/check_cache_stale_serving.ps1" `
        -Data @{
            dashboard_panel = "Cache Health"
            widget_key = "cache.stale_serving.status"
            owner = "SRE"
            kill_switch_name = $KillSwitchName
            mode = $Mode
            source_name = $metrics.source_name
            cache_scope = $metrics.cache_scope
            served_from = $metrics.served_from
            cache_table_count = $metrics.cache_table_count
            total_rows = $metrics.total_rows
            active_rows = $metrics.active_rows
            stale_rows = $metrics.stale_rows
            serveable_stale_rows = $metrics.serveable_stale_rows
            expired_rows = $metrics.expired_rows
            missing_timestamp_rows = $metrics.missing_timestamp_rows
            refresh_needed_rows = $metrics.refresh_needed_rows
            stale_ratio = $metrics.stale_ratio
            validation_note = $metrics.validation_note
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "check_cache_stale_serving" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "cache_stale_ratio" `
        -P0Item "P0.4" `
        -SignalValue ([string]$metrics.stale_ratio) `
        -ValueNum ([decimal]$metrics.stale_ratio) `
        -Status ([string]$metrics.status) `
        -AllowedValues "0..1" `
        -SourceTableOrEndpoint "tools/workers/check_cache_stale_serving.ps1" `
        -Data @{
            dashboard_panel = "Cache Health"
            widget_key = "cache.stale_ratio"
            owner = "SRE"
            kill_switch_name = $KillSwitchName
            mode = $Mode
            source_name = $metrics.source_name
            cache_scope = $metrics.cache_scope
            stale_rows = $metrics.stale_rows
            total_rows = $metrics.total_rows
            max_stale_ratio = $metrics.max_stale_ratio
            refresh_needed_rows = $metrics.refresh_needed_rows
        } `
        -LogRoot $LogRoot | Out-Null

    Write-JobLog `
        -RunId $script:RunId `
        -JobName "check_cache_stale_serving" `
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
            cache_stale_serving_status = $metrics.cache_stale_serving_status
            served_from = $metrics.served_from
            cache_scope = $metrics.cache_scope
            cache_table_count = $metrics.cache_table_count
            total_rows = $metrics.total_rows
            active_rows = $metrics.active_rows
            stale_rows = $metrics.stale_rows
            serveable_stale_rows = $metrics.serveable_stale_rows
            expired_rows = $metrics.expired_rows
            missing_timestamp_rows = $metrics.missing_timestamp_rows
            refresh_needed_rows = $metrics.refresh_needed_rows
            stale_ratio = $metrics.stale_ratio
            max_stale_ratio = $metrics.max_stale_ratio
            newest_cache_timestamp = $metrics.newest_cache_timestamp
            oldest_cache_timestamp = $metrics.oldest_cache_timestamp
            source_name = $metrics.source_name
            mode = $Mode
            validation_note = $metrics.validation_note
            note = "read-only cache stale-serving check; no DB writes performed"
        } `
        -LogRoot $LogRoot | Out-Null

    Write-Output "OK: cache stale-serving check completed. status=$($metrics.status) result=$($metrics.cache_stale_serving_status) served_from=$($metrics.served_from) cache_scope=$($metrics.cache_scope) total_rows=$($metrics.total_rows) stale_ratio=$($metrics.stale_ratio) refresh_needed_rows=$($metrics.refresh_needed_rows) mode=$Mode run_id=$script:RunId"
    exit 0
}
catch {
    $message = $_.Exception.Message
    $duration = Get-DurationMs -Start $script:StartedAt

    if ([string]::IsNullOrWhiteSpace($script:RunId)) {
        $script:RunId = "cache-stale-serving-failed-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
    }

    try {
        Write-JobLog `
            -RunId $script:RunId `
            -JobName "check_cache_stale_serving" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -Status "job_failed" `
            -EventType "job_failed" `
            -SourceName "cache_stale_serving" `
            -DurationMs $duration `
            -ErrorCode "CACHE_STALE_SERVING_FAILED" `
            -ErrorMessage $message `
            -Data @{
                kill_switch_name = $KillSwitchName
                mode = $Mode
                database_key = $DatabaseKey
            } `
            -LogRoot $LogRoot | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName "check_cache_stale_serving" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName "cache_stale_serving_status" `
            -P0Item "P0.4" `
            -SignalValue "fail" `
            -Status "failed" `
            -AllowedValues "pass|warning|fail|not_run|disabled" `
            -SourceTableOrEndpoint "tools/workers/check_cache_stale_serving.ps1" `
            -ErrorCode "CACHE_STALE_SERVING_FAILED" `
            -ErrorMessage $message `
            -Data @{
                dashboard_panel = "Cache Health"
                widget_key = "cache.stale_serving.status"
                owner = "SRE"
                kill_switch_name = $KillSwitchName
                mode = $Mode
            } `
            -LogRoot $LogRoot | Out-Null
    }
    catch {
        Write-Error "Cache stale-serving worker failed and failed to log error: $($_.Exception.Message)"
    }

    Write-Error "FAILED: cache stale-serving worker failed. run_id=$script:RunId error=$message"
    exit 1
}
