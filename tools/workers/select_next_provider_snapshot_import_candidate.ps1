<#
.SYNOPSIS
  Select the next provider snapshot import candidate.

.DESCRIPTION
  Read-only selector.

  This worker reads the latest provider snapshot import readiness and execution plan
  outputs and selects the next import lane only if a lane has real import work.

  If all lanes are noop/provider-noise, it emits noop_ready and stops.

  No provider calls.
  No DB reads.
  No DB writes.
  No imports.

.CONTRACT-MARKERS
  Write-JobLog
  Emit-Signal
  Emit-Heartbeat
  Test-KillSwitch
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "select_next_provider_snapshot_import_candidate"
$Component = "provider_snapshot_import_candidate_selector"
$DatabaseTarget = "none"
$SourceName = "provider_snapshot_import_execution_plan"
$KillSwitchName = "ENABLE_PROVIDER_SNAPSHOT_IMPORT_CANDIDATE_SELECTOR"

$CompletedSignal = "provider_snapshot_import_candidate_selected_completed"
$CandidateFoundSignal = "provider_snapshot_import_candidate_found"
$CandidateLaneSignal = "provider_snapshot_import_candidate_lane"
$SelectorDispositionSignal = "provider_snapshot_import_candidate_selector_disposition"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\provider_snapshot_import_candidate_selector"
$LogRoot = Join-Path $RepoRoot "runtime\logs\provider_snapshot_import_candidate_selector"

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

function Get-IntValue {
    param([object]$Object, [string]$Name, [int]$Default = 0)

    $text = Get-Text -Object $Object -Name $Name -Default ""
    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }

    $value = 0
    if ([int]::TryParse($text, [ref]$value)) { return $value }

    return $Default
}

function Get-BoolText {
    param([object]$Row, [string]$Name)

    $text = Get-Text -Object $Row -Name $Name -Default ""
    if ([string]::IsNullOrWhiteSpace($text)) { return "False" }
    if ($text.Trim().ToLowerInvariant() -in @("true", "1", "yes")) { return "True" }
    return "False"
}

function Get-Priority {
    param([string]$LaneKey)

    switch ($LaneKey) {
        "vod_streams" { return 10 }
        "series_streams" { return 20 }
        "live_streams" { return 30 }
        "vod_categories" { return 40 }
        "series_categories" { return 50 }
        "live_categories" { return 60 }
        default { return 999 }
    }
}

try {
    Write-LocalJsonLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        preview_only = $true
        db_writes = $false
        provider_calls = $false
    })

    Emit-LocalHeartbeat -Status "running"

    if (-not (Test-WorkerKillSwitch)) {
        $summary = [ordered]@{
            status = "disabled"
            preview_only = $true
            db_writes = $false
            provider_calls = $false
            run_id = $RunId
        }

        Emit-LocalSignal -SignalName $CompletedSignal -SignalValue "disabled" -Payload $summary
        Write-LocalJsonLog -EventName "job_completed" -Status "disabled" -Data $summary
        Write-Output "SKIPPED: $KillSwitchName is disabled. run_id=$RunId"
        exit 0
    }

    $readinessSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\provider_snapshot_import_readiness") -Filter "provider_snapshot_import_readiness_summary_*.json"
    $executionPlanSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\provider_snapshot_import_execution_plan") -Filter "provider_snapshot_import_execution_plan_summary_*.json"

    if ($null -eq $readinessSummaryFile) {
        throw "Latest provider snapshot import readiness summary not found."
    }

    if ($null -eq $executionPlanSummaryFile) {
        throw "Latest provider snapshot import execution plan summary not found."
    }

    $readinessSummary = Read-JsonFile -Path $readinessSummaryFile.FullName
    $executionSummary = Read-JsonFile -Path $executionPlanSummaryFile.FullName

    $planCsv = Get-Text -Object $executionSummary -Name "plan_csv" -Default ""
    if ([string]::IsNullOrWhiteSpace($planCsv) -or -not (Test-Path -LiteralPath $planCsv)) {
        throw "Execution plan CSV not found from summary: $planCsv"
    }

    $planRows = @(Import-Csv -LiteralPath $planCsv)

    $candidateRows = @()

    foreach ($row in $planRows) {
        $action = (Get-Text -Object $row -Name "action" -Default "").ToLowerInvariant()
        $wouldWriteDb = Get-BoolText -Row $row -Name "would_write_db"
        $laneKey = Get-Text -Object $row -Name "lane_key" -Default "unknown"
        $sourceRows = Get-IntValue -Object $row -Name "source_rows" -Default 0

        if ($action -match "import|apply|write" -or $wouldWriteDb -eq "True") {
            $candidateRows += [pscustomobject][ordered]@{
                lane_key = $laneKey
                action = $action
                reason = Get-Text -Object $row -Name "reason"
                source_rows = $sourceRows
                would_call_provider = Get-BoolText -Row $row -Name "would_call_provider"
                would_write_db = $wouldWriteDb
                priority = Get-Priority -LaneKey $laneKey
            }
        }
    }

    $selected = $candidateRows |
        Sort-Object priority, lane_key |
        Select-Object -First 1

    $candidateFound = $false
    $selectedLane = "none"
    $selectorDisposition = "noop_ready"
    $next_worker = "none"
    $reason = "no_import_needed"

    if ($null -ne $selected) {
        $candidateFound = $true
        $selectedLane = $selected.lane_key
        $selectorDisposition = "candidate_selected"
        $reason = $selected.reason

        switch ($selectedLane) {
            "vod_streams" { $next_worker = "apply_vod_streams_delta_limited.ps1" }
            default { $next_worker = "plan_lane_specific_apply_contract.ps1" }
        }
    }
    else {
        $selectorDisposition = Get-Text -Object $executionSummary -Name "execution_disposition" -Default "noop_ready"
        if ([string]::IsNullOrWhiteSpace($selectorDisposition)) {
            $selectorDisposition = "noop_ready"
        }

        $reason = "execution_plan_has_no_import_candidate"
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $selectionCsv = Join-Path $OutputRoot "provider_snapshot_import_candidate_selection_$timestamp.csv"
    $selectionJson = Join-Path $OutputRoot "provider_snapshot_import_candidate_selection_$timestamp.json"
    $summaryJson = Join-Path $OutputRoot "provider_snapshot_import_candidate_selection_summary_$timestamp.json"

    $selectionRow = [pscustomobject][ordered]@{
        candidate_found = $candidateFound
        selected_lane = $selectedLane
        selector_disposition = $selectorDisposition
        next_worker = $next_worker
        reason = $reason
        readiness_status = Get-Text -Object $readinessSummary -Name "status" -Default "unknown"
        readiness_disposition = Get-Text -Object $readinessSummary -Name "readiness_disposition" -Default "unknown"
        execution_status = Get-Text -Object $executionSummary -Name "status" -Default "unknown"
        execution_disposition = Get-Text -Object $executionSummary -Name "execution_disposition" -Default "unknown"
        planned_count = Get-IntValue -Object $executionSummary -Name "planned_count" -Default 0
        noop_count = Get-IntValue -Object $executionSummary -Name "noop_count" -Default 0
        blocked_count = Get-IntValue -Object $executionSummary -Name "blocked_count" -Default 0
        review_count = Get-IntValue -Object $executionSummary -Name "review_count" -Default 0
        db_writes = $false
        provider_calls = $false
    }

    $selectionRow | Export-Csv -Path $selectionCsv -NoTypeInformation
    $selectionRow | ConvertTo-Json -Depth 20 | Set-Content -Path $selectionJson -Encoding UTF8

    $summary = [ordered]@{
        status = "pass"
        preview_only = $true
        db_writes = $false
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        readiness_summary_json = $readinessSummaryFile.FullName
        execution_plan_summary_json = $executionPlanSummaryFile.FullName
        execution_plan_csv = $planCsv
        candidate_found = $candidateFound
        selected_lane = $selectedLane
        selector_disposition = $selectorDisposition
        next_worker = $next_worker
        reason = $reason
        selection_csv = $selectionCsv
        selection_json = $selectionJson
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue "pass" -Payload $summary
    Emit-LocalSignal -SignalName $CandidateFoundSignal -SignalValue $candidateFound -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $CandidateLaneSignal -SignalValue $selectedLane -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $SelectorDispositionSignal -SignalValue $selectorDisposition -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status "pass" -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: provider snapshot import candidate selected. status=pass candidate_found=$candidateFound selected_lane=$selectedLane disposition=$selectorDisposition next_worker=$next_worker db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: selection_csv=$selectionCsv selection_json=$selectionJson summary_json=$summaryJson"
        Import-Csv $selectionCsv | Format-List
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

    Write-Error "FAILED: provider snapshot import candidate selection failed. $message run_id=$RunId"
    exit 1
}
