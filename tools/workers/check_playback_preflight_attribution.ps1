# MiraTV Playback Preflight Attribution Worker
# File: tools/workers/check_playback_preflight_attribution.ps1
# Purpose:
#   P0.7 playback preflight attribution scaffold.
#   Establishes observable checks for playback preflight outcomes and attribution coverage.
#
# Current implementation:
#   - Local-first, no DB writes yet.
#   - Supports DryRun and SnapshotInput modes.
#   - Emits playback attribution and worker heartbeat signals.
#   - Does not mutate playback, availability, or attribution tables.
#   - Designed to be extended with DB/query bridge checks later.
#
# Signals:
#   - playback_preflight_outcome
#   - attribution_coverage_percent
#   - worker_heartbeat_status
#
# Kill switch:
#   - ENABLE_PLAYBACK_ATTRIBUTION
#
# Usage:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_playback_preflight_attribution.ps1" -Environment "dev"
#
# Optional snapshot input:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_playback_preflight_attribution.ps1" `
#     -Environment "dev" `
#     -Mode "SnapshotInput" `
#     -InputJsonPath "runtime/samples/playback_preflight_attribution_snapshot.json"

[CmdletBinding()]
param(
    [string]$WorkerName = "playback_resolver",
    [string]$Component = "playback_resolver",
    [string]$Environment = "prod",
    [string]$KillSwitchName = "ENABLE_PLAYBACK_ATTRIBUTION",

    [ValidateSet("DryRun", "SnapshotInput")]
    [string]$Mode = "DryRun",

    [string]$InputJsonPath = "",
    [string]$MediaType = "",
    [decimal]$MinimumAttributionCoveragePercent = 95,
    [decimal]$MaxUnknownOutcomeRatio = 0.05,
    [int]$HeartbeatIntervalSeconds = 900,
    [int]$StaleAfterSeconds = 3600,
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

function Get-PlaybackRows {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Snapshot
    )

    if ($null -eq $Snapshot) {
        return @()
    }

    if ($Snapshot.PSObject.Properties.Name -contains "events") {
        return Convert-ToArray -Value $Snapshot.events
    }

    if ($Snapshot.PSObject.Properties.Name -contains "items") {
        return Convert-ToArray -Value $Snapshot.items
    }

    if ($Snapshot.PSObject.Properties.Name -contains "playback_events") {
        return Convert-ToArray -Value $Snapshot.playback_events
    }

    if ($Snapshot.PSObject.Properties.Name -contains "results") {
        return Convert-ToArray -Value $Snapshot.results
    }

    return Convert-ToArray -Value $Snapshot
}

function Normalize-PlaybackOutcome {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return "unknown"
    }

    $raw = ([string]$Value).Trim().ToLowerInvariant()

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return "unknown"
    }

    switch -Regex ($raw) {
        "^(ok|playable|success|resolved|can_play)$" {
            return "playable"
        }
        "^(unavailable|not_available|provider_unavailable|gone)$" {
            return "unavailable"
        }
        "^(stale_id|stale|missing_provider_id|id_stale)$" {
            return "stale_id"
        }
        "^(bouquet_denied|bouquet|access_denied|entitlement_denied|not_entitled|denied)$" {
            return "bouquet_denied"
        }
        "^(provider_error|provider_failed|upstream_error|http_5xx)$" {
            return "provider_error"
        }
        "^(container_unsupported|unsupported_container|codec_unsupported|unsupported_codec)$" {
            return "container_unsupported"
        }
        "^(resolver_error|resolver_failed|preflight_error|exception)$" {
            return "resolver_error"
        }
        "^(timeout|network_timeout)$" {
            return "provider_error"
        }
        "^(406|http_406)$" {
            return "bouquet_denied"
        }
        "^(404|http_404)$" {
            return "unavailable"
        }
        default {
            return "unknown"
        }
    }
}

function Get-PlaybackMetrics {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Snapshot,

        [string]$MediaType,

        [decimal]$MinimumAttributionCoveragePercent,

        [decimal]$MaxUnknownOutcomeRatio
    )

    $rows = Get-PlaybackRows -Snapshot $Snapshot

    if (-not [string]::IsNullOrWhiteSpace($MediaType)) {
        $rows = @(
            $rows | Where-Object {
                $mediaRaw = Get-PropertyValue -Object $_ -Names @("media_type", "content_type", "type")
                ([string]$mediaRaw).Trim().ToLowerInvariant() -eq $MediaType.Trim().ToLowerInvariant()
            }
        )
    }

    $totalEvents = @($rows).Count
    $attributedEvents = 0
    $unknownEvents = 0
    $playableCount = 0
    $unavailableCount = 0
    $staleIdCount = 0
    $bouquetDeniedCount = 0
    $providerErrorCount = 0
    $containerUnsupportedCount = 0
    $resolverErrorCount = 0

    $outcomeCounts = @{
        playable = 0
        unavailable = 0
        stale_id = 0
        bouquet_denied = 0
        provider_error = 0
        container_unsupported = 0
        resolver_error = 0
        unknown = 0
    }

    foreach ($row in $rows) {
        $outcomeRaw = Get-PropertyValue -Object $row -Names @(
            "playback_preflight_outcome",
            "preflight_outcome",
            "outcome",
            "attribution",
            "result",
            "status"
        )

        $outcome = Normalize-PlaybackOutcome -Value $outcomeRaw

        if (-not $outcomeCounts.ContainsKey($outcome)) {
            $outcome = "unknown"
        }

        $outcomeCounts[$outcome] = [int]$outcomeCounts[$outcome] + 1

        if ($outcome -ne "unknown") {
            $attributedEvents++
        }
        else {
            $unknownEvents++
        }
    }

    $playableCount = [int]$outcomeCounts["playable"]
    $unavailableCount = [int]$outcomeCounts["unavailable"]
    $staleIdCount = [int]$outcomeCounts["stale_id"]
    $bouquetDeniedCount = [int]$outcomeCounts["bouquet_denied"]
    $providerErrorCount = [int]$outcomeCounts["provider_error"]
    $containerUnsupportedCount = [int]$outcomeCounts["container_unsupported"]
    $resolverErrorCount = [int]$outcomeCounts["resolver_error"]

    $coveragePercent = [decimal]0
    $unknownRatio = [decimal]0

    if ($totalEvents -gt 0) {
        $coveragePercent = [decimal]::Round(([decimal]$attributedEvents / [decimal]$totalEvents) * 100, 2)
        $unknownRatio = [decimal]::Round(([decimal]$unknownEvents / [decimal]$totalEvents), 4)
    }

    $dominantOutcome = "dry_run"

    if ($totalEvents -gt 0) {
        $dominantOutcome = [string](
            $outcomeCounts.GetEnumerator() |
                Sort-Object -Property Value -Descending |
                Select-Object -First 1
        ).Name
    }

    $status = "dry_run"
    $note = "local-first scaffold; no DB query performed"

    if ($null -ne $Snapshot) {
        $status = "ok"
        $note = "playback preflight attribution metrics within configured thresholds"

        if ($totalEvents -eq 0) {
            $status = "warning"
            $note = "no playback preflight events found for evaluated scope"
        }
        elseif ($coveragePercent -lt $MinimumAttributionCoveragePercent) {
            $status = "warning"
            $note = "attribution coverage below configured threshold"
        }
        elseif ($unknownRatio -gt $MaxUnknownOutcomeRatio) {
            $status = "warning"
            $note = "unknown outcome ratio above configured threshold"
        }
        elseif ($resolverErrorCount -gt 0) {
            $status = "warning"
            $note = "resolver errors detected"
        }
    }

    return [ordered]@{
        status = $status
        playback_preflight_outcome = $dominantOutcome
        attribution_coverage_percent = $coveragePercent
        unknown_outcome_ratio = $unknownRatio
        minimum_attribution_coverage_percent = $MinimumAttributionCoveragePercent
        max_unknown_outcome_ratio = $MaxUnknownOutcomeRatio
        total_events = $totalEvents
        attributed_events = $attributedEvents
        unknown_events = $unknownEvents
        playable_count = $playableCount
        unavailable_count = $unavailableCount
        stale_id_count = $staleIdCount
        bouquet_denied_count = $bouquetDeniedCount
        provider_error_count = $providerErrorCount
        container_unsupported_count = $containerUnsupportedCount
        resolver_error_count = $resolverErrorCount
        media_type = $MediaType
        outcome_counts = $outcomeCounts
        validation_note = $note
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
            -SourceName "playback_preflight_attribution" `
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
            -AllowedValues "playable|unavailable|stale_id|bouquet_denied|provider_error|container_unsupported|resolver_error|unknown|disabled|dry_run|failed" `
            -SourceTableOrEndpoint "tools/workers/check_playback_preflight_attribution.ps1" `
            -Data @{
                dashboard_panel = "Playback Diagnostics"
                widget_key = "playback.preflight.outcome"
                owner = "SRE"
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
        -SourceName "playback_preflight_attribution" `
        -Data @{
            kill_switch_name = $KillSwitchName
            mode = $Mode
            media_type = $MediaType
            minimum_attribution_coverage_percent = $MinimumAttributionCoveragePercent
            max_unknown_outcome_ratio = $MaxUnknownOutcomeRatio
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

    $snapshot = $null

    if ($Mode -eq "SnapshotInput") {
        if ([string]::IsNullOrWhiteSpace($InputJsonPath)) {
            throw "InputJsonPath is required when Mode=SnapshotInput."
        }

        $resolvedInput = Resolve-RepoRelativePath -RepoRoot $repoRoot -Path $InputJsonPath
        $snapshot = Read-PlaybackSnapshot -Path $resolvedInput
    }

    $metrics = Get-PlaybackMetrics `
        -Snapshot $snapshot `
        -MediaType $MediaType `
        -MinimumAttributionCoveragePercent $MinimumAttributionCoveragePercent `
        -MaxUnknownOutcomeRatio $MaxUnknownOutcomeRatio

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
        -AllowedValues "playable|unavailable|stale_id|bouquet_denied|provider_error|container_unsupported|resolver_error|unknown|disabled|dry_run|failed" `
        -SourceTableOrEndpoint "tools/workers/check_playback_preflight_attribution.ps1" `
        -Data @{
            dashboard_panel = "Playback Diagnostics"
            widget_key = "playback.preflight.outcome"
            owner = "SRE"
            kill_switch_name = $KillSwitchName
            mode = $Mode
            media_type = $MediaType
            total_events = $metrics.total_events
            attributed_events = $metrics.attributed_events
            unknown_events = $metrics.unknown_events
            unknown_outcome_ratio = $metrics.unknown_outcome_ratio
            playable_count = $metrics.playable_count
            unavailable_count = $metrics.unavailable_count
            stale_id_count = $metrics.stale_id_count
            bouquet_denied_count = $metrics.bouquet_denied_count
            provider_error_count = $metrics.provider_error_count
            container_unsupported_count = $metrics.container_unsupported_count
            resolver_error_count = $metrics.resolver_error_count
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
            dashboard_panel = "Playback Diagnostics"
            widget_key = "playback.attribution.coverage_percent"
            owner = "SRE"
            kill_switch_name = $KillSwitchName
            mode = $Mode
            media_type = $MediaType
            minimum_attribution_coverage_percent = $metrics.minimum_attribution_coverage_percent
            max_unknown_outcome_ratio = $metrics.max_unknown_outcome_ratio
            total_events = $metrics.total_events
            attributed_events = $metrics.attributed_events
            unknown_events = $metrics.unknown_events
            validation_note = $metrics.validation_note
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
        -SourceName "playback_preflight_attribution" `
        -SourceRowCount ([int]$metrics.total_events) `
        -RowsInserted 0 `
        -RowsUpdated 0 `
        -RowsSkipped ([int]$metrics.total_events) `
        -RowsFailed ([int]$metrics.unknown_events) `
        -DurationMs (Get-DurationMs -Start $script:StartedAt) `
        -Data @{
            playback_preflight_outcome = $metrics.playback_preflight_outcome
            attribution_coverage_percent = $metrics.attribution_coverage_percent
            unknown_outcome_ratio = $metrics.unknown_outcome_ratio
            total_events = $metrics.total_events
            attributed_events = $metrics.attributed_events
            unknown_events = $metrics.unknown_events
            playable_count = $metrics.playable_count
            unavailable_count = $metrics.unavailable_count
            stale_id_count = $metrics.stale_id_count
            bouquet_denied_count = $metrics.bouquet_denied_count
            provider_error_count = $metrics.provider_error_count
            container_unsupported_count = $metrics.container_unsupported_count
            resolver_error_count = $metrics.resolver_error_count
            media_type = $MediaType
            mode = $Mode
            validation_note = $metrics.validation_note
            note = "local-first scaffold; no DB query performed"
        } `
        -LogRoot $LogRoot | Out-Null

    Write-Output "OK: playback preflight attribution check completed. outcome=$($metrics.playback_preflight_outcome) coverage_percent=$($metrics.attribution_coverage_percent) mode=$Mode run_id=$script:RunId"
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
            -SourceName "playback_preflight_attribution" `
            -DurationMs $duration `
            -ErrorCode "PLAYBACK_PREFLIGHT_ATTRIBUTION_CHECK_FAILED" `
            -ErrorMessage $message `
            -Data @{
                kill_switch_name = $KillSwitchName
                mode = $Mode
                media_type = $MediaType
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
            -SignalValue "failed" `
            -Status "failed" `
            -AllowedValues "playable|unavailable|stale_id|bouquet_denied|provider_error|container_unsupported|resolver_error|unknown|disabled|dry_run|failed" `
            -SourceTableOrEndpoint "tools/workers/check_playback_preflight_attribution.ps1" `
            -ErrorCode "PLAYBACK_PREFLIGHT_ATTRIBUTION_CHECK_FAILED" `
            -ErrorMessage $message `
            -Data @{
                dashboard_panel = "Playback Diagnostics"
                widget_key = "playback.preflight.outcome"
                owner = "SRE"
                kill_switch_name = $KillSwitchName
                mode = $Mode
                media_type = $MediaType
            } `
            -LogRoot $LogRoot | Out-Null
    }
    catch {
        Write-Error "Playback preflight attribution worker failed and failed to log error: $($_.Exception.Message)"
    }

    Write-Error "FAILED: playback preflight attribution worker failed. run_id=$script:RunId error=$message"
    exit 1
}