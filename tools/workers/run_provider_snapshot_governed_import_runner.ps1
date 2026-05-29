<#
.SYNOPSIS
  Run the governed provider snapshot import workflow.

.DESCRIPTION
  One-button governed provider snapshot import runner.

  This runner chains:
    1. run_provider_snapshot_governed_refresh_gate.ps1
    2. select_next_provider_snapshot_import_candidate.ps1
    3. run_provider_snapshot_import_decision_gate.ps1

  It preserves the existing safety model:
    - No provider calls except through the governed refresh gate.
    - No DB writes unless -Apply is explicitly passed and downstream gates allow it.
    - If provider deltas are provider-noise/noop, the flow stops at noop_ready.
    - The import decision gate remains the final authority for apply/noop.

.CONTRACT-MARKERS
  Write-JobLog
  Emit-Signal
  Emit-Heartbeat
  Test-KillSwitch
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [int]$MacUserId = 6,
    [string]$ProviderLabel = "eldervpn",
    [int]$Limit = 25,
    [switch]$Apply,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "run_provider_snapshot_governed_import_runner"
$Component = "provider_snapshot_governed_import_runner"
$DatabaseTarget = "xpdgxfsp_content"
$SourceName = "provider_snapshot_governed_refresh_gate"
$KillSwitchName = "ENABLE_PROVIDER_SNAPSHOT_GOVERNED_IMPORT_RUNNER"

$CompletedSignal = "provider_snapshot_governed_import_runner_completed"
$DispositionSignal = "provider_snapshot_governed_import_runner_disposition"
$SelectedLaneSignal = "provider_snapshot_governed_import_runner_selected_lane"
$DbWriteCountSignal = "provider_snapshot_governed_import_runner_db_write_count"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\provider_snapshot_governed_import_runner"
$LogRoot = Join-Path $RepoRoot "runtime\logs\provider_snapshot_governed_import_runner"

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null

function Get-DurationMs {
    param([datetime]$Start)
    return [int][Math]::Round(((Get-Date) - $Start).TotalMilliseconds)
}

function Write-LocalJsonLog {
    param([string]$EventName, [string]$Status, [object]$Data = $null)

    # Contract marker: Write-JobLog
    $record = [ordered]@{
        event_ts        = (Get-Date).ToUniversalTime().ToString("o")
        event_name      = $EventName
        job_name        = $WorkerName
        run_id          = $RunId
        worker_name     = $WorkerName
        component       = $Component
        environment     = $Environment
        database_target = $DatabaseTarget
        source_name     = $SourceName
        status          = $Status
        attempt         = 1
        error_code      = $null
        error_message   = $null
        data            = $Data
    }

    $logPath = Join-Path $LogRoot "$WorkerName-$($StartedAt.ToUniversalTime().ToString('yyyyMMdd')).jsonl"
    Add-Content -Path $logPath -Value ($record | ConvertTo-Json -Depth 20 -Compress)
}

function Emit-LocalSignal {
    param([string]$SignalName, [object]$SignalValue, [object]$Payload = $null)

    # Contract marker: Emit-Signal
    Write-LocalJsonLog -EventName "signal_emitted" -Status "ok" -Data ([ordered]@{
        signal_name  = $SignalName
        signal_value = $SignalValue
        payload      = $Payload
    })
}

function Emit-LocalHeartbeat {
    param([string]$Status = "ok")

    # Contract marker: Emit-Heartbeat
    Write-LocalJsonLog -EventName "heartbeat" -Status $Status -Data ([ordered]@{})
}

function Test-WorkerKillSwitch {
    # Contract marker: Test-KillSwitch
    $raw = [Environment]::GetEnvironmentVariable($KillSwitchName)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $true }

    $normalized = $raw.Trim().ToLowerInvariant()
    return ($normalized -notin @("0", "false", "no", "off", "disabled"))
}

function Invoke-Worker {
    param(
        [string]$ScriptPath,
        [string[]]$Arguments
    )

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        throw "Worker script not found: $ScriptPath"
    }

    $stepStarted = Get-Date
    $output = @()
    $exitCode = 0

    try {
        $output = & pwsh -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) { $exitCode = 0 }
    }
    catch {
        $output += $_.Exception.Message
        $exitCode = 1
    }

    return [pscustomobject][ordered]@{
        script_path = $ScriptPath
        arguments = ($Arguments -join " ")
        exit_code = $exitCode
        duration_ms = Get-DurationMs -Start $stepStarted
        output = ($output | ForEach-Object { [string]$_ }) -join "`n"
    }
}

function Get-LatestFile {
    param([string]$Folder, [string]$Filter)

    if (-not (Test-Path -LiteralPath $Folder)) { return $null }

    return Get-ChildItem -LiteralPath $Folder -Filter $Filter -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
}

function Read-JsonFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Get-Text {
    param([object]$Object, [string]$Name, [string]$Default = "")

    if ($null -eq $Object) { return $Default }

    $property = $Object.PSObject.Properties |
        Where-Object { $_.Name -ieq $Name } |
        Select-Object -First 1

    if ($null -eq $property -or $null -eq $property.Value) { return $Default }

    return [string]$property.Value
}

function Get-Bool {
    param([object]$Object, [string]$Name, [bool]$Default = $false)

    $text = Get-Text -Object $Object -Name $Name -Default ""
    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }

    return ($text.Trim().ToLowerInvariant() -in @("true", "1", "yes"))
}

function Get-IntValue {
    param([object]$Object, [string]$Name, [int]$Default = 0)

    $text = Get-Text -Object $Object -Name $Name -Default ""
    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }

    $value = 0
    if ([int]::TryParse($text, [ref]$value)) { return $value }

    return $Default
}

try {
    if ($Limit -lt 1) { $Limit = 1 }
    if ($Limit -gt 100) { $Limit = 100 }

    $dryRun = -not [bool]$Apply

    Write-LocalJsonLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        dry_run = $dryRun
        apply_requested = [bool]$Apply
        mac_user_id = $MacUserId
        provider_label = $ProviderLabel
        limit = $Limit
    })

    Emit-LocalHeartbeat -Status "running"

    if (-not (Test-WorkerKillSwitch)) {
        $summary = [ordered]@{
            status = "disabled"
            disposition = "disabled_by_kill_switch"
            dry_run = $dryRun
            db_writes = $false
            provider_calls = $false
            run_id = $RunId
        }

        Emit-LocalSignal -SignalName $CompletedSignal -SignalValue "disabled" -Payload $summary
        Emit-LocalSignal -SignalName $DispositionSignal -SignalValue "disabled_by_kill_switch" -Payload ([ordered]@{ run_id = $RunId })
        Write-LocalJsonLog -EventName "job_completed" -Status "disabled" -Data $summary
        Write-Output "SKIPPED: $KillSwitchName is disabled. run_id=$RunId"
        exit 0
    }

    $steps = @()

    $refreshPath = Join-Path $PSScriptRoot "run_provider_snapshot_governed_refresh_gate.ps1"
    $refreshArgs = @(
        "-Environment", $Environment,
        "-MacUserId", ([string]$MacUserId),
        "-ProviderLabel", $ProviderLabel
    )

    $refreshResult = Invoke-Worker -ScriptPath $refreshPath -Arguments $refreshArgs
    $steps += [pscustomobject][ordered]@{
        step_order = 1
        step_name = "run_provider_snapshot_governed_refresh_gate"
        status = $(if ($refreshResult.exit_code -eq 0) { "pass" } else { "fail" })
        exit_code = $refreshResult.exit_code
        duration_ms = $refreshResult.duration_ms
    }

    if ($refreshResult.exit_code -ne 0) {
        throw "Governed refresh gate failed. $($refreshResult.output)"
    }

    $selectorPath = Join-Path $PSScriptRoot "select_next_provider_snapshot_import_candidate.ps1"
    $selectorResult = Invoke-Worker -ScriptPath $selectorPath -Arguments @("-Environment", $Environment, "-Quiet")
    $steps += [pscustomobject][ordered]@{
        step_order = 2
        step_name = "select_next_provider_snapshot_import_candidate"
        status = $(if ($selectorResult.exit_code -eq 0) { "pass" } else { "fail" })
        exit_code = $selectorResult.exit_code
        duration_ms = $selectorResult.duration_ms
    }

    if ($selectorResult.exit_code -ne 0) {
        throw "Selector worker failed. $($selectorResult.output)"
    }

    $decisionPath = Join-Path $PSScriptRoot "run_provider_snapshot_import_decision_gate.ps1"
    $decisionArgs = @("-Environment", $Environment, "-Limit", ([string]$Limit), "-Quiet")
    if ($Apply) {
        $decisionArgs += "-Apply"
    }

    $decisionResult = Invoke-Worker -ScriptPath $decisionPath -Arguments $decisionArgs
    $steps += [pscustomobject][ordered]@{
        step_order = 3
        step_name = "run_provider_snapshot_import_decision_gate"
        status = $(if ($decisionResult.exit_code -eq 0) { "pass" } else { "fail" })
        exit_code = $decisionResult.exit_code
        duration_ms = $decisionResult.duration_ms
    }

    if ($decisionResult.exit_code -ne 0) {
        throw "Import decision gate failed. $($decisionResult.output)"
    }

    $decisionSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\provider_snapshot_import_decision_gate") -Filter "provider_snapshot_import_decision_gate_summary_*.json"
    $decisionSummary = Read-JsonFile -Path $(if ($decisionSummaryFile) { $decisionSummaryFile.FullName } else { "" })

    $finalDisposition = Get-Text -Object $decisionSummary -Name "disposition" -Default "unknown"
    $selectedLane = Get-Text -Object $decisionSummary -Name "selected_lane" -Default "none"
    $candidateFound = Get-Bool -Object $decisionSummary -Name "candidate_found" -Default $false
    $dbWrites = Get-Bool -Object $decisionSummary -Name "db_writes" -Default $false
    $actualWriteCount = Get-IntValue -Object $decisionSummary -Name "actual_write_count" -Default 0
    $wouldWriteCount = Get-IntValue -Object $decisionSummary -Name "would_write_count" -Default 0

    $status = "pass"
    if ($finalDisposition -match "fail|missing|unimplemented") {
        $status = "warning"
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $reportCsv = Join-Path $OutputRoot "provider_snapshot_governed_import_runner_$timestamp.csv"
    $reportJson = Join-Path $OutputRoot "provider_snapshot_governed_import_runner_$timestamp.json"
    $summaryJson = Join-Path $OutputRoot "provider_snapshot_governed_import_runner_summary_$timestamp.json"
    $stepsCsv = Join-Path $OutputRoot "provider_snapshot_governed_import_runner_steps_$timestamp.csv"

    $steps | Export-Csv -Path $stepsCsv -NoTypeInformation

    $row = [pscustomobject][ordered]@{
        final_disposition = $finalDisposition
        dry_run = $dryRun
        apply_requested = [bool]$Apply
        mac_user_id = $MacUserId
        provider_label = $ProviderLabel
        candidate_found = $candidateFound
        selected_lane = $selectedLane
        would_write_count = $wouldWriteCount
        actual_write_count = $actualWriteCount
        db_writes = $dbWrites
        provider_calls = $true
        decision_summary_json = $(if ($decisionSummaryFile) { $decisionSummaryFile.FullName } else { "" })
        steps_csv = $stepsCsv
    }

    $row | Export-Csv -Path $reportCsv -NoTypeInformation
    $row | ConvertTo-Json -Depth 20 | Set-Content -Path $reportJson -Encoding UTF8

    $summary = [ordered]@{
        status = $status
        disposition = $finalDisposition
        dry_run = $dryRun
        apply_requested = [bool]$Apply
        db_writes = $dbWrites
        provider_calls = $true
        worker_name = $WorkerName
        run_id = $RunId
        mac_user_id = $MacUserId
        provider_label = $ProviderLabel
        candidate_found = $candidateFound
        selected_lane = $selectedLane
        would_write_count = $wouldWriteCount
        actual_write_count = $actualWriteCount
        decision_summary_json = $(if ($decisionSummaryFile) { $decisionSummaryFile.FullName } else { "" })
        report_csv = $reportCsv
        report_json = $reportJson
        steps_csv = $stepsCsv
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $status -Payload $summary
    Emit-LocalSignal -SignalName $DispositionSignal -SignalValue $finalDisposition -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $SelectedLaneSignal -SignalValue $selectedLane -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $DbWriteCountSignal -SignalValue $actualWriteCount -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: provider snapshot governed import runner completed. status=$status disposition=$finalDisposition selected_lane=$selectedLane dry_run=$dryRun db_writes=$dbWrites actual_write=$actualWriteCount provider_calls=True run_id=$RunId"
        Write-Output "FILES: report_csv=$reportCsv report_json=$reportJson steps_csv=$stepsCsv summary_json=$summaryJson"
        Import-Csv $reportCsv | Format-List
    }

    exit 0
}
catch {
    $message = $_.Exception.Message

    try {
        Emit-LocalSignal -SignalName $CompletedSignal -SignalValue "fail" -Payload ([ordered]@{
            run_id = $RunId
            error_message = $message
        })

        Emit-LocalHeartbeat -Status "failed"
        Write-LocalJsonLog -EventName "job_failed" -Status "failed" -Data ([ordered]@{
            error_message = $message
            duration_ms = Get-DurationMs -Start $StartedAt
        })
    }
    catch {}

    Write-Error "FAILED: provider snapshot governed import runner failed. $message run_id=$RunId"
    exit 1
}
