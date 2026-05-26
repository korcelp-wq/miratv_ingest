# MiraTV DB Quality Gates Worker
# File: tools/workers/run_db_quality_gates.ps1
# Purpose:
#   P0.5 automated DB quality gates scaffold + read-only DB-backed mode.
#   Establishes observable quality gates for app-eligible base live inventory.
#
# Current implementation:
#   - Supports DryRun, SnapshotInput, and DbQuery modes.
#   - DbQuery mode uses tools/common/DbQuery.psm1, which calls dog_open_proc.php.
#   - DbQuery mode evaluates the base live channel universe, not only the screen named "Live".
#   - Does not mutate database tables.
#
# Base live quality rule:
#   EPG/live quality is a global live_channels concern.
#   This worker evaluates all active app-eligible live_channels.
#   Screen-specific gates for live/24_7/ppv/soccer/aps/home can be added later.
#
# App-eligible exclusion rule:
#   Exclude intentionally low-value/noisy novelty rows from actionable quality counts:
#     - XMAS
#     - FIREPLACE
#     - AMBIENT
#     - VEVO
#
# Signals:
#   - quality_gate_result
#   - duplicate_ratio
#   - blank_key_ratio
#   - filter_diversity_score
#   - worker_heartbeat_status
#
# Kill switch:
#   - ENABLE_DB_QUALITY_GATE_AUTOMATION
#
# Required for DbQuery mode:
#   $env:DOG_OPEN_PROC_ENDPOINT = "https://miratv.club/_workers/api/series/dog_open_proc.php"
#   $env:DOG_OPEN_PROC_TOKEN = "<token>"
#
# Usage:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/run_db_quality_gates.ps1" -Environment "dev"
#
# DbQuery:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/run_db_quality_gates.ps1" -Environment "dev" -Mode "DbQuery"

[CmdletBinding()]
param(
    [string]$WorkerName = "db_quality_gate",
    [string]$Component = "db_quality_gate",
    [string]$Environment = "prod",
    [string]$KillSwitchName = "ENABLE_DB_QUALITY_GATE_AUTOMATION",

    [ValidateSet("DryRun", "SnapshotInput", "DbQuery")]
    [string]$Mode = "DryRun",

    [string]$InputJsonPath = "",
    [string]$DatabaseKey = "content",
    [string]$DbQueryEndpoint = "",
    [string]$DbQueryToken = "",
    [int]$QueryTimeoutSec = 30,

    [decimal]$MaxDuplicateRatio = 0.05,
    [decimal]$MaxBlankKeyRatio = 0.01,
    [int]$MinimumFilterDiversityScore = 2,
    [int]$HeartbeatIntervalSeconds = 86400,
    [int]$StaleAfterSeconds = 90000,
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

function Read-QualitySnapshot {
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

    if ($Snapshot.PSObject.Properties.Name -contains "screens") {
        $rows = Convert-ToArraySafe -Value $Snapshot.screens
        if ($rows.Count -gt 0) {
            return $rows[0]
        }
    }

    if ($Snapshot.PSObject.Properties.Name -contains "items") {
        $rows = Convert-ToArraySafe -Value $Snapshot.items
        if ($rows.Count -gt 0) {
            return $rows[0]
        }
    }

    return $Snapshot
}

function Get-LiveQualityGateSql {
    [CmdletBinding()]
    param()

    return @"
SELECT
    totals.screen_type,
    totals.total_rows,
    totals.excluded_rows,
    dup.duplicate_rows,
    blank.blank_key_rows,
    filters.filter_diversity_score,
    CASE
        WHEN totals.total_rows > 0 THEN ROUND(dup.duplicate_rows / totals.total_rows, 6)
        ELSE 0
    END AS duplicate_ratio,
    CASE
        WHEN totals.total_rows > 0 THEN ROUND(blank.blank_key_rows / totals.total_rows, 6)
        ELSE 0
    END AS blank_key_ratio
FROM
    (
        SELECT
            'live_channels' AS screen_type,
            COUNT(*) AS total_rows,
            SUM(
                CASE
                    WHEN UPPER(COALESCE(name, '')) LIKE 'XMAS|%'
                      OR UPPER(COALESCE(name, '')) LIKE '%FIREPLACE%'
                      OR UPPER(COALESCE(name, '')) LIKE '%AMBIENT%'
                      OR UPPER(COALESCE(name, '')) LIKE '%VEVO%'
                    THEN 1
                    ELSE 0
                END
            ) AS excluded_rows
        FROM live_channels
        WHERE COALESCE(is_active, 1) = 1
          AND UPPER(COALESCE(name, '')) NOT LIKE 'XMAS|%'
          AND UPPER(COALESCE(name, '')) NOT LIKE '%FIREPLACE%'
          AND UPPER(COALESCE(name, '')) NOT LIKE '%AMBIENT%'
          AND UPPER(COALESCE(name, '')) NOT LIKE '%VEVO%'
    ) totals
CROSS JOIN
    (
        SELECT
            COALESCE(SUM(dup_rows), 0) AS duplicate_rows
        FROM
            (
                SELECT
                    CASE
                        WHEN COUNT(*) > 1 THEN COUNT(*) - 1
                        ELSE 0
                    END AS dup_rows
                FROM live_channels
                WHERE COALESCE(is_active, 1) = 1
                  AND UPPER(COALESCE(name, '')) NOT LIKE 'XMAS|%'
                  AND UPPER(COALESCE(name, '')) NOT LIKE '%FIREPLACE%'
                  AND UPPER(COALESCE(name, '')) NOT LIKE '%AMBIENT%'
                  AND UPPER(COALESCE(name, '')) NOT LIKE '%VEVO%'
                  AND COALESCE(NULLIF(TRIM(clean_search_name), ''), NULLIF(TRIM(name), '')) IS NOT NULL
                GROUP BY COALESCE(NULLIF(TRIM(clean_search_name), ''), NULLIF(TRIM(name), ''))
                HAVING COUNT(*) > 1
            ) d
    ) dup
CROSS JOIN
    (
        SELECT
            SUM(
                CASE
                    WHEN provider_stream_id IS NULL
                      OR provider_stream_id = ''
                      OR name IS NULL
                      OR TRIM(name) = ''
                      OR COALESCE(NULLIF(TRIM(clean_search_name), ''), NULLIF(TRIM(name), '')) IS NULL
                    THEN 1
                    ELSE 0
                END
            ) AS blank_key_rows
        FROM live_channels
        WHERE COALESCE(is_active, 1) = 1
          AND UPPER(COALESCE(name, '')) NOT LIKE 'XMAS|%'
          AND UPPER(COALESCE(name, '')) NOT LIKE '%FIREPLACE%'
          AND UPPER(COALESCE(name, '')) NOT LIKE '%AMBIENT%'
          AND UPPER(COALESCE(name, '')) NOT LIKE '%VEVO%'
    ) blank
CROSS JOIN
    (
        SELECT
            COUNT(DISTINCT category_id) AS filter_diversity_score
        FROM live_channels
        WHERE COALESCE(is_active, 1) = 1
          AND category_id IS NOT NULL
          AND category_id <> ''
          AND UPPER(COALESCE(name, '')) NOT LIKE 'XMAS|%'
          AND UPPER(COALESCE(name, '')) NOT LIKE '%FIREPLACE%'
          AND UPPER(COALESCE(name, '')) NOT LIKE '%AMBIENT%'
          AND UPPER(COALESCE(name, '')) NOT LIKE '%VEVO%'
    ) filters
"@
}

function Get-LiveQualityGateDbRow {
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

    $sql = Get-LiveQualityGateSql

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
        throw "DbQuery returned zero rows for live quality gate query."
    }

    return $rows[0]
}

function Get-QualityGateMetrics {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$MetricRow,

        [string]$Mode,

        [decimal]$MaxDuplicateRatio,

        [decimal]$MaxBlankKeyRatio,

        [int]$MinimumFilterDiversityScore,

        [string]$SourceName
    )

    $status = "dry_run"
    $qualityGateResult = "not_run"
    $screenType = "live_channels"
    $totalRows = 0
    $excludedRows = 0
    $duplicateRows = 0
    $blankKeyRows = 0
    $duplicateRatio = [decimal]0
    $blankKeyRatio = [decimal]0
    $filterDiversityScore = 0
    $validationNote = "local-first scaffold; no DB query performed"

    if ($null -ne $MetricRow) {
        $screenTypeRaw = Get-PropertyValue -Object $MetricRow -Names @("screen_type", "screen", "page")

        if ($null -ne $screenTypeRaw -and -not [string]::IsNullOrWhiteSpace([string]$screenTypeRaw)) {
            $screenType = ([string]$screenTypeRaw).Trim()
        }

        $totalRows = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @(
            "total_rows",
            "total_count",
            "row_count"
        ))

        $excludedRows = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @(
            "excluded_rows",
            "excluded_count",
            "non_actionable_rows"
        ))

        $duplicateRows = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @(
            "duplicate_rows",
            "duplicate_count",
            "dupe_rows"
        ))

        $blankKeyRows = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @(
            "blank_key_rows",
            "missing_key_rows",
            "blank_rows"
        ))

        $duplicateRatio = Convert-ToDecimalSafe -Value (Get-PropertyValue -Object $MetricRow -Names @(
            "duplicate_ratio",
            "dupe_ratio",
            "duplicate_rate"
        ))

        $blankKeyRatio = Convert-ToDecimalSafe -Value (Get-PropertyValue -Object $MetricRow -Names @(
            "blank_key_ratio",
            "missing_key_ratio",
            "blank_keys_ratio"
        ))

        $filterDiversityScore = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @(
            "filter_diversity_score",
            "filter_count",
            "distinct_filter_count"
        ))

        if ($totalRows -gt 0) {
            if ($duplicateRatio -eq 0 -and $duplicateRows -gt 0) {
                $duplicateRatio = [decimal]::Round(([decimal]$duplicateRows / [decimal]$totalRows), 6)
            }

            if ($blankKeyRatio -eq 0 -and $blankKeyRows -gt 0) {
                $blankKeyRatio = [decimal]::Round(([decimal]$blankKeyRows / [decimal]$totalRows), 6)
            }
        }

        $status = "ok"
        $qualityGateResult = "pass"
        $validationNote = "base live channel quality metrics are within configured thresholds"

        if ($totalRows -le 0) {
            $status = "warning"
            $qualityGateResult = "warning"
            $validationNote = "no app-eligible live channel rows found"
        }
        elseif ($duplicateRatio -gt $MaxDuplicateRatio) {
            $status = "warning"
            $qualityGateResult = "warning"
            $validationNote = "duplicate ratio exceeds configured threshold"
        }
        elseif ($blankKeyRatio -gt $MaxBlankKeyRatio) {
            $status = "warning"
            $qualityGateResult = "warning"
            $validationNote = "blank key ratio exceeds configured threshold"
        }
        elseif ($filterDiversityScore -lt $MinimumFilterDiversityScore) {
            $status = "warning"
            $qualityGateResult = "warning"
            $validationNote = "filter diversity score is below configured minimum"
        }
    }

    return [ordered]@{
        status = $status
        quality_gate_result = $qualityGateResult
        screen_type = $screenType
        total_rows = $totalRows
        excluded_rows = $excludedRows
        duplicate_rows = $duplicateRows
        blank_key_rows = $blankKeyRows
        duplicate_ratio = $duplicateRatio
        blank_key_ratio = $blankKeyRatio
        filter_diversity_score = $filterDiversityScore
        max_duplicate_ratio = $MaxDuplicateRatio
        max_blank_key_ratio = $MaxBlankKeyRatio
        minimum_filter_diversity_score = $MinimumFilterDiversityScore
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

$script:RunId = New-RunId -Prefix "db-quality-gates"

try {
    $enabled = Test-KillSwitch -Name $KillSwitchName -DefaultEnabled $true

    if (-not $enabled) {
        Write-JobLog `
            -RunId $script:RunId `
            -JobName "run_db_quality_gates" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -Status "job_skipped" `
            -EventType "job_skipped" `
            -SourceName "db_quality_gates" `
            -DurationMs (Get-DurationMs -Start $script:StartedAt) `
            -Data @{
                kill_switch_name = $KillSwitchName
                kill_switch_enabled = $false
                reason = "DB quality gate automation disabled by kill switch"
                mode = $Mode
            } `
            -LogRoot $LogRoot | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName "run_db_quality_gates" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName "quality_gate_result" `
            -P0Item "P0.5" `
            -SignalValue "disabled" `
            -Status "disabled" `
            -AllowedValues "pass|fail|warning|not_run|disabled" `
            -SourceTableOrEndpoint "tools/workers/run_db_quality_gates.ps1" `
            -Data @{
                dashboard_panel = "Quality Gates"
                widget_key = "quality.gate.result"
                owner = "Content Ops"
                kill_switch_name = $KillSwitchName
            } `
            -LogRoot $LogRoot | Out-Null

        Write-Output "SKIPPED: $KillSwitchName is disabled. run_id=$script:RunId"
        exit 0
    }

    Write-JobLog `
        -RunId $script:RunId `
        -JobName "run_db_quality_gates" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -Status "job_started" `
        -EventType "job_started" `
        -SourceName "db_quality_gates" `
        -Data @{
            kill_switch_name = $KillSwitchName
            mode = $Mode
            database_key = $DatabaseKey
            max_duplicate_ratio = $MaxDuplicateRatio
            max_blank_key_ratio = $MaxBlankKeyRatio
            minimum_filter_diversity_score = $MinimumFilterDiversityScore
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Heartbeat `
        -RunId $script:RunId `
        -JobName "run_db_quality_gates" `
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
        -JobName "run_db_quality_gates" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "worker_heartbeat_status" `
        -P0Item "P0.2" `
        -SignalValue "ok" `
        -Status "ok" `
        -AllowedValues "ok|missed|failed|disabled" `
        -SourceTableOrEndpoint "tools/workers/run_db_quality_gates.ps1" `
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
        $snapshot = Read-QualitySnapshot -Path $resolvedInput
        $metricRow = Get-SnapshotMetricRow -Snapshot $snapshot
        $sourceName = "snapshot_input"
    }
    elseif ($Mode -eq "DbQuery") {
        $metricRow = Get-LiveQualityGateDbRow `
            -RepoRoot $repoRoot `
            -DatabaseKey $DatabaseKey `
            -Endpoint $DbQueryEndpoint `
            -Token $DbQueryToken `
            -TimeoutSec $QueryTimeoutSec

        $sourceName = "dog_open_proc:content.live_channels"
    }

    $metrics = Get-QualityGateMetrics `
        -MetricRow $metricRow `
        -Mode $Mode `
        -MaxDuplicateRatio $MaxDuplicateRatio `
        -MaxBlankKeyRatio $MaxBlankKeyRatio `
        -MinimumFilterDiversityScore $MinimumFilterDiversityScore `
        -SourceName $sourceName

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "run_db_quality_gates" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "quality_gate_result" `
        -P0Item "P0.5" `
        -SignalValue ([string]$metrics.quality_gate_result) `
        -Status ([string]$metrics.status) `
        -AllowedValues "pass|fail|warning|not_run|disabled" `
        -SourceTableOrEndpoint "tools/workers/run_db_quality_gates.ps1" `
        -ScreenType ([string]$metrics.screen_type) `
        -Data @{
            dashboard_panel = "Quality Gates"
            widget_key = "quality.gate.result"
            owner = "Content Ops"
            kill_switch_name = $KillSwitchName
            mode = $Mode
            source_name = $metrics.source_name
            screen_type = $metrics.screen_type
            total_rows = $metrics.total_rows
            excluded_rows = $metrics.excluded_rows
            duplicate_rows = $metrics.duplicate_rows
            blank_key_rows = $metrics.blank_key_rows
            duplicate_ratio = $metrics.duplicate_ratio
            blank_key_ratio = $metrics.blank_key_ratio
            filter_diversity_score = $metrics.filter_diversity_score
            validation_note = $metrics.validation_note
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "run_db_quality_gates" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "duplicate_ratio" `
        -P0Item "P0.5" `
        -SignalValue ([string]$metrics.duplicate_ratio) `
        -ValueNum ([decimal]$metrics.duplicate_ratio) `
        -Status ([string]$metrics.status) `
        -AllowedValues "0..1" `
        -SourceTableOrEndpoint "tools/workers/run_db_quality_gates.ps1" `
        -ScreenType ([string]$metrics.screen_type) `
        -Data @{
            dashboard_panel = "Quality Gates"
            widget_key = "quality.duplicate_ratio.by_screen"
            owner = "Content Ops"
            kill_switch_name = $KillSwitchName
            mode = $Mode
            source_name = $metrics.source_name
            screen_type = $metrics.screen_type
            duplicate_rows = $metrics.duplicate_rows
            total_rows = $metrics.total_rows
            max_duplicate_ratio = $metrics.max_duplicate_ratio
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "run_db_quality_gates" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "blank_key_ratio" `
        -P0Item "P0.5" `
        -SignalValue ([string]$metrics.blank_key_ratio) `
        -ValueNum ([decimal]$metrics.blank_key_ratio) `
        -Status ([string]$metrics.status) `
        -AllowedValues "0..1" `
        -SourceTableOrEndpoint "tools/workers/run_db_quality_gates.ps1" `
        -ScreenType ([string]$metrics.screen_type) `
        -Data @{
            dashboard_panel = "Quality Gates"
            widget_key = "quality.blank_key_ratio.by_screen"
            owner = "Content Ops"
            kill_switch_name = $KillSwitchName
            mode = $Mode
            source_name = $metrics.source_name
            screen_type = $metrics.screen_type
            blank_key_rows = $metrics.blank_key_rows
            total_rows = $metrics.total_rows
            max_blank_key_ratio = $metrics.max_blank_key_ratio
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "run_db_quality_gates" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "filter_diversity_score" `
        -P0Item "P0.5" `
        -SignalValue ([string]$metrics.filter_diversity_score) `
        -ValueNum ([decimal]$metrics.filter_diversity_score) `
        -Status ([string]$metrics.status) `
        -AllowedValues "0+" `
        -SourceTableOrEndpoint "tools/workers/run_db_quality_gates.ps1" `
        -ScreenType ([string]$metrics.screen_type) `
        -Data @{
            dashboard_panel = "Quality Gates"
            widget_key = "quality.filter_diversity_score.by_screen"
            owner = "Content Ops"
            kill_switch_name = $KillSwitchName
            mode = $Mode
            source_name = $metrics.source_name
            screen_type = $metrics.screen_type
            minimum_filter_diversity_score = $metrics.minimum_filter_diversity_score
        } `
        -LogRoot $LogRoot | Out-Null

    Write-JobLog `
        -RunId $script:RunId `
        -JobName "run_db_quality_gates" `
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
            quality_gate_result = $metrics.quality_gate_result
            screen_type = $metrics.screen_type
            total_rows = $metrics.total_rows
            excluded_rows = $metrics.excluded_rows
            duplicate_rows = $metrics.duplicate_rows
            blank_key_rows = $metrics.blank_key_rows
            duplicate_ratio = $metrics.duplicate_ratio
            blank_key_ratio = $metrics.blank_key_ratio
            filter_diversity_score = $metrics.filter_diversity_score
            max_duplicate_ratio = $metrics.max_duplicate_ratio
            max_blank_key_ratio = $metrics.max_blank_key_ratio
            minimum_filter_diversity_score = $metrics.minimum_filter_diversity_score
            source_name = $metrics.source_name
            mode = $Mode
            validation_note = $metrics.validation_note
            note = "read-only base live channel quality check; no DB writes performed"
        } `
        -LogRoot $LogRoot | Out-Null

    Write-Output "OK: DB quality gates completed. result=$($metrics.quality_gate_result) screen_type=$($metrics.screen_type) total_rows=$($metrics.total_rows) duplicate_ratio=$($metrics.duplicate_ratio) blank_key_ratio=$($metrics.blank_key_ratio) filter_diversity_score=$($metrics.filter_diversity_score) mode=$Mode run_id=$script:RunId"
    exit 0
}
catch {
    $message = $_.Exception.Message
    $duration = Get-DurationMs -Start $script:StartedAt

    if ([string]::IsNullOrWhiteSpace($script:RunId)) {
        $script:RunId = "db-quality-gates-failed-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
    }

    try {
        Write-JobLog `
            -RunId $script:RunId `
            -JobName "run_db_quality_gates" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -Status "job_failed" `
            -EventType "job_failed" `
            -SourceName "db_quality_gates" `
            -DurationMs $duration `
            -ErrorCode "DB_QUALITY_GATES_FAILED" `
            -ErrorMessage $message `
            -Data @{
                kill_switch_name = $KillSwitchName
                mode = $Mode
                database_key = $DatabaseKey
            } `
            -LogRoot $LogRoot | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName "run_db_quality_gates" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName "quality_gate_result" `
            -P0Item "P0.5" `
            -SignalValue "fail" `
            -Status "failed" `
            -AllowedValues "pass|fail|warning|not_run|disabled" `
            -SourceTableOrEndpoint "tools/workers/run_db_quality_gates.ps1" `
            -ErrorCode "DB_QUALITY_GATES_FAILED" `
            -ErrorMessage $message `
            -Data @{
                dashboard_panel = "Quality Gates"
                widget_key = "quality.gate.result"
                owner = "Content Ops"
                kill_switch_name = $KillSwitchName
                mode = $Mode
            } `
            -LogRoot $LogRoot | Out-Null
    }
    catch {
        Write-Error "DB quality gates worker failed and failed to log error: $($_.Exception.Message)"
    }

    Write-Error "FAILED: DB quality gates worker failed. run_id=$script:RunId error=$message"
    exit 1
}
