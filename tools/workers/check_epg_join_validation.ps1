# MiraTV EPG Join Validation Worker
# File: tools/workers/check_epg_join_validation.ps1
# Purpose:
#   P0.3 EPG join validation gate scaffold + read-only DB-backed mode.
#   Establishes observable validation for correct EPG-to-live-channel join behavior.
#
# Current implementation:
#   - Supports DryRun, SnapshotInput, and DbQuery modes.
#   - DbQuery mode uses tools/common/DbQuery.psm1, which calls dog_open_proc.php.
#   - Emits EPG join validation and worker heartbeat signals.
#   - Does not mutate EPG/live tables.
#
# Correct join rule:
#   Preferred:
#     epg_programs.epg_channel_id = live_channels.epg_channel_id
#
#   Acceptable fallback:
#     epg_programs.channel = live_channels.epg_channel_id
#
#   Bad legacy join to detect:
#     live_channels.id = epg_programs.channel
#
# Signals:
#   - epg_join_validation_status
#   - worker_heartbeat_status
#
# Kill switch:
#   - ENABLE_EPG_JOIN_GATE
#
# Required for DbQuery mode:
#   $env:DOG_OPEN_PROC_ENDPOINT = "https://miratv.club/_workers/api/series/dog_open_proc.php"
#   $env:DOG_OPEN_PROC_TOKEN = "<token>"
#
# Usage:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_epg_join_validation.ps1" -Environment "dev"
#
# DbQuery:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_epg_join_validation.ps1" -Environment "dev" -Mode "DbQuery"

[CmdletBinding()]
param(
    [string]$WorkerName = "epg_validation_gate",
    [string]$Component = "epg_validation_gate",
    [string]$Environment = "prod",
    [string]$KillSwitchName = "ENABLE_EPG_JOIN_GATE",

    [ValidateSet("DryRun", "SnapshotInput", "DbQuery")]
    [string]$Mode = "DryRun",

    [string]$InputJsonPath = "",
    [string]$DatabaseKey = "content",
    [string]$DbQueryEndpoint = "",
    [string]$DbQueryToken = "",
    [int]$QueryTimeoutSec = 30,

    [int]$MinimumPreferredJoinRows = 1,
    [int]$MaximumBadLegacyJoinRows = 0,
    [int]$HeartbeatIntervalSeconds = 1800,
    [int]$StaleAfterSeconds = 21600,
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

function Read-EpgJoinSnapshot {
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

    return $Snapshot
}

function Get-EpgJoinValidationSql {
    [CmdletBinding()]
    param()

    return @"
SELECT
    preferred.preferred_join_rows,
    fallback.acceptable_fallback_join_rows,
    bad.bad_legacy_join_rows,
    epg.epg_program_count,
    epg.epg_channel_count,
    live.live_channel_count,
    live.live_epg_channel_count
FROM
    (
        SELECT
            COUNT(*) AS preferred_join_rows
        FROM epg_programs epg
        INNER JOIN live_channels live
            ON epg.epg_channel_id = live.epg_channel_id
        WHERE epg.epg_channel_id IS NOT NULL
          AND epg.epg_channel_id <> ''
          AND live.epg_channel_id IS NOT NULL
          AND live.epg_channel_id <> ''
    ) preferred
CROSS JOIN
    (
        SELECT
            COUNT(*) AS acceptable_fallback_join_rows
        FROM epg_programs epg
        INNER JOIN live_channels live
            ON epg.channel = live.epg_channel_id
        WHERE epg.channel IS NOT NULL
          AND epg.channel <> ''
          AND live.epg_channel_id IS NOT NULL
          AND live.epg_channel_id <> ''
    ) fallback
CROSS JOIN
    (
        SELECT
            COUNT(*) AS bad_legacy_join_rows
        FROM epg_programs epg
        INNER JOIN live_channels live
            ON live.id = epg.channel
        WHERE epg.channel IS NOT NULL
          AND epg.channel <> ''
    ) bad
CROSS JOIN
    (
        SELECT
            COUNT(*) AS epg_program_count,
            COUNT(DISTINCT epg_channel_id) AS epg_channel_count
        FROM epg_programs
    ) epg
CROSS JOIN
    (
        SELECT
            COUNT(*) AS live_channel_count,
            COUNT(DISTINCT epg_channel_id) AS live_epg_channel_count
        FROM live_channels
        WHERE epg_channel_id IS NOT NULL
          AND epg_channel_id <> ''
    ) live
"@
}

function Get-EpgJoinValidationDbRow {
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

    $sql = Get-EpgJoinValidationSql

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
        throw "DbQuery returned zero rows for EPG join validation query."
    }

    return $rows[0]
}

function Get-EpgJoinMetrics {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$MetricRow,

        [string]$Mode,

        [int]$MinimumPreferredJoinRows,

        [int]$MaximumBadLegacyJoinRows,

        [string]$SourceName
    )

    $status = "dry_run"
    $joinStatus = "not_run"
    $preferredJoinRows = 0
    $acceptableFallbackJoinRows = 0
    $badLegacyJoinRows = 0
    $epgProgramCount = 0
    $epgChannelCount = 0
    $liveChannelCount = 0
    $liveEpgChannelCount = 0
    $validationNote = "local-first scaffold; no DB query performed"

    if ($null -ne $MetricRow) {
        $preferredJoinRows = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @(
            "preferred_join_rows",
            "preferred_rows",
            "correct_join_rows"
        ))

        $acceptableFallbackJoinRows = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @(
            "acceptable_fallback_join_rows",
            "fallback_join_rows"
        ))

        $badLegacyJoinRows = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @(
            "bad_legacy_join_rows",
            "legacy_join_rows",
            "bad_join_rows"
        ))

        $epgProgramCount = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @(
            "epg_program_count",
            "program_count"
        ))

        $epgChannelCount = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @(
            "epg_channel_count",
            "distinct_epg_channel_count"
        ))

        $liveChannelCount = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @(
            "live_channel_count",
            "channel_count"
        ))

        $liveEpgChannelCount = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @(
            "live_epg_channel_count",
            "live_distinct_epg_channel_count"
        ))

        $status = "ok"
        $joinStatus = "pass"
        $validationNote = "preferred EPG join is available and bad legacy join is within threshold"

        if ($epgProgramCount -le 0) {
            $status = "warning"
            $joinStatus = "warning"
            $validationNote = "no EPG program rows found"
        }
        elseif ($preferredJoinRows -lt $MinimumPreferredJoinRows) {
            $status = "fail"
            $joinStatus = "fail"
            $validationNote = "preferred EPG join produced fewer rows than required"
        }
        elseif ($badLegacyJoinRows -gt $MaximumBadLegacyJoinRows) {
            $status = "warning"
            $joinStatus = "warning"
            $validationNote = "bad legacy join produced rows above configured threshold"
        }
    }

    return [ordered]@{
        status = $status
        epg_join_validation_status = $joinStatus
        preferred_join_rows = $preferredJoinRows
        acceptable_fallback_join_rows = $acceptableFallbackJoinRows
        bad_legacy_join_rows = $badLegacyJoinRows
        minimum_preferred_join_rows = $MinimumPreferredJoinRows
        maximum_bad_legacy_join_rows = $MaximumBadLegacyJoinRows
        epg_program_count = $epgProgramCount
        epg_channel_count = $epgChannelCount
        live_channel_count = $liveChannelCount
        live_epg_channel_count = $liveEpgChannelCount
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

$script:RunId = New-RunId -Prefix "epg-join-validation"

try {
    $enabled = Test-KillSwitch -Name $KillSwitchName -DefaultEnabled $true

    if (-not $enabled) {
        Write-JobLog `
            -RunId $script:RunId `
            -JobName "check_epg_join_validation" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -Status "job_skipped" `
            -EventType "job_skipped" `
            -SourceName "epg_join_validation" `
            -DurationMs (Get-DurationMs -Start $script:StartedAt) `
            -Data @{
                kill_switch_name = $KillSwitchName
                kill_switch_enabled = $false
                reason = "EPG join validation disabled by kill switch"
                mode = $Mode
            } `
            -LogRoot $LogRoot | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName "check_epg_join_validation" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName "epg_join_validation_status" `
            -P0Item "P0.3" `
            -SignalValue "disabled" `
            -Status "disabled" `
            -AllowedValues "pass|fail|warning|not_run|disabled" `
            -SourceTableOrEndpoint "tools/workers/check_epg_join_validation.ps1" `
            -Data @{
                dashboard_panel = "EPG Health"
                widget_key = "epg.join.validation.status"
                owner = "Content Ops"
                kill_switch_name = $KillSwitchName
            } `
            -LogRoot $LogRoot | Out-Null

        Write-Output "SKIPPED: $KillSwitchName is disabled. run_id=$script:RunId"
        exit 0
    }

    Write-JobLog `
        -RunId $script:RunId `
        -JobName "check_epg_join_validation" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -Status "job_started" `
        -EventType "job_started" `
        -SourceName "epg_join_validation" `
        -Data @{
            kill_switch_name = $KillSwitchName
            mode = $Mode
            minimum_preferred_join_rows = $MinimumPreferredJoinRows
            maximum_bad_legacy_join_rows = $MaximumBadLegacyJoinRows
            database_key = $DatabaseKey
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Heartbeat `
        -RunId $script:RunId `
        -JobName "check_epg_join_validation" `
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
        -JobName "check_epg_join_validation" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "worker_heartbeat_status" `
        -P0Item "P0.2" `
        -SignalValue "ok" `
        -Status "ok" `
        -AllowedValues "ok|missed|failed|disabled" `
        -SourceTableOrEndpoint "tools/workers/check_epg_join_validation.ps1" `
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
        $snapshot = Read-EpgJoinSnapshot -Path $resolvedInput
        $metricRow = Get-SnapshotMetricRow -Snapshot $snapshot
        $sourceName = "snapshot_input"
    }
    elseif ($Mode -eq "DbQuery") {
        $metricRow = Get-EpgJoinValidationDbRow `
            -RepoRoot $repoRoot `
            -DatabaseKey $DatabaseKey `
            -Endpoint $DbQueryEndpoint `
            -Token $DbQueryToken `
            -TimeoutSec $QueryTimeoutSec

        $sourceName = "dog_open_proc:content.epg_programs/live_channels"
    }

    $metrics = Get-EpgJoinMetrics `
        -MetricRow $metricRow `
        -Mode $Mode `
        -MinimumPreferredJoinRows $MinimumPreferredJoinRows `
        -MaximumBadLegacyJoinRows $MaximumBadLegacyJoinRows `
        -SourceName $sourceName

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "check_epg_join_validation" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "epg_join_validation_status" `
        -P0Item "P0.3" `
        -SignalValue ([string]$metrics.epg_join_validation_status) `
        -Status ([string]$metrics.status) `
        -AllowedValues "pass|fail|warning|not_run|disabled" `
        -SourceTableOrEndpoint "tools/workers/check_epg_join_validation.ps1" `
        -Data @{
            dashboard_panel = "EPG Health"
            widget_key = "epg.join.validation.status"
            owner = "Content Ops"
            kill_switch_name = $KillSwitchName
            mode = $Mode
            source_name = $metrics.source_name
            preferred_join_rows = $metrics.preferred_join_rows
            acceptable_fallback_join_rows = $metrics.acceptable_fallback_join_rows
            bad_legacy_join_rows = $metrics.bad_legacy_join_rows
            minimum_preferred_join_rows = $metrics.minimum_preferred_join_rows
            maximum_bad_legacy_join_rows = $metrics.maximum_bad_legacy_join_rows
            epg_program_count = $metrics.epg_program_count
            epg_channel_count = $metrics.epg_channel_count
            live_channel_count = $metrics.live_channel_count
            live_epg_channel_count = $metrics.live_epg_channel_count
            validation_note = $metrics.validation_note
        } `
        -LogRoot $LogRoot | Out-Null

    Write-JobLog `
        -RunId $script:RunId `
        -JobName "check_epg_join_validation" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -Status "job_completed" `
        -EventType "job_completed" `
        -SourceName ([string]$metrics.source_name) `
        -SourceRowCount ([int]$metrics.epg_program_count) `
        -RowsInserted 0 `
        -RowsUpdated 0 `
        -RowsSkipped ([int]$metrics.epg_program_count) `
        -RowsFailed 0 `
        -DurationMs (Get-DurationMs -Start $script:StartedAt) `
        -Data @{
            epg_join_validation_status = $metrics.epg_join_validation_status
            preferred_join_rows = $metrics.preferred_join_rows
            acceptable_fallback_join_rows = $metrics.acceptable_fallback_join_rows
            bad_legacy_join_rows = $metrics.bad_legacy_join_rows
            minimum_preferred_join_rows = $metrics.minimum_preferred_join_rows
            maximum_bad_legacy_join_rows = $metrics.maximum_bad_legacy_join_rows
            epg_program_count = $metrics.epg_program_count
            epg_channel_count = $metrics.epg_channel_count
            live_channel_count = $metrics.live_channel_count
            live_epg_channel_count = $metrics.live_epg_channel_count
            source_name = $metrics.source_name
            mode = $Mode
            validation_note = $metrics.validation_note
            note = "read-only check; no DB writes performed"
        } `
        -LogRoot $LogRoot | Out-Null

    Write-Output "OK: EPG join validation completed. status=$($metrics.status) result=$($metrics.epg_join_validation_status) preferred_join_rows=$($metrics.preferred_join_rows) bad_legacy_join_rows=$($metrics.bad_legacy_join_rows) mode=$Mode run_id=$script:RunId"
    exit 0
}
catch {
    $message = $_.Exception.Message
    $duration = Get-DurationMs -Start $script:StartedAt

    if ([string]::IsNullOrWhiteSpace($script:RunId)) {
        $script:RunId = "epg-join-validation-failed-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
    }

    try {
        Write-JobLog `
            -RunId $script:RunId `
            -JobName "check_epg_join_validation" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -Status "job_failed" `
            -EventType "job_failed" `
            -SourceName "epg_join_validation" `
            -DurationMs $duration `
            -ErrorCode "EPG_JOIN_VALIDATION_FAILED" `
            -ErrorMessage $message `
            -Data @{
                kill_switch_name = $KillSwitchName
                mode = $Mode
                database_key = $DatabaseKey
            } `
            -LogRoot $LogRoot | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName "check_epg_join_validation" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName "epg_join_validation_status" `
            -P0Item "P0.3" `
            -SignalValue "fail" `
            -Status "failed" `
            -AllowedValues "pass|fail|warning|not_run|disabled" `
            -SourceTableOrEndpoint "tools/workers/check_epg_join_validation.ps1" `
            -ErrorCode "EPG_JOIN_VALIDATION_FAILED" `
            -ErrorMessage $message `
            -Data @{
                dashboard_panel = "EPG Health"
                widget_key = "epg.join.validation.status"
                owner = "Content Ops"
                kill_switch_name = $KillSwitchName
                mode = $Mode
            } `
            -LogRoot $LogRoot | Out-Null
    }
    catch {
        Write-Error "EPG join validation worker failed and failed to log error: $($_.Exception.Message)"
    }

    Write-Error "FAILED: EPG join validation worker failed. run_id=$script:RunId error=$message"
    exit 1
}