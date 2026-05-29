<#
.SYNOPSIS
  Run the provider snapshot import decision gate.

.DESCRIPTION
  Read-only/dry-run-first runner.

  This runner executes the import candidate selector first. If no candidate exists,
  it stops with noop_ready. If the selector chooses vod_streams, it runs the VOD
  limited apply gate in dry-run mode unless -Apply is explicitly passed.

  This runner does not call providers.
  This runner does not mutate real readiness or execution-plan reports.
  This runner does not write to the database unless -Apply is explicitly requested
  and the downstream apply worker allows it.

  With the current provider-noise cycle, this should stop at noop_ready.

.CONTRACT-MARKERS
  Write-JobLog
  Emit-Signal
  Emit-Heartbeat
  Test-KillSwitch
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [int]$Limit = 25,
    [switch]$Apply,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "run_provider_snapshot_import_decision_gate"
$Component = "provider_snapshot_import_decision_gate"
$DatabaseTarget = "xpdgxfsp_content"
$SourceName = "provider_snapshot_import_candidate_selector"
$KillSwitchName = "ENABLE_PROVIDER_SNAPSHOT_IMPORT_DECISION_GATE"

$CompletedSignal = "provider_snapshot_import_decision_gate_completed"
$DispositionSignal = "provider_snapshot_import_decision_gate_disposition"
$SelectedLaneSignal = "provider_snapshot_import_decision_gate_selected_lane"
$DbWriteCountSignal = "provider_snapshot_import_decision_gate_db_write_count"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\provider_snapshot_import_decision_gate"
$LogRoot = Join-Path $RepoRoot "runtime\logs\provider_snapshot_import_decision_gate"

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

    $output = @()
    $exitCode = 0
    $stepStarted = Get-Date

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

    $selectorPath = Join-Path $PSScriptRoot "select_next_provider_snapshot_import_candidate.ps1"
    $selectorResult = Invoke-Worker -ScriptPath $selectorPath -Arguments @("-Environment", $Environment, "-Quiet")
    $steps += [pscustomobject][ordered]@{
        step_order = 1
        step_name = "select_next_provider_snapshot_import_candidate"
        status = $(if ($selectorResult.exit_code -eq 0) { "pass" } else { "fail" })
        exit_code = $selectorResult.exit_code
        duration_ms = $selectorResult.duration_ms
    }

    if ($selectorResult.exit_code -ne 0) {
        throw "Selector worker failed. $($selectorResult.output)"
    }

    $selectorSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\provider_snapshot_import_candidate_selector") -Filter "provider_snapshot_import_candidate_selection_summary_*.json"
    $selectorSummary = Read-JsonFile -Path $(if ($selectorSummaryFile) { $selectorSummaryFile.FullName } else { "" })

    $candidateFound = Get-Bool -Object $selectorSummary -Name "candidate_found" -Default $false
    $selectedLane = Get-Text -Object $selectorSummary -Name "selected_lane" -Default "none"
    $nextWorker = Get-Text -Object $selectorSummary -Name "next_worker" -Default "none"
    $selectorDisposition = Get-Text -Object $selectorSummary -Name "selector_disposition" -Default "unknown"

    $finalDisposition = "noop_ready"
    $dbWrites = $false
    $actualWriteCount = 0
    $wouldWriteCount = 0
    $applyGateSummaryFile = ""

    if (-not $candidateFound) {
        $finalDisposition = "noop_ready"
    }
    elseif ($selectedLane -eq "vod_streams" -and $nextWorker -eq "apply_vod_streams_delta_limited.ps1") {
        $applyPath = Join-Path $PSScriptRoot "apply_vod_streams_delta_limited.ps1"
        $applyArgs = @("-Environment", $Environment, "-Limit", ([string]$Limit), "-Quiet")
        if ($Apply) {
            $applyArgs += "-Apply"
        }

        $applyResult = Invoke-Worker -ScriptPath $applyPath -Arguments $applyArgs
        $steps += [pscustomobject][ordered]@{
            step_order = 2
            step_name = "apply_vod_streams_delta_limited"
            status = $(if ($applyResult.exit_code -eq 0) { "pass" } else { "fail" })
            exit_code = $applyResult.exit_code
            duration_ms = $applyResult.duration_ms
        }

        if ($applyResult.exit_code -ne 0) {
            throw "VOD apply gate failed. $($applyResult.output)"
        }

        $applyGateSummary = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_streams_delta_limited_apply") -Filter "vod_streams_delta_limited_apply_summary_*.json"
        if ($applyGateSummary) {
            $applyGateSummaryFile = $applyGateSummary.FullName
            $applySummary = Read-JsonFile -Path $applyGateSummary.FullName
            $finalDisposition = Get-Text -Object $applySummary -Name "disposition" -Default "unknown"
            $dbWrites = Get-Bool -Object $applySummary -Name "db_writes" -Default $false
            $actualWriteCount = Get-IntValue -Object $applySummary -Name "actual_write_count" -Default 0
            $wouldWriteCount = Get-IntValue -Object $applySummary -Name "would_write_count" -Default 0
        }
        else {
            $finalDisposition = "apply_gate_summary_missing"
        }
    }
    else {
        $finalDisposition = "candidate_selected_for_unimplemented_lane"
    }

    $status = "pass"
    if ($finalDisposition -match "fail|missing|unimplemented") {
        $status = "warning"
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $reportCsv = Join-Path $OutputRoot "provider_snapshot_import_decision_gate_$timestamp.csv"
    $reportJson = Join-Path $OutputRoot "provider_snapshot_import_decision_gate_$timestamp.json"
    $summaryJson = Join-Path $OutputRoot "provider_snapshot_import_decision_gate_summary_$timestamp.json"
    $stepsCsv = Join-Path $OutputRoot "provider_snapshot_import_decision_gate_steps_$timestamp.csv"

    $steps | Export-Csv -Path $stepsCsv -NoTypeInformation

    $row = [pscustomobject][ordered]@{
        final_disposition = $finalDisposition
        dry_run = $dryRun
        apply_requested = [bool]$Apply
        candidate_found = $candidateFound
        selected_lane = $selectedLane
        selector_disposition = $selectorDisposition
        next_worker = $nextWorker
        would_write_count = $wouldWriteCount
        actual_write_count = $actualWriteCount
        db_writes = $dbWrites
        provider_calls = $false
        selector_summary_json = $(if ($selectorSummaryFile) { $selectorSummaryFile.FullName } else { "" })
        apply_gate_summary_json = $applyGateSummaryFile
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
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        candidate_found = $candidateFound
        selected_lane = $selectedLane
        selector_disposition = $selectorDisposition
        next_worker = $nextWorker
        would_write_count = $wouldWriteCount
        actual_write_count = $actualWriteCount
        selector_summary_json = $(if ($selectorSummaryFile) { $selectorSummaryFile.FullName } else { "" })
        apply_gate_summary_json = $applyGateSummaryFile
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
        Write-Output "OK: provider snapshot import decision gate completed. status=$status disposition=$finalDisposition selected_lane=$selectedLane dry_run=$dryRun db_writes=$dbWrites actual_write=$actualWriteCount provider_calls=False run_id=$RunId"
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

    Write-Error "FAILED: provider snapshot import decision gate failed. $message run_id=$RunId"
    exit 1
}
