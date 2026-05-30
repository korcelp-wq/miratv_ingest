<#
.SYNOPSIS
  Select the canonical VOD apply DB/write target candidate.

.DESCRIPTION
  Read-only selector.

  This worker consumes the latest VOD apply DB target inventory and selects the best
  candidate for future VOD apply work. It intentionally avoids choosing unrelated
  high-confidence rows such as series artwork endpoints or clean-search-name updates.

  Preference order:
    1. provider_pull_spine/import_vod_streams.ps1 manifest evidence
    2. existing VOD delta preview/row-preview worker evidence
    3. query/dog_opens/CVI evidence if clearly VOD apply-related
    4. server endpoint/direct SQL only if explicitly VOD streams apply/import-related

  No provider calls.
  No DB reads.
  No DB writes.
  No real snapshot mutation.

.CONTRACT-MARKERS
  Write-JobLog
  Emit-Signal
  Emit-Heartbeat
  Test-KillSwitch
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [string]$InventoryCsv = "",
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "select_vod_apply_db_target_candidate"
$Component = "vod_apply_db_target_selector"
$DatabaseTarget = "xpdgxfsp_content"
$SourceName = "vod_apply_db_target_inventory"
$KillSwitchName = "ENABLE_VOD_APPLY_DB_TARGET_SELECTOR"

$CompletedSignal = "vod_apply_db_target_selector_completed"
$SelectedTypeSignal = "vod_apply_db_target_selector_selected_type"
$ConfidenceSignal = "vod_apply_db_target_selector_confidence"
$ReviewRequiredSignal = "vod_apply_db_target_selector_review_required"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\vod_apply_db_target_selector"
$LogRoot = Join-Path $RepoRoot "runtime\logs\vod_apply_db_target_selector"

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

function Get-LatestInventoryCsv {
    if (-not [string]::IsNullOrWhiteSpace($InventoryCsv)) {
        if (-not (Test-Path -LiteralPath $InventoryCsv)) {
            throw "Inventory CSV not found: $InventoryCsv"
        }
        return (Resolve-Path -LiteralPath $InventoryCsv).Path
    }

    $summaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_apply_db_target_inventory") -Filter "vod_apply_db_target_inventory_summary_*.json"
    if ($summaryFile) {
        $summary = Read-JsonFile -Path $summaryFile.FullName
        $csv = ""
        if ($summary -and $summary.PSObject.Properties["report_csv"]) {
            $csv = [string]$summary.report_csv
        }
        if (-not [string]::IsNullOrWhiteSpace($csv) -and (Test-Path -LiteralPath $csv)) {
            return (Resolve-Path -LiteralPath $csv).Path
        }
    }

    $latest = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_apply_db_target_inventory") -Filter "vod_apply_db_target_inventory_*.csv"
    if ($null -eq $latest) {
        throw "No VOD apply DB target inventory CSV found. Run inventory_vod_apply_db_targets.ps1 first."
    }

    return $latest.FullName
}

function Get-Field {
    param([object]$Row, [string]$Name, [string]$Default = "")

    if ($null -eq $Row) { return $Default }

    $property = $Row.PSObject.Properties |
        Where-Object { $_.Name -ieq $Name } |
        Select-Object -First 1

    if ($null -eq $property -or $null -eq $property.Value) { return $Default }

    return [string]$property.Value
}

function Get-Score {
    param([object]$Row)

    $file = (Get-Field -Row $Row -Name "file_path").ToLowerInvariant()
    $line = (Get-Field -Row $Row -Name "line_text").ToLowerInvariant()
    $kind = (Get-Field -Row $Row -Name "match_kind").ToLowerInvariant()
    $route = (Get-Field -Row $Row -Name "route_guess").ToLowerInvariant()

    $score = 0
    $reasons = @()

    if ($line -match "import_vod_streams\.ps1" -or $file -match "import_vod_streams") {
        $score += 80
        $reasons += "explicit_import_vod_streams"
    }

    if ($file -match "master_control_ingest_manifest") {
        $score += 60
        $reasons += "manifest_evidence"
    }

    if ($file -match "import_vod_streams_delta_preview|import_vod_streams_delta_row_preview|apply_vod_streams_delta_limited") {
        $score += 55
        $reasons += "governed_vod_delta_worker_evidence"
    }

    if ($line -match "vod_streams" -or $kind -match "vod_streams_reference") {
        $score += 25
        $reasons += "vod_streams_reference"
    }

    if ($line -match "provider_stream_id|stream_id") {
        $score += 15
        $reasons += "provider_stream_id_reference"
    }

    if ($line -match "category_id|container_extension|movie_image|stream_icon") {
        $score += 10
        $reasons += "vod_field_reference"
    }

    if ($route -match "dog_opens|cvi|query") {
        $score += 20
        $reasons += "query_or_dog_candidate"
    }

    if ($route -match "server_endpoint|direct_sql") {
        $score += 10
        $reasons += "write_path_candidate"
    }

    if ($file -match "series_artwork|content_artwork_candidates|normalize_media_search_names|inventory_vod_apply_db_targets\.ps1") {
        $score -= 100
        $reasons += "unrelated_or_self_inventory"
    }

    if ($line -match "series SET|live_channels|content_artwork_candidates|clean_search_name") {
        $score -= 80
        $reasons += "not_vod_apply_target"
    }

    if ($score -lt 0) { $score = 0 }

    return [pscustomobject][ordered]@{
        score = $score
        reasons = ($reasons -join "|")
    }
}

function Get-SelectedType {
    param([object]$Row)

    $file = (Get-Field -Row $Row -Name "file_path").ToLowerInvariant()
    $line = (Get-Field -Row $Row -Name "line_text").ToLowerInvariant()
    $route = (Get-Field -Row $Row -Name "route_guess").ToLowerInvariant()

    if ($file -match "master_control_ingest_manifest" -and $line -match "import_vod_streams\.ps1") {
        return "manifest_import_route"
    }

    if ($file -match "import_vod_streams_delta_preview|import_vod_streams_delta_row_preview|apply_vod_streams_delta_limited") {
        return "governed_delta_worker_route"
    }

    if ($route -match "dog_opens|cvi|query") {
        return "query_or_dog_opens_candidate"
    }

    if ($route -match "server_endpoint") {
        return "server_endpoint_candidate"
    }

    if ($route -match "direct_sql") {
        return "direct_sql_candidate"
    }

    return "manual_review"
}

try {
    Write-LocalJsonLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        db_writes = $false
        provider_calls = $false
    })

    Emit-LocalHeartbeat -Status "running"

    if (-not (Test-WorkerKillSwitch)) {
        $summary = [ordered]@{
            status = "disabled"
            disposition = "disabled_by_kill_switch"
            db_writes = $false
            provider_calls = $false
            run_id = $RunId
        }

        Emit-LocalSignal -SignalName $CompletedSignal -SignalValue "disabled" -Payload $summary
        Write-LocalJsonLog -EventName "job_completed" -Status "disabled" -Data $summary
        Write-Output "SKIPPED: $KillSwitchName is disabled. run_id=$RunId"
        exit 0
    }

    $inventoryPath = Get-LatestInventoryCsv
    $inventoryRows = @(Import-Csv -LiteralPath $inventoryPath)

    $scoredRows = @()
    foreach ($row in $inventoryRows) {
        $scoreObj = Get-Score -Row $row
        $selectedType = Get-SelectedType -Row $row

        $scoredRows += [pscustomobject][ordered]@{
            score = $scoreObj.score
            score_reasons = $scoreObj.reasons
            selected_type_guess = $selectedType
            original_confidence = Get-Field -Row $row -Name "confidence"
            original_route_guess = Get-Field -Row $row -Name "route_guess"
            match_kind = Get-Field -Row $row -Name "match_kind"
            file_path = Get-Field -Row $row -Name "file_path"
            line_number = Get-Field -Row $row -Name "line_number"
            line_text = Get-Field -Row $row -Name "line_text"
            db_writes = $false
            provider_calls = $false
        }
    }

    $ranked = @($scoredRows | Sort-Object @{Expression = "score"; Descending = $true}, file_path, line_number)
    $selected = $ranked | Select-Object -First 1

    $selectionStatus = "pass"
    $disposition = "selected"
    $selectedType = "none"
    $selectedConfidence = "none"
    $reviewRequired = $true

    if ($null -eq $selected -or [int]$selected.score -le 0) {
        $selectionStatus = "warning"
        $disposition = "no_candidate_selected"
    }
    else {
        $selectedType = [string]$selected.selected_type_guess
        if ([int]$selected.score -ge 120) {
            $selectedConfidence = "high"
            $reviewRequired = $false
        }
        elseif ([int]$selected.score -ge 80) {
            $selectedConfidence = "medium"
            $reviewRequired = $true
        }
        else {
            $selectedConfidence = "low"
            $reviewRequired = $true
        }

        if ($selectedType -eq "manifest_import_route") {
            $disposition = "selected_manifest_import_route"
            $reviewRequired = $true
        }
        elseif ($selectedType -eq "governed_delta_worker_route") {
            $disposition = "selected_governed_delta_worker_route"
        }
        else {
            $disposition = "selected_requires_manual_review"
            $reviewRequired = $true
        }
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $rankedCsv = Join-Path $OutputRoot "vod_apply_db_target_selector_ranked_$timestamp.csv"
    $selectionCsv = Join-Path $OutputRoot "vod_apply_db_target_selector_selection_$timestamp.csv"
    $selectionJson = Join-Path $OutputRoot "vod_apply_db_target_selector_selection_$timestamp.json"
    $summaryJson = Join-Path $OutputRoot "vod_apply_db_target_selector_summary_$timestamp.json"

    $ranked | Export-Csv -Path $rankedCsv -NoTypeInformation

    $selectionRow = [pscustomobject][ordered]@{
        disposition = $disposition
        selected_type = $selectedType
        selected_confidence = $selectedConfidence
        review_required = $reviewRequired
        score = $(if ($selected) { $selected.score } else { 0 })
        score_reasons = $(if ($selected) { $selected.score_reasons } else { "" })
        file_path = $(if ($selected) { $selected.file_path } else { "" })
        line_number = $(if ($selected) { $selected.line_number } else { "" })
        line_text = $(if ($selected) { $selected.line_text } else { "" })
        inventory_csv = $inventoryPath
        db_writes = $false
        provider_calls = $false
    }

    $selectionRow | Export-Csv -Path $selectionCsv -NoTypeInformation
    $selectionRow | ConvertTo-Json -Depth 20 | Set-Content -Path $selectionJson -Encoding UTF8

    $summary = [ordered]@{
        status = $selectionStatus
        disposition = $disposition
        db_writes = $false
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        selected_type = $selectedType
        selected_confidence = $selectedConfidence
        review_required = $reviewRequired
        score = $selectionRow.score
        score_reasons = $selectionRow.score_reasons
        selected_file_path = $selectionRow.file_path
        selected_line_number = $selectionRow.line_number
        inventory_csv = $inventoryPath
        ranked_csv = $rankedCsv
        selection_csv = $selectionCsv
        selection_json = $selectionJson
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $selectionStatus -Payload $summary
    Emit-LocalSignal -SignalName $SelectedTypeSignal -SignalValue $selectedType -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $ConfidenceSignal -SignalValue $selectedConfidence -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $ReviewRequiredSignal -SignalValue $reviewRequired -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $selectionStatus -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: VOD apply DB target candidate selected. status=$selectionStatus disposition=$disposition selected_type=$selectedType confidence=$selectedConfidence review_required=$reviewRequired db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: selection_csv=$selectionCsv selection_json=$selectionJson ranked_csv=$rankedCsv summary_json=$summaryJson"
        Import-Csv $selectionCsv | Format-List
        "`nTOP RANKED:"
        Import-Csv $rankedCsv |
            Select-Object -First 20 score, selected_type_guess, score_reasons, original_route_guess, file_path, line_number, line_text |
            Format-Table -AutoSize
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

    Write-Error "FAILED: VOD apply DB target selector failed. $message run_id=$RunId"
    exit 1
}
