# MiraTV EPG Join Validation Worker
# File: tools/workers/check_epg_join_validation.ps1
# Purpose:
#   P0.3 EPG join validation gate scaffold.
#   Establishes observable validation for correct EPG-to-live-channel join behavior.
#
# Current implementation:
#   - Local-first, no DB writes yet.
#   - Supports DryRun and SnapshotInput modes.
#   - Emits EPG join validation and worker heartbeat signals.
#   - Does not mutate EPG/live tables.
#   - Designed to be extended with DB/query bridge checks later.
#
# Correct join rule:
#   Preferred:
#     epg_programs.epg_channel_id = live_channels.epg_channel_id
#
#   Acceptable fallback:
#     epg_programs.channel = live_channels.epg_channel_id
#
#   Bad legacy join:
#     live_channels.id = epg_programs.channel
#
# Signals:
#   - epg_join_validation_status
#   - worker_heartbeat_status
#
# Kill switch:
#   - ENABLE_EPG_JOIN_GATE
#
# Usage:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_epg_join_validation.ps1" -Environment "dev"
#
# Optional snapshot input:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/check_epg_join_validation.ps1" `
#     -Environment "dev" `
#     -Mode "SnapshotInput" `
#     -InputJsonPath "runtime/samples/epg_join_validation_snapshot.json"

[CmdletBinding()]
param(
    [string]$WorkerName = "epg_validation_gate",
    [string]$Component = "epg_validation_gate",
    [string]$Environment = "prod",
    [string]$KillSwitchName = "ENABLE_EPG_JOIN_GATE",

    [ValidateSet("DryRun", "SnapshotInput")]
    [string]$Mode = "DryRun",

    [string]$InputJsonPath = "",
    [int]$MinimumPreferredJoinRows = 1,
    [decimal]$MinimumPreferredJoinRatio = 0.80,
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

function Get-EpgJoinMetrics {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Snapshot,

        [int]$MinimumPreferredJoinRows,

        [decimal]$MinimumPreferredJoinRatio
    )

    $status = "dry_run"
    $preferredJoinRows = 0
    $fallbackJoinRows = 0
    $badLegacyJoinRows = 0
    $unmatchedProgramRows = 0
    $totalProgramRows = 0
    $preferredJoinRatio = [decimal]0
    $sourceName = "dry_run_no_db_query"
    $validationNote = "local-first scaffold; no DB query performed"

    if ($null -ne $Snapshot) {
        $preferredJoinRows = Convert-ToIntSafe -Value (Get-PropertyValue -Object $Snapshot -Names @(
            "preferred_join_rows",
            "epg_channel_id_join_rows",
            "correct_join_rows"
        ))

        $fallbackJoinRows = Convert-ToIntSafe -Value (Get-PropertyValue -Object $Snapshot -Names @(
            "fallback_join_rows",
            "channel_to_epg_channel_id_rows"
        ))

        $badLegacyJoinRows = Convert-ToIntSafe -Value (Get-PropertyValue -Object $Snapshot -Names @(
            "bad_legacy_join_rows",
            "legacy_join_rows",
            "numeric_id_join_rows"
        ))

        $unmatchedProgramRows = Convert-ToIntSafe -Value (Get-PropertyValue -Object $Snapshot -Names @(
            "unmatched_program_rows",
            "unmatched_rows",
            "missing_join_rows"
        ))

        $totalProgramRows = Convert-ToIntSafe -Value (Get-PropertyValue -Object $Snapshot -Names @(
            "total_program_rows",
            "program_count",
            "epg_program_count",
            "rows",
            "row_count"
        ))

        $ratioRaw = Get-PropertyValue -Object $Snapshot -Names @(
            "preferred_join_ratio",
            "correct_join_ratio"
        )

        $sourceRaw = Get-PropertyValue -Object $Snapshot -Names @(
            "source_name",
            "source",
            "endpoint",
            "table"
        )

        if ($totalProgramRows -le 0) {
            $totalProgramRows = $preferredJoinRows + $fallbackJoinRows + $badLegacyJoinRows + $unmatchedProgramRows
        }

        if ($null -ne $ratioRaw) {
            $preferredJoinRatio = Convert-ToDecimalSafe -Value $ratioRaw -DefaultValue 0
        }
        elseif ($totalProgramRows -gt 0) {
            $preferredJoinRatio = [decimal]::Round(([decimal]$preferredJoinRows / [decimal]$totalProgramRows), 4)
        }

        if ($null -ne $sourceRaw -and -not [string]::IsNullOrWhiteSpace([string]$sourceRaw)) {
            $sourceName = [string]$sourceRaw
        }

        $status = "pass"
        $validationNote = "preferred EPG join path is within configured threshold"

        if ($badLegacyJoinRows -gt 0) {
            $status = "fail"
            $validationNote = "bad legacy join rows detected: live_channels.id = epg_programs.channel"
        }
        elseif ($preferredJoinRows -lt $MinimumPreferredJoinRows) {
            $status = "fail"
            $validationNote = "preferred join rows below configured minimum"
        }
        elseif ($preferredJoinRatio -lt $MinimumPreferredJoinRatio) {
            $status = "warning"
            $validationNote = "preferred join ratio below configured minimum"
        }
        elseif ($fallbackJoinRows -gt 0 -or $unmatchedProgramRows -gt 0) {
            $status = "warning"
            $validationNote = "fallback or unmatched EPG rows detected"
        }
    }

    return [ordered]@{
        status = $status
        preferred_join_rows = $preferredJoinRows
        fallback_join_rows = $fallbackJoinRows
        bad_legacy_join_rows = $badLegacyJoinRows
        unmatched_program_rows = $unmatchedProgramRows
        total_program_rows = $totalProgramRows
        preferred_join_ratio = $preferredJoinRatio
        minimum_preferred_join_rows = $MinimumPreferredJoinRows
        minimum_preferred_join_ratio = $MinimumPreferredJoinRatio
        source_name = $sourceName
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
                reason = "EPG join validation gate disabled by kill switch"
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
            -AllowedValues "pass|warning|fail|disabled|dry_run" `
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
            minimum_preferred_join_ratio = $MinimumPreferredJoinRatio
            preferred_join = "epg_programs.epg_channel_id = live_channels.epg_channel_id"
            fallback_join = "epg_programs.channel = live_channels.epg_channel_id"
            prohibited_join = "live_channels.id = epg_programs.channel"
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

    $snapshot = $null

    if ($Mode -eq "SnapshotInput") {
        if ([string]::IsNullOrWhiteSpace($InputJsonPath)) {
            throw "InputJsonPath is required when Mode=SnapshotInput."
        }

        $resolvedInput = Resolve-RepoRelativePath -RepoRoot $repoRoot -Path $InputJsonPath
        $snapshot = Read-EpgJoinSnapshot -Path $resolvedInput
    }

    $metrics = Get-EpgJoinMetrics `
        -Snapshot $snapshot `
        -MinimumPreferredJoinRows $MinimumPreferredJoinRows `
        -MinimumPreferredJoinRatio $MinimumPreferredJoinRatio

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "check_epg_join_validation" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "epg_join_validation_status" `
        -P0Item "P0.3" `
        -SignalValue ([string]$metrics.status) `
        -Status ([string]$metrics.status) `
        -AllowedValues "pass|warning|fail|disabled|dry_run" `
        -SourceTableOrEndpoint "tools/workers/check_epg_join_validation.ps1" `
        -Data @{
            dashboard_panel = "EPG Health"
            widget_key = "epg.join.validation.status"
            owner = "Content Ops"
            kill_switch_name = $KillSwitchName
            mode = $Mode
            source_name = $metrics.source_name
            preferred_join_rows = $metrics.preferred_join_rows
            fallback_join_rows = $metrics.fallback_join_rows
            bad_legacy_join_rows = $metrics.bad_legacy_join_rows
            unmatched_program_rows = $metrics.unmatched_program_rows
            total_program_rows = $metrics.total_program_rows
            preferred_join_ratio = $metrics.preferred_join_ratio
            minimum_preferred_join_rows = $metrics.minimum_preferred_join_rows
            minimum_preferred_join_ratio = $metrics.minimum_preferred_join_ratio
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
        -SourceRowCount ([int]$metrics.total_program_rows) `
        -RowsInserted 0 `
        -RowsUpdated 0 `
        -RowsSkipped ([int]$metrics.total_program_rows) `
        -RowsFailed 0 `
        -DurationMs (Get-DurationMs -Start $script:StartedAt) `
        -Data @{
            epg_join_validation_status = $metrics.status
            preferred_join_rows = $metrics.preferred_join_rows
            fallback_join_rows = $metrics.fallback_join_rows
            bad_legacy_join_rows = $metrics.bad_legacy_join_rows
            unmatched_program_rows = $metrics.unmatched_program_rows
            total_program_rows = $metrics.total_program_rows
            preferred_join_ratio = $metrics.preferred_join_ratio
            validation_note = $metrics.validation_note
            mode = $Mode
            note = "local-first scaffold; no DB query performed"
        } `
        -LogRoot $LogRoot | Out-Null

    Write-Output "OK: EPG join validation completed. status=$($metrics.status) preferred_join_rows=$($metrics.preferred_join_rows) bad_legacy_join_rows=$($metrics.bad_legacy_join_rows) mode=$Mode run_id=$script:RunId"
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
            -AllowedValues "pass|warning|fail|disabled|dry_run" `
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