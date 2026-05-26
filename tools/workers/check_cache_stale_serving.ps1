# MiraTV Cache Stale-Serving Check Worker
# File: tools/workers/check_cache_stale_serving.ps1
# Purpose:
#   P0.4 stale-serving contract / cache health scaffold.
#   Establishes observable checks for cache serving source, stale ratio, and screen-level cache safety.
#
# Current implementation:
#   - Local-first, no DB writes yet.
#   - Supports DryRun and SnapshotInput modes.
#   - Emits cache health and worker heartbeat signals.
#   - Does not mutate cache tables or endpoints.
#   - Designed to be extended with DB/query bridge and endpoint aggregation later.
#
# Signals:
#   - cache_served_from
#   - stale_ratio_by_screen
#   - worker_heartbeat_status
#
# Kill switch:
#   - ENABLE_ASYNC_CACHE_REFRESH
#
# Usage:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_cache_stale_serving.ps1" -Environment "dev"
#
# Optional snapshot input:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_cache_stale_serving.ps1" `
#     -Environment "dev" `
#     -Mode "SnapshotInput" `
#     -InputJsonPath "runtime/samples/cache_stale_serving_snapshot.json"

[CmdletBinding()]
param(
    [string]$WorkerName = "cache_reader",
    [string]$Component = "cache_reader",
    [string]$Environment = "prod",
    [string]$KillSwitchName = "ENABLE_ASYNC_CACHE_REFRESH",

    [ValidateSet("DryRun", "SnapshotInput")]
    [string]$Mode = "DryRun",

    [string]$InputJsonPath = "",
    [string]$ScreenType = "",
    [decimal]$MaxStaleRatio = 0.25,
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

function Get-CacheRows {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Snapshot
    )

    if ($null -eq $Snapshot) {
        return @()
    }

    if ($Snapshot.PSObject.Properties.Name -contains "screens") {
        return Convert-ToArray -Value $Snapshot.screens
    }

    if ($Snapshot.PSObject.Properties.Name -contains "items") {
        return Convert-ToArray -Value $Snapshot.items
    }

    if ($Snapshot.PSObject.Properties.Name -contains "cache_rows") {
        return Convert-ToArray -Value $Snapshot.cache_rows
    }

    if ($Snapshot.PSObject.Properties.Name -contains "results") {
        return Convert-ToArray -Value $Snapshot.results
    }

    return Convert-ToArray -Value $Snapshot
}

function Get-CacheMetrics {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Snapshot,

        [string]$ScreenType,

        [decimal]$MaxStaleRatio
    )

    $rows = Get-CacheRows -Snapshot $Snapshot

    if (-not [string]::IsNullOrWhiteSpace($ScreenType)) {
        $rows = @(
            $rows | Where-Object {
                $screenRaw = Get-PropertyValue -Object $_ -Names @("screen_type", "screen", "page")
                ([string]$screenRaw).Trim().ToLowerInvariant() -eq $ScreenType.Trim().ToLowerInvariant()
            }
        )
    }

    $totalRows = @($rows).Count
    $freshRows = 0
    $staleRows = 0
    $emptyRows = 0
    $errorRows = 0
    $unknownRows = 0

    $servedFromCounts = @{}
    $screenCounts = @{}
    $screenStaleCounts = @{}

    foreach ($row in $rows) {
        $screenRaw = Get-PropertyValue -Object $row -Names @("screen_type", "screen", "page")
        $screen = "unknown"

        if ($null -ne $screenRaw -and -not [string]::IsNullOrWhiteSpace([string]$screenRaw)) {
            $screen = ([string]$screenRaw).Trim().ToLowerInvariant()
        }

        if (-not $screenCounts.ContainsKey($screen)) {
            $screenCounts[$screen] = 0
            $screenStaleCounts[$screen] = 0
        }

        $screenCounts[$screen] = [int]$screenCounts[$screen] + 1

        $servedFromRaw = Get-PropertyValue -Object $row -Names @("cache_served_from", "served_from", "source", "cache_status")
        $servedFrom = "unknown"

        if ($null -ne $servedFromRaw -and -not [string]::IsNullOrWhiteSpace([string]$servedFromRaw)) {
            $servedFrom = ([string]$servedFromRaw).Trim().ToLowerInvariant()
        }

        if (-not $servedFromCounts.ContainsKey($servedFrom)) {
            $servedFromCounts[$servedFrom] = 0
        }

        $servedFromCounts[$servedFrom] = [int]$servedFromCounts[$servedFrom] + 1

        $statusRaw = Get-PropertyValue -Object $row -Names @("cache_status", "status", "state", "cache_state")
        $status = ""

        if ($null -ne $statusRaw) {
            $status = ([string]$statusRaw).Trim().ToLowerInvariant()
        }

        if ($status -in @("fresh", "active", "cache_active", "cache_fresh", "ok", "valid")) {
            $freshRows++
        }
        elseif ($status -in @("stale", "cache_stale", "stale_served", "cache_stale_refreshing", "expired")) {
            $staleRows++
            $screenStaleCounts[$screen] = [int]$screenStaleCounts[$screen] + 1
        }
        elseif ($status -in @("empty", "miss", "cache_miss", "none")) {
            $emptyRows++
        }
        elseif ($status -in @("error", "failed", "exception")) {
            $errorRows++
        }
        else {
            if ($servedFrom -match "stale") {
                $staleRows++
                $screenStaleCounts[$screen] = [int]$screenStaleCounts[$screen] + 1
            }
            elseif ($servedFrom -match "fresh|active|cache") {
                $freshRows++
            }
            else {
                $unknownRows++
            }
        }
    }

    $staleRatio = [decimal]0

    if ($totalRows -gt 0) {
        $staleRatio = [decimal]::Round(([decimal]$staleRows / [decimal]$totalRows), 4)
    }

    $dominantServedFrom = "dry_run"

    if ($servedFromCounts.Count -gt 0) {
        $dominantServedFrom = [string](
            $servedFromCounts.GetEnumerator() |
                Sort-Object -Property Value -Descending |
                Select-Object -First 1
        ).Name
    }

    $screenRatios = @{}

    foreach ($screenKey in $screenCounts.Keys) {
        $count = [int]$screenCounts[$screenKey]
        $staleCount = [int]$screenStaleCounts[$screenKey]
        $ratio = [decimal]0

        if ($count -gt 0) {
            $ratio = [decimal]::Round(([decimal]$staleCount / [decimal]$count), 4)
        }

        $screenRatios[$screenKey] = $ratio
    }

    $status = "dry_run"
    $note = "local-first scaffold; no DB query performed"

    if ($null -ne $Snapshot) {
        $status = "ok"
        $note = "cache stale-serving metrics within configured threshold"

        if ($errorRows -gt 0) {
            $status = "fail"
            $note = "cache error rows detected"
        }
        elseif ($totalRows -eq 0) {
            $status = "warning"
            $note = "no cache rows found for evaluated scope"
        }
        elseif ($staleRatio -gt $MaxStaleRatio) {
            $status = "warning"
            $note = "stale ratio exceeds configured threshold"
        }
        elseif ($emptyRows -gt 0) {
            $status = "warning"
            $note = "empty/cache miss rows detected"
        }
    }

    return [ordered]@{
        status = $status
        cache_served_from = $dominantServedFrom
        stale_ratio = $staleRatio
        max_stale_ratio = $MaxStaleRatio
        total_rows = $totalRows
        fresh_rows = $freshRows
        stale_rows = $staleRows
        empty_rows = $emptyRows
        error_rows = $errorRows
        unknown_rows = $unknownRows
        screen_type = $ScreenType
        screen_ratios = $screenRatios
        validation_note = $note
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
                reason = "async cache refresh / stale-serving checks disabled by kill switch"
                mode = $Mode
            } `
            -LogRoot $LogRoot | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName "check_cache_stale_serving" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName "cache_served_from" `
            -P0Item "P0.4" `
            -SignalValue "disabled" `
            -Status "disabled" `
            -AllowedValues "cache_fresh|cache_stale|cache_stale_refreshing|origin|empty|disabled|dry_run" `
            -SourceTableOrEndpoint "tools/workers/check_cache_stale_serving.ps1" `
            -Data @{
                dashboard_panel = "Cache Health"
                widget_key = "cache.served_from"
                owner = "API Ops"
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
            screen_type = $ScreenType
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

    $snapshot = $null

    if ($Mode -eq "SnapshotInput") {
        if ([string]::IsNullOrWhiteSpace($InputJsonPath)) {
            throw "InputJsonPath is required when Mode=SnapshotInput."
        }

        $resolvedInput = Resolve-RepoRelativePath -RepoRoot $repoRoot -Path $InputJsonPath
        $snapshot = Read-CacheSnapshot -Path $resolvedInput
    }

    $metrics = Get-CacheMetrics `
        -Snapshot $snapshot `
        -ScreenType $ScreenType `
        -MaxStaleRatio $MaxStaleRatio

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "check_cache_stale_serving" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "cache_served_from" `
        -P0Item "P0.4" `
        -SignalValue ([string]$metrics.cache_served_from) `
        -Status ([string]$metrics.status) `
        -AllowedValues "cache_fresh|cache_stale|cache_stale_refreshing|origin|empty|disabled|dry_run|unknown" `
        -SourceTableOrEndpoint "tools/workers/check_cache_stale_serving.ps1" `
        -ScreenType $ScreenType `
        -Data @{
            dashboard_panel = "Cache Health"
            widget_key = "cache.served_from"
            owner = "API Ops"
            kill_switch_name = $KillSwitchName
            mode = $Mode
            stale_ratio = $metrics.stale_ratio
            max_stale_ratio = $metrics.max_stale_ratio
            total_rows = $metrics.total_rows
            fresh_rows = $metrics.fresh_rows
            stale_rows = $metrics.stale_rows
            empty_rows = $metrics.empty_rows
            error_rows = $metrics.error_rows
            unknown_rows = $metrics.unknown_rows
            validation_note = $metrics.validation_note
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "check_cache_stale_serving" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "stale_ratio_by_screen" `
        -P0Item "P0.4" `
        -SignalValue ([string]$metrics.stale_ratio) `
        -ValueNum ([decimal]$metrics.stale_ratio) `
        -Status ([string]$metrics.status) `
        -AllowedValues "0..1" `
        -SourceTableOrEndpoint "tools/workers/check_cache_stale_serving.ps1" `
        -ScreenType $ScreenType `
        -Data @{
            dashboard_panel = "Cache Health"
            widget_key = "cache.stale_ratio.by_screen"
            owner = "API Ops"
            kill_switch_name = $KillSwitchName
            mode = $Mode
            cache_served_from = $metrics.cache_served_from
            max_stale_ratio = $metrics.max_stale_ratio
            total_rows = $metrics.total_rows
            fresh_rows = $metrics.fresh_rows
            stale_rows = $metrics.stale_rows
            empty_rows = $metrics.empty_rows
            error_rows = $metrics.error_rows
            unknown_rows = $metrics.unknown_rows
            screen_ratios = $metrics.screen_ratios
            validation_note = $metrics.validation_note
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
        -SourceName "cache_stale_serving" `
        -SourceRowCount ([int]$metrics.total_rows) `
        -RowsInserted 0 `
        -RowsUpdated 0 `
        -RowsSkipped ([int]$metrics.total_rows) `
        -RowsFailed 0 `
        -DurationMs (Get-DurationMs -Start $script:StartedAt) `
        -Data @{
            cache_served_from = $metrics.cache_served_from
            stale_ratio = $metrics.stale_ratio
            max_stale_ratio = $metrics.max_stale_ratio
            total_rows = $metrics.total_rows
            fresh_rows = $metrics.fresh_rows
            stale_rows = $metrics.stale_rows
            empty_rows = $metrics.empty_rows
            error_rows = $metrics.error_rows
            unknown_rows = $metrics.unknown_rows
            screen_type = $ScreenType
            mode = $Mode
            validation_note = $metrics.validation_note
            note = "local-first scaffold; no DB query performed"
        } `
        -LogRoot $LogRoot | Out-Null

    Write-Output "OK: cache stale-serving check completed. status=$($metrics.status) served_from=$($metrics.cache_served_from) stale_ratio=$($metrics.stale_ratio) mode=$Mode run_id=$script:RunId"
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
            -ErrorCode "CACHE_STALE_SERVING_CHECK_FAILED" `
            -ErrorMessage $message `
            -Data @{
                kill_switch_name = $KillSwitchName
                mode = $Mode
                screen_type = $ScreenType
            } `
            -LogRoot $LogRoot | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName "check_cache_stale_serving" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName "cache_served_from" `
            -P0Item "P0.4" `
            -SignalValue "failed" `
            -Status "failed" `
            -AllowedValues "cache_fresh|cache_stale|cache_stale_refreshing|origin|empty|disabled|dry_run|unknown|failed" `
            -SourceTableOrEndpoint "tools/workers/check_cache_stale_serving.ps1" `
            -ScreenType $ScreenType `
            -ErrorCode "CACHE_STALE_SERVING_CHECK_FAILED" `
            -ErrorMessage $message `
            -Data @{
                dashboard_panel = "Cache Health"
                widget_key = "cache.served_from"
                owner = "API Ops"
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