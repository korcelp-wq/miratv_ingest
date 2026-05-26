# MiraTV DB Quality Gates Worker
# File: tools/workers/run_db_quality_gates.ps1
# Purpose:
#   P0.5 automated DB quality gates scaffold.
#   Establishes observable quality gates for live/cache data quality before DB-backed enforcement.
#
# Current implementation:
#   - Local-first, no DB writes yet.
#   - Supports DryRun and SnapshotInput modes.
#   - Emits quality gate, duplicate ratio, blank key ratio, filter diversity, and heartbeat signals.
#   - Does not mutate database tables.
#   - Designed to be extended with DB/query bridge checks later.
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
# Usage:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/run_db_quality_gates.ps1" -Environment "dev"
#
# Optional snapshot input:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/run_db_quality_gates.ps1" `
#     -Environment "dev" `
#     -Mode "SnapshotInput" `
#     -InputJsonPath "runtime/samples/db_quality_snapshot.json"

[CmdletBinding()]
param(
    [string]$WorkerName = "db_quality_gate",
    [string]$Component = "db_quality_gate",
    [string]$Environment = "prod",
    [string]$KillSwitchName = "ENABLE_DB_QUALITY_GATE_AUTOMATION",

    [ValidateSet("DryRun", "SnapshotInput")]
    [string]$Mode = "DryRun",

    [string]$InputJsonPath = "",
    [string]$ScreenType = "",
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

function Get-QualityRows {
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

    if ($Snapshot.PSObject.Properties.Name -contains "metrics") {
        return Convert-ToArray -Value $Snapshot.metrics
    }

    if ($Snapshot.PSObject.Properties.Name -contains "results") {
        return Convert-ToArray -Value $Snapshot.results
    }

    return Convert-ToArray -Value $Snapshot
}

function Get-DbQualityMetrics {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Snapshot,

        [string]$ScreenType,

        [decimal]$MaxDuplicateRatio,

        [decimal]$MaxBlankKeyRatio,

        [int]$MinimumFilterDiversityScore
    )

    $rows = Get-QualityRows -Snapshot $Snapshot

    if (-not [string]::IsNullOrWhiteSpace($ScreenType)) {
        $rows = @(
            $rows | Where-Object {
                $screenRaw = Get-PropertyValue -Object $_ -Names @("screen_type", "screen", "page")
                ([string]$screenRaw).Trim().ToLowerInvariant() -eq $ScreenType.Trim().ToLowerInvariant()
            }
        )
    }

    $totalScreens = @($rows).Count
    $worstDuplicateRatio = [decimal]0
    $worstBlankKeyRatio = [decimal]0
    $lowestFilterDiversityScore = 999999
    $failedScreens = 0
    $warningScreens = 0
    $screenSummaries = @()

    foreach ($row in $rows) {
        $screenRaw = Get-PropertyValue -Object $row -Names @("screen_type", "screen", "page")
        $screen = "unknown"

        if ($null -ne $screenRaw -and -not [string]::IsNullOrWhiteSpace([string]$screenRaw)) {
            $screen = ([string]$screenRaw).Trim().ToLowerInvariant()
        }

        $duplicateRatio = Convert-ToDecimalSafe -Value (Get-PropertyValue -Object $row -Names @("duplicate_ratio", "dupe_ratio", "duplicate_rate")) -DefaultValue 0
        $blankKeyRatio = Convert-ToDecimalSafe -Value (Get-PropertyValue -Object $row -Names @("blank_key_ratio", "missing_key_ratio", "blank_keys_ratio")) -DefaultValue 0
        $filterDiversityScore = Convert-ToIntSafe -Value (Get-PropertyValue -Object $row -Names @("filter_diversity_score", "filter_count", "distinct_filter_count")) -DefaultValue 0

        if ($duplicateRatio -gt $worstDuplicateRatio) {
            $worstDuplicateRatio = $duplicateRatio
        }

        if ($blankKeyRatio -gt $worstBlankKeyRatio) {
            $worstBlankKeyRatio = $blankKeyRatio
        }

        if ($filterDiversityScore -lt $lowestFilterDiversityScore) {
            $lowestFilterDiversityScore = $filterDiversityScore
        }

        $screenStatus = "pass"
        $screenNote = "quality metrics within configured thresholds"

        if ($duplicateRatio -gt $MaxDuplicateRatio -or $blankKeyRatio -gt $MaxBlankKeyRatio) {
            $screenStatus = "fail"
            $screenNote = "hard quality threshold exceeded"
            $failedScreens++
        }
        elseif ($filterDiversityScore -lt $MinimumFilterDiversityScore) {
            $screenStatus = "warning"
            $screenNote = "filter diversity below configured minimum"
            $warningScreens++
        }

        $screenSummaries += [ordered]@{
            screen_type = $screen
            status = $screenStatus
            duplicate_ratio = $duplicateRatio
            blank_key_ratio = $blankKeyRatio
            filter_diversity_score = $filterDiversityScore
            note = $screenNote
        }
    }

    if ($lowestFilterDiversityScore -eq 999999) {
        $lowestFilterDiversityScore = 0
    }

    $status = "dry_run"
    $qualityGateResult = "not_run"
    $note = "local-first scaffold; no DB query performed"

    if ($null -ne $Snapshot) {
        $status = "pass"
        $qualityGateResult = "pass"
        $note = "quality gate metrics within configured thresholds"

        if ($totalScreens -eq 0) {
            $status = "warning"
            $qualityGateResult = "warning"
            $note = "no quality rows found for evaluated scope"
        }
        elseif ($failedScreens -gt 0) {
            $status = "fail"
            $qualityGateResult = "fail"
            $note = "one or more hard quality thresholds exceeded"
        }
        elseif ($warningScreens -gt 0) {
            $status = "warning"
            $qualityGateResult = "warning"
            $note = "one or more warning quality thresholds exceeded"
        }
    }

    return [ordered]@{
        status = $status
        quality_gate_result = $qualityGateResult
        duplicate_ratio = $worstDuplicateRatio
        blank_key_ratio = $worstBlankKeyRatio
        filter_diversity_score = $lowestFilterDiversityScore
        max_duplicate_ratio = $MaxDuplicateRatio
        max_blank_key_ratio = $MaxBlankKeyRatio
        minimum_filter_diversity_score = $MinimumFilterDiversityScore
        total_screens = $totalScreens
        failed_screens = $failedScreens
        warning_screens = $warningScreens
        screen_type = $ScreenType
        screen_summaries = $screenSummaries
        validation_note = $note
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
            screen_type = $ScreenType
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

    $snapshot = $null

    if ($Mode -eq "SnapshotInput") {
        if ([string]::IsNullOrWhiteSpace($InputJsonPath)) {
            throw "InputJsonPath is required when Mode=SnapshotInput."
        }

        $resolvedInput = Resolve-RepoRelativePath -RepoRoot $repoRoot -Path $InputJsonPath
        $snapshot = Read-QualitySnapshot -Path $resolvedInput
    }

    $metrics = Get-DbQualityMetrics `
        -Snapshot $snapshot `
        -ScreenType $ScreenType `
        -MaxDuplicateRatio $MaxDuplicateRatio `
        -MaxBlankKeyRatio $MaxBlankKeyRatio `
        -MinimumFilterDiversityScore $MinimumFilterDiversityScore

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
        -ScreenType $ScreenType `
        -Data @{
            dashboard_panel = "Quality Gates"
            widget_key = "quality.gate.result"
            owner = "Content Ops"
            kill_switch_name = $KillSwitchName
            mode = $Mode
            total_screens = $metrics.total_screens
            failed_screens = $metrics.failed_screens
            warning_screens = $metrics.warning_screens
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
        -ScreenType $ScreenType `
        -Data @{
            dashboard_panel = "Quality Gates"
            widget_key = "quality.duplicate_ratio.by_screen"
            owner = "Content Ops"
            kill_switch_name = $KillSwitchName
            max_duplicate_ratio = $metrics.max_duplicate_ratio
            mode = $Mode
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
        -ScreenType $ScreenType `
        -Data @{
            dashboard_panel = "Quality Gates"
            widget_key = "quality.blank_key_ratio.by_screen"
            owner = "Content Ops"
            kill_switch_name = $KillSwitchName
            max_blank_key_ratio = $metrics.max_blank_key_ratio
            mode = $Mode
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
        -ScreenType $ScreenType `
        -Data @{
            dashboard_panel = "Quality Gates"
            widget_key = "quality.filter_diversity_score.by_screen"
            owner = "Content Ops"
            kill_switch_name = $KillSwitchName
            minimum_filter_diversity_score = $metrics.minimum_filter_diversity_score
            mode = $Mode
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
        -SourceName "db_quality_gates" `
        -SourceRowCount ([int]$metrics.total_screens) `
        -RowsInserted 0 `
        -RowsUpdated 0 `
        -RowsSkipped ([int]$metrics.total_screens) `
        -RowsFailed ([int]$metrics.failed_screens) `
        -DurationMs (Get-DurationMs -Start $script:StartedAt) `
        -Data @{
            quality_gate_result = $metrics.quality_gate_result
            duplicate_ratio = $metrics.duplicate_ratio
            blank_key_ratio = $metrics.blank_key_ratio
            filter_diversity_score = $metrics.filter_diversity_score
            total_screens = $metrics.total_screens
            failed_screens = $metrics.failed_screens
            warning_screens = $metrics.warning_screens
            screen_type = $ScreenType
            mode = $Mode
            validation_note = $metrics.validation_note
            note = "local-first scaffold; no DB query performed"
        } `
        -LogRoot $LogRoot | Out-Null

    Write-Output "OK: DB quality gates completed. result=$($metrics.quality_gate_result) duplicate_ratio=$($metrics.duplicate_ratio) blank_key_ratio=$($metrics.blank_key_ratio) filter_diversity_score=$($metrics.filter_diversity_score) mode=$Mode run_id=$script:RunId"
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
                screen_type = $ScreenType
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
            -ScreenType $ScreenType `
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