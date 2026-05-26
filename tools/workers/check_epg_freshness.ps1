# MiraTV EPG Freshness Check Worker
# File: tools/workers/check_epg_freshness.ps1
# Purpose:
#   P0.3 EPG freshness/import signal worker scaffold.
#   Establishes observable freshness checks for EPG import health before wiring DB-backed validation.
#
# Current implementation:
#   - Local-first, no DB writes yet.
#   - Supports DryRun and SnapshotInput modes.
#   - Emits EPG freshness and worker heartbeat signals.
#   - Does not mutate EPG tables.
#   - Designed to be extended with DB/query bridge checks later.
#
# Signals:
#   - epg_freshness_age_hours
#   - worker_heartbeat_status
#
# Kill switch:
#   - ENABLE_EPG_IMPORT
#
# Usage:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_epg_freshness.ps1" -Environment "dev"
#
# Optional snapshot input:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_epg_freshness.ps1" `
#     -Environment "dev" `
#     -Mode "SnapshotInput" `
#     -InputJsonPath "runtime/samples/epg_freshness_snapshot.json"

[CmdletBinding()]
param(
    [string]$WorkerName = "epg_import_worker",
    [string]$Component = "epg_import_worker",
    [string]$Environment = "prod",
    [string]$KillSwitchName = "ENABLE_EPG_IMPORT",

    [ValidateSet("DryRun", "SnapshotInput")]
    [string]$Mode = "DryRun",

    [string]$InputJsonPath = "",
    [int]$MaxFreshnessAgeHours = 6,
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

function Read-EpgSnapshot {
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

function Convert-ToDateTimeOrNull {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    $parsed = [datetime]::MinValue

    if ([datetime]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed.ToUniversalTime()
    }

    return $null
}

function Get-EpgFreshnessMetrics {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Snapshot,

        [int]$MaxFreshnessAgeHours
    )

    $nowUtc = (Get-Date).ToUniversalTime()
    $lastImportAt = $null
    $lastProgramEndAt = $null
    $programCount = 0
    $channelCount = 0
    $sourceName = "dry_run_no_db_query"

    if ($null -ne $Snapshot) {
        $lastImportRaw = Get-PropertyValue -Object $Snapshot -Names @(
            "last_import_at",
            "last_success_at",
            "imported_at",
            "refreshed_at",
            "created_at",
            "snapshot_at"
        )

        $lastProgramEndRaw = Get-PropertyValue -Object $Snapshot -Names @(
            "latest_program_end_time",
            "max_end_time",
            "last_program_end_at",
            "program_end_at"
        )

        $programCountRaw = Get-PropertyValue -Object $Snapshot -Names @(
            "program_count",
            "epg_program_count",
            "rows",
            "row_count"
        )

        $channelCountRaw = Get-PropertyValue -Object $Snapshot -Names @(
            "channel_count",
            "epg_channel_count",
            "mapped_channel_count"
        )

        $sourceRaw = Get-PropertyValue -Object $Snapshot -Names @(
            "source_name",
            "source",
            "endpoint",
            "table"
        )

        $lastImportAt = Convert-ToDateTimeOrNull -Value $lastImportRaw
        $lastProgramEndAt = Convert-ToDateTimeOrNull -Value $lastProgramEndRaw

        $parsedProgramCount = 0
        if ($null -ne $programCountRaw -and [int]::TryParse([string]$programCountRaw, [ref]$parsedProgramCount)) {
            $programCount = $parsedProgramCount
        }

        $parsedChannelCount = 0
        if ($null -ne $channelCountRaw -and [int]::TryParse([string]$channelCountRaw, [ref]$parsedChannelCount)) {
            $channelCount = $parsedChannelCount
        }

        if ($null -ne $sourceRaw -and -not [string]::IsNullOrWhiteSpace([string]$sourceRaw)) {
            $sourceName = [string]$sourceRaw
        }
    }

    $freshnessAgeHours = 0
    $freshnessBasis = "none"

    if ($null -ne $lastImportAt) {
        $freshnessAgeHours = [decimal][math]::Round(($nowUtc - $lastImportAt).TotalHours, 2)
        $freshnessBasis = "last_import_at"
    }
    elseif ($null -ne $lastProgramEndAt) {
        $freshnessAgeHours = [decimal][math]::Round(($nowUtc - $lastProgramEndAt).TotalHours, 2)
        $freshnessBasis = "latest_program_end_time"
    }

    if ($freshnessAgeHours -lt 0) {
        $freshnessAgeHours = 0
    }

    $status = "dry_run"

    if ($null -ne $Snapshot) {
        $status = "ok"

        if ($freshnessAgeHours -gt $MaxFreshnessAgeHours) {
            $status = "stale"
        }

        if ($programCount -eq 0) {
            $status = "warning"
        }
    }

    return [ordered]@{
        status = $status
        freshness_age_hours = $freshnessAgeHours
        max_freshness_age_hours = $MaxFreshnessAgeHours
        freshness_basis = $freshnessBasis
        last_import_at = if ($null -ne $lastImportAt) { $lastImportAt.ToString("o") } else { "" }
        latest_program_end_time = if ($null -ne $lastProgramEndAt) { $lastProgramEndAt.ToString("o") } else { "" }
        program_count = $programCount
        channel_count = $channelCount
        source_name = $sourceName
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

    $snapshot = $null
    $sourceName = "dry_run_no_db_query"

    if ($Mode -eq "SnapshotInput") {
        if ([string]::IsNullOrWhiteSpace($InputJsonPath)) {
            throw "InputJsonPath is required when Mode=SnapshotInput."
        }

        $resolvedInput = Resolve-RepoRelativePath -RepoRoot $repoRoot -Path $InputJsonPath
        $snapshot = Read-EpgSnapshot -Path $resolvedInput
        $sourceName = $resolvedInput
    }

    $metrics = Get-EpgFreshnessMetrics -Snapshot $snapshot -MaxFreshnessAgeHours $MaxFreshnessAgeHours

    if ($Mode -eq "SnapshotInput") {
        $sourceName = $metrics.source_name
    }

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "check_epg_freshness" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "epg_freshness_age_hours" `
        -P0Item "P0.3" `
        -SignalValue ([string]$metrics.freshness_age_hours) `
        -ValueNum ([decimal]$metrics.freshness_age_hours) `
        -Status ([string]$metrics.status) `
        -AllowedValues "0+" `
        -SourceTableOrEndpoint "tools/workers/check_epg_freshness.ps1" `
        -Data @{
            dashboard_panel = "EPG Health"
            widget_key = "epg.freshness.age_hours"
            owner = "Content Ops"
            kill_switch_name = $KillSwitchName
            mode = $Mode
            source_name = $sourceName
            max_freshness_age_hours = $metrics.max_freshness_age_hours
            freshness_basis = $metrics.freshness_basis
            last_import_at = $metrics.last_import_at
            latest_program_end_time = $metrics.latest_program_end_time
            program_count = $metrics.program_count
            channel_count = $metrics.channel_count
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
        -SourceName $sourceName `
        -SourceRowCount ([int]$metrics.program_count) `
        -RowsInserted 0 `
        -RowsUpdated 0 `
        -RowsSkipped ([int]$metrics.program_count) `
        -RowsFailed 0 `
        -DurationMs (Get-DurationMs -Start $script:StartedAt) `
        -Data @{
            epg_freshness_status = $metrics.status
            epg_freshness_age_hours = $metrics.freshness_age_hours
            max_freshness_age_hours = $metrics.max_freshness_age_hours
            freshness_basis = $metrics.freshness_basis
            last_import_at = $metrics.last_import_at
            latest_program_end_time = $metrics.latest_program_end_time
            program_count = $metrics.program_count
            channel_count = $metrics.channel_count
            mode = $Mode
            note = "local-first scaffold; no DB query performed"
        } `
        -LogRoot $LogRoot | Out-Null

    Write-Output "OK: EPG freshness check completed. status=$($metrics.status) age_hours=$($metrics.freshness_age_hours) mode=$Mode run_id=$script:RunId"
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