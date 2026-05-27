# MiraTV Playback Preflight Attribution Worker
# File: tools/workers/check_playback_preflight_attribution.ps1
# Purpose:
#   P0.7 playback preflight attribution scaffold + read-only DB-backed mode.
#   Establishes observable playback attribution coverage checks without mutating database tables.
#
# Current implementation:
#   - Supports DryRun, SnapshotInput, and DbQuery modes.
#   - DbQuery mode uses tools/common/DbQuery.psm1, which calls dog_open_proc.php.
#   - DbQuery mode adaptively discovers available Live/VOD/Series source tables and columns.
#   - Does not mutate database tables.
#
# Playback attribution philosophy:
#   Playback must be attributable before the client launches a player.
#   At minimum, playable inventory should be traceable to provider id/stream id context.
#   VOD/Series should also be able to resolve container/extension where available.
#
# Signals:
#   - playback_preflight_outcome
#   - attribution_coverage_percent
#   - worker_heartbeat_status
#
# Kill switch:
#   - ENABLE_PLAYBACK_ATTRIBUTION
#
# Required for DbQuery mode:
#   $env:DOG_OPEN_PROC_ENDPOINT = "https://miratv.club/_workers/api/series/dog_open_proc.php"
#   $env:DOG_OPEN_PROC_TOKEN = "<token>"
#
# Usage:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_playback_preflight_attribution.ps1" -Environment "dev"
#
# DbQuery:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_playback_preflight_attribution.ps1" -Environment "dev" -Mode "DbQuery"

[CmdletBinding()]
param(
    [string]$WorkerName = "playback_resolver",
    [string]$Component = "playback_resolver",
    [string]$Environment = "prod",
    [string]$KillSwitchName = "ENABLE_PLAYBACK_ATTRIBUTION",

    [ValidateSet("DryRun", "SnapshotInput", "DbQuery")]
    [string]$Mode = "DryRun",

    [string]$InputJsonPath = "",
    [string]$DatabaseKey = "content",
    [string]$DbQueryEndpoint = "",
    [string]$DbQueryToken = "",
    [int]$QueryTimeoutSec = 30,

    [decimal]$MinimumCoveragePercent = 95.0,
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

function Read-PlaybackSnapshot {
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

    if ($Snapshot.PSObject.Properties.Name -contains "playback") {
        $rows = Convert-ToArraySafe -Value $Snapshot.playback
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

function Get-TableDiscoverySql {
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
  AND t.TABLE_NAME IN (
      'live_channels',
      'vod',
      'series',
      'series_episodes',
      'episodes',
      'vod_metadata_ext',
      'series_metadata_ext'
  )
ORDER BY t.TABLE_NAME, c.ORDINAL_POSITION
"@
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

function Get-NonBlankSqlExpression {
    [CmdletBinding()]
    param(
        [string]$ColumnName
    )

    if ([string]::IsNullOrWhiteSpace($ColumnName)) {
        return "0"
    }

    $safe = Escape-SqlIdentifier -Name $ColumnName
    return "($safe IS NOT NULL AND TRIM(CAST($safe AS CHAR)) <> '')"
}

function Get-ActiveWhereExpression {
    [CmdletBinding()]
    param(
        [string[]]$ColumnNames
    )

    $activeColumn = Get-PreferredColumn -ColumnNames $ColumnNames -PreferredNames @(
        "is_active",
        "active",
        "enabled"
    )

    if ([string]::IsNullOrWhiteSpace($activeColumn)) {
        return "1 = 1"
    }

    $safeActive = Escape-SqlIdentifier -Name $activeColumn
    return "COALESCE($safeActive, 1) = 1"
}

function Get-LivePlaybackMetricSql {
    [CmdletBinding()]
    param(
        [string[]]$ColumnNames
    )

    $providerIdColumn = Get-PreferredColumn -ColumnNames $ColumnNames -PreferredNames @(
        "provider_stream_id",
        "stream_id",
        "provider_id",
        "id"
    )

    $nameColumn = Get-PreferredColumn -ColumnNames $ColumnNames -PreferredNames @(
        "name",
        "title",
        "channel_name"
    )

    $containerColumn = Get-PreferredColumn -ColumnNames $ColumnNames -PreferredNames @(
        "stream_type",
        "container_extension",
        "container",
        "extension"
    )

    $httpStatusColumn = Get-PreferredColumn -ColumnNames $ColumnNames -PreferredNames @(
        "last_http_status",
        "http_status",
        "last_playback_status"
    )

    $providerIdNonBlank = Get-NonBlankSqlExpression -ColumnName $providerIdColumn
    $nameNonBlank = Get-NonBlankSqlExpression -ColumnName $nameColumn
    $containerNonBlank = Get-NonBlankSqlExpression -ColumnName $containerColumn
    $where = Get-ActiveWhereExpression -ColumnNames $ColumnNames

    $blocked406Expr = "0"
    if (-not [string]::IsNullOrWhiteSpace($httpStatusColumn)) {
        $safeHttp = Escape-SqlIdentifier -Name $httpStatusColumn
        $blocked406Expr = "SUM(CASE WHEN CAST($safeHttp AS CHAR) = '406' THEN 1 ELSE 0 END)"
    }

    return @"
SELECT
    'live' AS media_type,
    COUNT(*) AS total_candidates,
    SUM(CASE WHEN $providerIdNonBlank AND $nameNonBlank THEN 1 ELSE 0 END) AS attributed_count,
    SUM(CASE WHEN NOT ($providerIdNonBlank) THEN 1 ELSE 0 END) AS missing_provider_id_count,
    0 AS missing_container_count,
    SUM(CASE WHEN $containerNonBlank THEN 1 ELSE 0 END) AS container_known_count,
    $blocked406Expr AS blocked_406_count
FROM live_channels
WHERE $where
"@
}

function Get-VodPlaybackMetricSql {
    [CmdletBinding()]
    param(
        [string[]]$ColumnNames
    )

    $providerIdColumn = Get-PreferredColumn -ColumnNames $ColumnNames -PreferredNames @(
        "provider_vod_id",
        "vod_id",
        "stream_id",
        "provider_id",
        "id"
    )

    $titleColumn = Get-PreferredColumn -ColumnNames $ColumnNames -PreferredNames @(
        "title",
        "name",
        "movie_name"
    )

    $containerColumn = Get-PreferredColumn -ColumnNames $ColumnNames -PreferredNames @(
        "container_extension",
        "container",
        "extension",
        "stream_type"
    )

    $httpStatusColumn = Get-PreferredColumn -ColumnNames $ColumnNames -PreferredNames @(
        "last_http_status",
        "http_status",
        "last_playback_status"
    )

    $providerIdNonBlank = Get-NonBlankSqlExpression -ColumnName $providerIdColumn
    $titleNonBlank = Get-NonBlankSqlExpression -ColumnName $titleColumn
    $containerNonBlank = Get-NonBlankSqlExpression -ColumnName $containerColumn
    $where = Get-ActiveWhereExpression -ColumnNames $ColumnNames

    $blocked406Expr = "0"
    if (-not [string]::IsNullOrWhiteSpace($httpStatusColumn)) {
        $safeHttp = Escape-SqlIdentifier -Name $httpStatusColumn
        $blocked406Expr = "SUM(CASE WHEN CAST($safeHttp AS CHAR) = '406' THEN 1 ELSE 0 END)"
    }

    return @"
SELECT
    'vod' AS media_type,
    COUNT(*) AS total_candidates,
    SUM(CASE WHEN $providerIdNonBlank AND $titleNonBlank THEN 1 ELSE 0 END) AS attributed_count,
    SUM(CASE WHEN NOT ($providerIdNonBlank) THEN 1 ELSE 0 END) AS missing_provider_id_count,
    SUM(CASE WHEN NOT ($containerNonBlank) THEN 1 ELSE 0 END) AS missing_container_count,
    SUM(CASE WHEN $containerNonBlank THEN 1 ELSE 0 END) AS container_known_count,
    $blocked406Expr AS blocked_406_count
FROM vod
WHERE $where
"@
}

function Get-SeriesPlaybackMetricSql {
    [CmdletBinding()]
    param(
        [string[]]$ColumnNames
    )

    $providerIdColumn = Get-PreferredColumn -ColumnNames $ColumnNames -PreferredNames @(
        "provider_series_id",
        "series_id",
        "stream_id",
        "provider_id",
        "id"
    )

    $titleColumn = Get-PreferredColumn -ColumnNames $ColumnNames -PreferredNames @(
        "title",
        "name",
        "series_name"
    )

    $containerColumn = Get-PreferredColumn -ColumnNames $ColumnNames -PreferredNames @(
        "container_extension",
        "container",
        "extension",
        "stream_type"
    )

    $httpStatusColumn = Get-PreferredColumn -ColumnNames $ColumnNames -PreferredNames @(
        "last_http_status",
        "http_status",
        "last_playback_status"
    )

    $providerIdNonBlank = Get-NonBlankSqlExpression -ColumnName $providerIdColumn
    $titleNonBlank = Get-NonBlankSqlExpression -ColumnName $titleColumn
    $containerNonBlank = Get-NonBlankSqlExpression -ColumnName $containerColumn
    $where = Get-ActiveWhereExpression -ColumnNames $ColumnNames

    $blocked406Expr = "0"
    if (-not [string]::IsNullOrWhiteSpace($httpStatusColumn)) {
        $safeHttp = Escape-SqlIdentifier -Name $httpStatusColumn
        $blocked406Expr = "SUM(CASE WHEN CAST($safeHttp AS CHAR) = '406' THEN 1 ELSE 0 END)"
    }

    return @"
SELECT
    'series' AS media_type,
    COUNT(*) AS total_candidates,
    SUM(CASE WHEN $providerIdNonBlank AND $titleNonBlank THEN 1 ELSE 0 END) AS attributed_count,
    SUM(CASE WHEN NOT ($providerIdNonBlank) THEN 1 ELSE 0 END) AS missing_provider_id_count,
    SUM(CASE WHEN NOT ($containerNonBlank) THEN 1 ELSE 0 END) AS missing_container_count,
    SUM(CASE WHEN $containerNonBlank THEN 1 ELSE 0 END) AS container_known_count,
    $blocked406Expr AS blocked_406_count
FROM series
WHERE $where
"@
}

function Get-PlaybackMetricDbRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [string]$DatabaseKey = "content",

        [string]$Endpoint = "",

        [string]$Token = "",

        [int]$TimeoutSec = 30
    )

    $dbQueryModule = Join-Path $RepoRoot "tools\common\DbQuery.psm1"

    if (-not (Test-Path -LiteralPath $dbQueryModule)) {
        throw "DbQuery module not found at: $dbQueryModule"
    }

    Import-Module $dbQueryModule -Force

    $discoveryResult = Invoke-ReadOnlyDbQuery `
        -DatabaseKey $DatabaseKey `
        -Sql (Get-TableDiscoverySql) `
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

    $parts = @()

    if ($tableMap.ContainsKey("live_channels")) {
        $parts += Get-LivePlaybackMetricSql -ColumnNames @($tableMap["live_channels"].ToArray())
    }

    if ($tableMap.ContainsKey("vod")) {
        $parts += Get-VodPlaybackMetricSql -ColumnNames @($tableMap["vod"].ToArray())
    }

    if ($tableMap.ContainsKey("series")) {
        $parts += Get-SeriesPlaybackMetricSql -ColumnNames @($tableMap["series"].ToArray())
    }

    if ($parts.Count -eq 0) {
        return [pscustomobject]@{
            total_playback_candidates = 0
            attributed_count = 0
            unattributed_count = 0
            missing_provider_id_count = 0
            missing_container_count = 0
            container_known_count = 0
            blocked_406_count = 0
            coverage_percent = 0
            source_table_count = 0
        }
    }

    $unionSql = $parts -join "`nUNION ALL`n"

    $metricSql = @"
SELECT
    SUM(total_candidates) AS total_playback_candidates,
    SUM(attributed_count) AS attributed_count,
    SUM(total_candidates - attributed_count) AS unattributed_count,
    SUM(missing_provider_id_count) AS missing_provider_id_count,
    SUM(missing_container_count) AS missing_container_count,
    SUM(container_known_count) AS container_known_count,
    SUM(blocked_406_count) AS blocked_406_count,
    COUNT(*) AS source_table_count,
    CASE
        WHEN SUM(total_candidates) > 0 THEN ROUND((SUM(attributed_count) / SUM(total_candidates)) * 100, 3)
        ELSE 0
    END AS coverage_percent
FROM
(
$unionSql
) playback_metrics
"@

    $queryResult = Invoke-ReadOnlyDbQuery `
        -DatabaseKey $DatabaseKey `
        -Sql $metricSql `
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
        throw "DbQuery returned zero rows for playback preflight attribution query."
    }

    return $rows[0]
}

function Get-PlaybackMetrics {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$MetricRow,

        [string]$Mode,

        [decimal]$MinimumCoveragePercent,

        [string]$SourceName
    )

    $status = "dry_run"
    $playbackOutcome = "dry_run"
    $totalPlaybackCandidates = 0
    $attributedCount = 0
    $unattributedCount = 0
    $missingProviderIdCount = 0
    $missingContainerCount = 0
    $containerKnownCount = 0
    $blocked406Count = 0
    $sourceTableCount = 0
    $coveragePercent = [decimal]0
    $validationNote = "local-first scaffold; no DB query performed"

    if ($null -ne $MetricRow) {
        $totalPlaybackCandidates = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @(
            "total_playback_candidates",
            "total_candidates",
            "candidate_count"
        ))

        $attributedCount = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @(
            "attributed_count",
            "attributed_rows"
        ))

        $unattributedCount = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @(
            "unattributed_count",
            "unattributed_rows"
        ))

        $missingProviderIdCount = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @(
            "missing_provider_id_count",
            "missing_provider_count"
        ))

        $missingContainerCount = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @(
            "missing_container_count",
            "missing_extension_count"
        ))

        $containerKnownCount = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @(
            "container_known_count",
            "container_resolved_count"
        ))

        $blocked406Count = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @(
            "blocked_406_count",
            "http_406_count"
        ))

        $sourceTableCount = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @(
            "source_table_count",
            "table_count"
        ))

        $coveragePercent = Convert-ToDecimalSafe -Value (Get-PropertyValue -Object $MetricRow -Names @(
            "coverage_percent",
            "attribution_coverage_percent"
        ))

        if ($totalPlaybackCandidates -gt 0) {
            if ($unattributedCount -eq 0 -and $attributedCount -lt $totalPlaybackCandidates) {
                $unattributedCount = $totalPlaybackCandidates - $attributedCount
            }

            if ($coveragePercent -eq 0 -and $attributedCount -gt 0) {
                $coveragePercent = [decimal]::Round(([decimal]$attributedCount / [decimal]$totalPlaybackCandidates) * 100, 3)
            }
        }

        $status = "ok"
        $playbackOutcome = "pass"
        $validationNote = "playback attribution coverage is within configured threshold"

        if ($sourceTableCount -le 0 -or $totalPlaybackCandidates -le 0) {
            $status = "warning"
            $playbackOutcome = "warning"
            $validationNote = "no playback candidate source rows were found"
        }
        elseif ($coveragePercent -lt $MinimumCoveragePercent) {
            $status = "warning"
            $playbackOutcome = "warning"
            $validationNote = "playback attribution coverage is below configured threshold"
        }
    }

    return [ordered]@{
        status = $status
        playback_preflight_outcome = $playbackOutcome
        coverage_percent = $coveragePercent

        # Compatibility field for contract/dashboard naming.
        attribution_coverage_percent = $coveragePercent

        total_playback_candidates = $totalPlaybackCandidates
        attributed_count = $attributedCount
        unattributed_count = $unattributedCount
        missing_provider_id_count = $missingProviderIdCount
        missing_container_count = $missingContainerCount
        container_known_count = $containerKnownCount
        blocked_406_count = $blocked406Count
        source_table_count = $sourceTableCount
        minimum_coverage_percent = $MinimumCoveragePercent
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

$script:RunId = New-RunId -Prefix "playback-preflight"

try {
    $enabled = Test-KillSwitch -Name $KillSwitchName -DefaultEnabled $true

    if (-not $enabled) {
        Write-JobLog `
            -RunId $script:RunId `
            -JobName "check_playback_preflight_attribution" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -Status "job_skipped" `
            -EventType "job_skipped" `
            -SourceName "playback_preflight" `
            -DurationMs (Get-DurationMs -Start $script:StartedAt) `
            -Data @{
                kill_switch_name = $KillSwitchName
                kill_switch_enabled = $false
                reason = "playback attribution disabled by kill switch"
                mode = $Mode
            } `
            -LogRoot $LogRoot | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName "check_playback_preflight_attribution" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName "playback_preflight_outcome" `
            -P0Item "P0.7" `
            -SignalValue "disabled" `
            -Status "disabled" `
            -AllowedValues "pass|warning|fail|not_run|disabled" `
            -SourceTableOrEndpoint "tools/workers/check_playback_preflight_attribution.ps1" `
            -Data @{
                dashboard_panel = "Playback Health"
                widget_key = "playback.preflight.outcome"
                owner = "Playback Ops"
                kill_switch_name = $KillSwitchName
            } `
            -LogRoot $LogRoot | Out-Null

        Write-Output "SKIPPED: $KillSwitchName is disabled. run_id=$script:RunId"
        exit 0
    }

    Write-JobLog `
        -RunId $script:RunId `
        -JobName "check_playback_preflight_attribution" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -Status "job_started" `
        -EventType "job_started" `
        -SourceName "playback_preflight" `
        -Data @{
            kill_switch_name = $KillSwitchName
            mode = $Mode
            database_key = $DatabaseKey
            minimum_coverage_percent = $MinimumCoveragePercent
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Heartbeat `
        -RunId $script:RunId `
        -JobName "check_playback_preflight_attribution" `
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
        -JobName "check_playback_preflight_attribution" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "worker_heartbeat_status" `
        -P0Item "P0.2" `
        -SignalValue "ok" `
        -Status "ok" `
        -AllowedValues "ok|missed|failed|disabled" `
        -SourceTableOrEndpoint "tools/workers/check_playback_preflight_attribution.ps1" `
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
        $snapshot = Read-PlaybackSnapshot -Path $resolvedInput
        $metricRow = Get-SnapshotMetricRow -Snapshot $snapshot
        $sourceName = "snapshot_input"
    }
    elseif ($Mode -eq "DbQuery") {
        $metricRow = Get-PlaybackMetricDbRow `
            -RepoRoot $repoRoot `
            -DatabaseKey $DatabaseKey `
            -Endpoint $DbQueryEndpoint `
            -Token $DbQueryToken `
            -TimeoutSec $QueryTimeoutSec

        $sourceName = "dog_open_proc:content.playback_sources"
    }

    $metrics = Get-PlaybackMetrics `
        -MetricRow $metricRow `
        -Mode $Mode `
        -MinimumCoveragePercent $MinimumCoveragePercent `
        -SourceName $sourceName

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "check_playback_preflight_attribution" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "playback_preflight_outcome" `
        -P0Item "P0.7" `
        -SignalValue ([string]$metrics.playback_preflight_outcome) `
        -Status ([string]$metrics.status) `
        -AllowedValues "pass|warning|fail|not_run|disabled" `
        -SourceTableOrEndpoint "tools/workers/check_playback_preflight_attribution.ps1" `
        -Data @{
            dashboard_panel = "Playback Health"
            widget_key = "playback.preflight.outcome"
            owner = "Playback Ops"
            kill_switch_name = $KillSwitchName
            mode = $Mode
            source_name = $metrics.source_name
            total_playback_candidates = $metrics.total_playback_candidates
            attributed_count = $metrics.attributed_count
            unattributed_count = $metrics.unattributed_count
            missing_provider_id_count = $metrics.missing_provider_id_count
            missing_container_count = $metrics.missing_container_count
            container_known_count = $metrics.container_known_count
            blocked_406_count = $metrics.blocked_406_count
            coverage_percent = $metrics.coverage_percent
            validation_note = $metrics.validation_note
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "check_playback_preflight_attribution" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "attribution_coverage_percent" `
        -P0Item "P0.7" `
        -SignalValue ([string]$metrics.attribution_coverage_percent) `
        -ValueNum ([decimal]$metrics.attribution_coverage_percent) `
        -Status ([string]$metrics.status) `
        -AllowedValues "0..100" `
        -SourceTableOrEndpoint "tools/workers/check_playback_preflight_attribution.ps1" `
        -Data @{
            dashboard_panel = "Playback Health"
            widget_key = "playback.attribution.coverage_percent"
            owner = "Playback Ops"
            kill_switch_name = $KillSwitchName
            mode = $Mode
            source_name = $metrics.source_name
            total_playback_candidates = $metrics.total_playback_candidates
            attributed_count = $metrics.attributed_count
            unattributed_count = $metrics.unattributed_count
            minimum_coverage_percent = $metrics.minimum_coverage_percent
        } `
        -LogRoot $LogRoot | Out-Null

    Write-JobLog `
        -RunId $script:RunId `
        -JobName "check_playback_preflight_attribution" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -Status "job_completed" `
        -EventType "job_completed" `
        -SourceName ([string]$metrics.source_name) `
        -SourceRowCount ([int]$metrics.total_playback_candidates) `
        -RowsInserted 0 `
        -RowsUpdated 0 `
        -RowsSkipped ([int]$metrics.total_playback_candidates) `
        -RowsFailed 0 `
        -DurationMs (Get-DurationMs -Start $script:StartedAt) `
        -Data @{
            playback_preflight_outcome = $metrics.playback_preflight_outcome
            coverage_percent = $metrics.coverage_percent
            total_playback_candidates = $metrics.total_playback_candidates
            attributed_count = $metrics.attributed_count
            unattributed_count = $metrics.unattributed_count
            missing_provider_id_count = $metrics.missing_provider_id_count
            missing_container_count = $metrics.missing_container_count
            container_known_count = $metrics.container_known_count
            blocked_406_count = $metrics.blocked_406_count
            source_table_count = $metrics.source_table_count
            minimum_coverage_percent = $metrics.minimum_coverage_percent
            source_name = $metrics.source_name
            mode = $Mode
            validation_note = $metrics.validation_note
            note = "read-only playback preflight attribution check; no DB writes performed"
        } `
        -LogRoot $LogRoot | Out-Null

    Write-Output "OK: playback preflight attribution check completed. outcome=$($metrics.playback_preflight_outcome) coverage_percent=$($metrics.coverage_percent) total_candidates=$($metrics.total_playback_candidates) unattributed_count=$($metrics.unattributed_count) missing_provider_id_count=$($metrics.missing_provider_id_count) missing_container_count=$($metrics.missing_container_count) blocked_406_count=$($metrics.blocked_406_count) mode=$Mode run_id=$script:RunId"
    exit 0
}
catch {
    $message = $_.Exception.Message
    $duration = Get-DurationMs -Start $script:StartedAt

    if ([string]::IsNullOrWhiteSpace($script:RunId)) {
        $script:RunId = "playback-preflight-failed-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
    }

    try {
        Write-JobLog `
            -RunId $script:RunId `
            -JobName "check_playback_preflight_attribution" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -Status "job_failed" `
            -EventType "job_failed" `
            -SourceName "playback_preflight" `
            -DurationMs $duration `
            -ErrorCode "PLAYBACK_PREFLIGHT_FAILED" `
            -ErrorMessage $message `
            -Data @{
                kill_switch_name = $KillSwitchName
                mode = $Mode
                database_key = $DatabaseKey
            } `
            -LogRoot $LogRoot | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName "check_playback_preflight_attribution" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName "playback_preflight_outcome" `
            -P0Item "P0.7" `
            -SignalValue "fail" `
            -Status "failed" `
            -AllowedValues "pass|warning|fail|not_run|disabled" `
            -SourceTableOrEndpoint "tools/workers/check_playback_preflight_attribution.ps1" `
            -ErrorCode "PLAYBACK_PREFLIGHT_FAILED" `
            -ErrorMessage $message `
            -Data @{
                dashboard_panel = "Playback Health"
                widget_key = "playback.preflight.outcome"
                owner = "Playback Ops"
                kill_switch_name = $KillSwitchName
                mode = $Mode
            } `
            -LogRoot $LogRoot | Out-Null
    }
    catch {
        Write-Error "Playback preflight worker failed and failed to log error: $($_.Exception.Message)"
    }

    Write-Error "FAILED: playback preflight attribution worker failed. run_id=$script:RunId error=$message"
    exit 1
}
