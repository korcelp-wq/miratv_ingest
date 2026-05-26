# MiraTV EPG Freshness Check Worker
# File: tools/workers/check_epg_freshness.ps1
# Purpose:
#   P0.3 EPG freshness gate scaffold + read-only DB-backed mode.
#   Establishes observable EPG freshness checks without mutating EPG tables.
#
# Current implementation:
#   - Supports DryRun, SnapshotInput, and DbQuery modes.
#   - DbQuery mode uses tools/common/DbQuery.psm1, which calls dog_open_proc.php.
#   - Emits EPG freshness and worker heartbeat signals.
#   - Does not mutate EPG/live tables.
#
# Signals:
#   - epg_freshness_age_hours
#   - worker_heartbeat_status
#
# Kill switch:
#   - ENABLE_EPG_IMPORT
#
# Required for DbQuery mode:
#   $env:DOG_OPEN_PROC_ENDPOINT = "https://miratv.club/_workers/api/series/dog_open_proc.php"
#   $env:DOG_OPEN_PROC_TOKEN = "<token>"
#
# Usage:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_epg_freshness.ps1" -Environment "dev"
#
# DbQuery:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_epg_freshness.ps1" -Environment "dev" -Mode "DbQuery"

[CmdletBinding()]
param(
    [string]$WorkerName = "epg_import_worker",
    [string]$Component = "epg_import_worker",
    [string]$Environment = "prod",
    [string]$KillSwitchName = "ENABLE_EPG_IMPORT",

    [ValidateSet("DryRun", "SnapshotInput", "DbQuery")]
    [string]$Mode = "DryRun",

    [string]$InputJsonPath = "",
    [string]$DatabaseKey = "content",
    [string]$DbQueryEndpoint = "",
    [string]$DbQueryToken = "",
    [int]$QueryTimeoutSec = 30,

    [int]$MaxFreshnessAgeHours = 24,
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

function Read-EpgFreshnessSnapshot {
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

    return $Snapshot
}

function Get-EpgFreshnessSql {
    [CmdletBinding()]
    param()

    return @"
SELECT
    COUNT(*) AS program_count,
    COUNT(DISTINCT epg_channel_id) AS channel_count,
    MAX(end_time) AS latest_program_end_time,
    TIMESTAMPDIFF(HOUR, MAX(end_time), NOW()) AS epg_freshness_age_hours
FROM epg_programs
"@
}

function Get-EpgFreshnessDbRow {
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

    $sql = Get-EpgFreshnessSql

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
        throw "DbQuery returned zero rows for EPG freshness query."
    }

    return $rows[0]
}

function Get-EpgFreshnessMetrics {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$MetricRow,

        [string]$Mode,

        [int]$MaxFreshnessAgeHours,

        [string]$SourceName
    )

    $status = "dry_run"
    $programCount = 0
    $channelCount = 0
    $ageHours = 0
    $latestProgramEndTime = $null
    $validationNote = "local-first scaffold; no DB query performed"

    if ($null -ne $MetricRow) {
        $programCount = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @(
            "program_count",
            "epg_program_count",
            "row_count",
            "rows"
        ))

        $channelCount = Convert-ToIntSafe -Value (Get-PropertyValue -Object $MetricRow -Names @(
            "channel_count",
            "epg_channel_count",
            "distinct_channel_count"
        ))

        $ageRaw = Get-PropertyValue -Object $MetricRow -Names @(
            "epg_freshness_age_hours",
            "freshness_age_hours",
            "age_hours"
        )

        $latestRaw = Get-PropertyValue -Object $MetricRow -Names @(
            "latest_program_end_time",
            "max_end_time",
            "last_epg_end_time",
            "last_import_at"
        )

        $latestProgramEndTime = Convert-ToDateTimeSafe -Value $latestRaw

        if ($null -ne $ageRaw) {
            $ageHours = Convert-ToDecimalSafe -Value $ageRaw -DefaultValue 0
        }
        elseif ($null -ne $latestProgramEndTime) {
            $now = Get-Date
            $ageHours = [decimal]::Round(($now - $latestProgramEndTime).TotalHours, 2)

            if ($ageHours -lt 0) {
                $ageHours = 0
            }
        }

        $status = "ok"
        $validationNote = "EPG freshness is within configured threshold"

        if ($programCount -le 0) {
            $status = "warning"
            $validationNote = "no EPG program rows found"
        }
        elseif ($ageHours -gt $MaxFreshnessAgeHours) {
            $status = "warning"
            $validationNote = "EPG freshness age exceeds configured threshold"
        }
    }

    return [ordered]@{
        status = $status
        epg_freshness_age_hours = $ageHours
        max_freshness_age_hours = $MaxFreshnessAgeHours
        program_count = $programCount
        channel_count = $channelCount
        latest_program_end_time = $latestProgramEndTime
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

$script:RunId = New-RunId -Prefix "epg-freshness"

try {
    $enabled = Test-KillSwitch -Name $KillSwitchName -DefaultEnabled $true

    if (-not $enabled) {
        Write-JobLog `
            -RunId $script:RunId `
            -JobName "check_epg_freshness" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -Status "job_skipped" `
            -EventType "job_skipped" `
            -SourceName "epg_freshness" `
            -DurationMs (Get-DurationMs -Start $script:StartedAt) `
            -Data @{
                kill_switch_name = $KillSwitchName
                kill_switch_enabled = $false
                reason = "EPG import/freshness checks disabled by kill switch"
                mode = $Mode
            } `
            -LogRoot $LogRoot | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName "check_epg_freshness" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName "epg_freshness_age_hours" `
            -P0Item "P0.3" `
            -SignalValue "disabled" `
            -Status "disabled" `
            -AllowedValues "0+|disabled|failed" `
            -SourceTableOrEndpoint "tools/workers/check_epg_freshness.ps1" `
            -Data @{
                dashboard_panel = "EPG Health"
                widget_key = "epg.freshness.age_hours"
                owner = "Content Ops"
                kill_switch_name = $KillSwitchName
            } `
            -LogRoot $LogRoot | Out-Null

        Write-Output "SKIPPED: $KillSwitchName is disabled. run_id=$script:RunId"
        exit 0
    }

    Write-JobLog `
        -RunId $script:RunId `
        -JobName "check_epg_freshness" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -Status "job_started" `
        -EventType "job_started" `
        -SourceName "epg_freshness" `
        -Data @{
            kill_switch_name = $KillSwitchName
            mode = $Mode
            max_freshness_age_hours = $MaxFreshnessAgeHours
            database_key = $DatabaseKey
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Heartbeat `
        -RunId $script:RunId `
        -JobName "check_epg_freshness" `
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
        -JobName "check_epg_freshness" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "worker_heartbeat_status" `
        -P0Item "P0.2" `
        -SignalValue "ok" `
        -Status "ok" `
        -AllowedValues "ok|missed|failed|disabled" `
        -SourceTableOrEndpoint "tools/workers/check_epg_freshness.ps1" `
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
        $snapshot = Read-EpgFreshnessSnapshot -Path $resolvedInput
        $metricRow = Get-SnapshotMetricRow -Snapshot $snapshot
        $sourceName = "snapshot_input"
    }
    elseif ($Mode -eq "DbQuery") {
        $metricRow = Get-EpgFreshnessDbRow `
            -RepoRoot $repoRoot `
            -DatabaseKey $DatabaseKey `
            -Endpoint $DbQueryEndpoint `
            -Token $DbQueryToken `
            -TimeoutSec $QueryTimeoutSec

        $sourceName = "dog_open_proc:content.epg_programs"
    }

    $metrics = Get-EpgFreshnessMetrics `
        -MetricRow $metricRow `
        -Mode $Mode `
        -MaxFreshnessAgeHours $MaxFreshnessAgeHours `
        -SourceName $sourceName

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "check_epg_freshness" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "epg_freshness_age_hours" `
        -P0Item "P0.3" `
        -SignalValue ([string]$metrics.epg_freshness_age_hours) `
        -ValueNum ([decimal]$metrics.epg_freshness_age_hours) `
        -Status ([string]$metrics.status) `
        -AllowedValues "0+" `
        -SourceTableOrEndpoint "tools/workers/check_epg_freshness.ps1" `
        -Data @{
            dashboard_panel = "EPG Health"
            widget_key = "epg.freshness.age_hours"
            owner = "Content Ops"
            kill_switch_name = $KillSwitchName
            mode = $Mode
            source_name = $metrics.source_name
            max_freshness_age_hours = $metrics.max_freshness_age_hours
            program_count = $metrics.program_count
            channel_count = $metrics.channel_count
            latest_program_end_time = $metrics.latest_program_end_time
            validation_note = $metrics.validation_note
        } `
        -LogRoot $LogRoot | Out-Null

    Write-JobLog `
        -RunId $script:RunId `
        -JobName "check_epg_freshness" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -Status "job_completed" `
        -EventType "job_completed" `
        -SourceName ([string]$metrics.source_name) `
        -SourceRowCount ([int]$metrics.program_count) `
        -RowsInserted 0 `
        -RowsUpdated 0 `
        -RowsSkipped ([int]$metrics.program_count) `
        -RowsFailed 0 `
        -DurationMs (Get-DurationMs -Start $script:StartedAt) `
        -Data @{
            epg_freshness_age_hours = $metrics.epg_freshness_age_hours
            max_freshness_age_hours = $metrics.max_freshness_age_hours
            program_count = $metrics.program_count
            channel_count = $metrics.channel_count
            latest_program_end_time = $metrics.latest_program_end_time
            source_name = $metrics.source_name
            mode = $Mode
            validation_note = $metrics.validation_note
            note = "read-only check; no DB writes performed"
        } `
        -LogRoot $LogRoot | Out-Null

    Write-Output "OK: EPG freshness check completed. status=$($metrics.status) age_hours=$($metrics.epg_freshness_age_hours) mode=$Mode program_count=$($metrics.program_count) run_id=$script:RunId"
    exit 0
}
catch {
    $message = $_.Exception.Message
    $duration = Get-DurationMs -Start $script:StartedAt

    if ([string]::IsNullOrWhiteSpace($script:RunId)) {
        $script:RunId = "epg-freshness-failed-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
    }

    try {
        Write-JobLog `
            -RunId $script:RunId `
            -JobName "check_epg_freshness" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -Status "job_failed" `
            -EventType "job_failed" `
            -SourceName "epg_freshness" `
            -DurationMs $duration `
            -ErrorCode "EPG_FRESHNESS_CHECK_FAILED" `
            -ErrorMessage $message `
            -Data @{
                kill_switch_name = $KillSwitchName
                mode = $Mode
                database_key = $DatabaseKey
            } `
            -LogRoot $LogRoot | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName "check_epg_freshness" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName "epg_freshness_age_hours" `
            -P0Item "P0.3" `
            -SignalValue "failed" `
            -Status "failed" `
            -AllowedValues "0+|disabled|failed" `
            -SourceTableOrEndpoint "tools/workers/check_epg_freshness.ps1" `
            -ErrorCode "EPG_FRESHNESS_CHECK_FAILED" `
            -ErrorMessage $message `
            -Data @{
                dashboard_panel = "EPG Health"
                widget_key = "epg.freshness.age_hours"
                owner = "Content Ops"
                kill_switch_name = $KillSwitchName
                mode = $Mode
            } `
            -LogRoot $LogRoot | Out-Null
    }
    catch {
        Write-Error "EPG freshness worker failed and failed to log error: $($_.Exception.Message)"
    }

    Write-Error "FAILED: EPG freshness worker failed. run_id=$script:RunId error=$message"
    exit 1
}