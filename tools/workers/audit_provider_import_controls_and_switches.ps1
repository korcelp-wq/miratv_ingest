<#
.SYNOPSIS
  Audit provider import controls, kill switches, and artifact routing.

.DESCRIPTION
  Read-only diagnostic worker.

  This worker checks whether the provider/VOD import path is effectively turned off
  or pointed at lane-summary artifacts instead of item-level provider snapshot rows.

  It audits:
    - ENABLE_* environment variables related to provider/import/vod/apply
    - latest summaries for preview_only, dry_run, db_writes, candidate_found
    - latest CSV artifacts and whether they are lane-summary/control rows
    - worker source references to preview_only, dry_run, db_writes, source_dryrun_csv,
      source_snapshot, planned_import_count, skipped_provider_noise_count
    - whether VOD delta preview is consuming a dry-run control CSV instead of item rows

  It does not call providers.
  It does not read DB.
  It does not write DB.
  It does not mutate snapshots.

.CONTRACT-MARKERS
  Write-JobLog
  Emit-Signal
  Emit-Heartbeat
  Test-KillSwitch
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [int]$MaxSourceMatches = 300,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "audit_provider_import_controls_and_switches"
$Component = "provider_import_controls_and_switches"
$DatabaseTarget = "none"
$SourceName = "runtime_reports_and_worker_sources"
$KillSwitchName = "ENABLE_PROVIDER_IMPORT_CONTROLS_AUDIT"

$CompletedSignal = "provider_import_controls_audit_completed"
$DispositionSignal = "provider_import_controls_audit_disposition"
$EffectiveOffSignal = "provider_import_controls_effective_off"
$WrongArtifactSignal = "provider_import_controls_wrong_artifact_suspected"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\provider_import_controls_audit"
$LogRoot = Join-Path $RepoRoot "runtime\logs\provider_import_controls_audit"

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
    param([object]$Object, [string]$Name)

    $text = Get-Text -Object $Object -Name $Name -Default ""
    if ([string]::IsNullOrWhiteSpace($text)) { return "" }

    return $text.Trim()
}

function Get-CsvHeaders {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    try {
        $first = Import-Csv -LiteralPath $Path | Select-Object -First 1
        if ($null -eq $first) { return @() }
        return @($first.PSObject.Properties.Name)
    }
    catch {
        return @()
    }
}

function Get-CsvRowCount {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return -1
    }

    try {
        return @(Import-Csv -LiteralPath $Path).Count
    }
    catch {
        return -1
    }
}

function Test-LaneSummaryHeaders {
    param([string[]]$Headers)

    $joined = ($Headers -join "|").ToLowerInvariant()

    if ($joined -match "lane_key" -and $joined -match "row_disposition" -and $joined -notmatch "provider_stream_id|stream_id|provider_category_id|title|name|container_extension") {
        return $true
    }

    return $false
}

function Test-ItemHeaders {
    param([string[]]$Headers)

    $joined = ($Headers -join "|").ToLowerInvariant()

    if ($joined -match "provider_stream_id|stream_id|provider_category_id|category_id|title|name|container_extension") {
        return $true
    }

    return $false
}

function Get-SafeLine {
    param([string]$Line)

    if ($null -eq $Line) { return "" }

    $safe = $Line.Trim()
    $safe = $safe -replace '(?i)(password|passwd|pwd|token|secret|key)\s*=\s*["''][^"'']+["'']', '$1=<redacted>'
    $safe = $safe -replace '(?i)(password|passwd|pwd|token|secret|key)\s*:\s*["''][^"'']+["'']', '$1:<redacted>'
    if ($safe.Length -gt 260) { return $safe.Substring(0, 260) }
    return $safe
}

try {
    if ($MaxSourceMatches -lt 1) { $MaxSourceMatches = 300 }
    if ($MaxSourceMatches -gt 2000) { $MaxSourceMatches = 2000 }

    Write-LocalJsonLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        max_source_matches = $MaxSourceMatches
        db_reads = $false
        db_writes = $false
        provider_calls = $false
    })

    Emit-LocalHeartbeat -Status "running"

    if (-not (Test-WorkerKillSwitch)) {
        $summary = [ordered]@{
            status = "disabled"
            disposition = "disabled_by_kill_switch"
            db_reads = $false
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

    $envNames = @(
        "ENABLE_PROVIDER_SNAPSHOT_SPINE",
        "ENABLE_PROVIDER_SNAPSHOT_DELTA",
        "ENABLE_PROVIDER_SNAPSHOT_IMPORT_PREVIEW",
        "ENABLE_PROVIDER_SNAPSHOT_IMPORT_DRYRUN",
        "ENABLE_VOD_STREAMS_DELTA_IMPORT_PREVIEW",
        "ENABLE_VOD_STREAMS_DELTA_LIMITED_APPLY",
        "ENABLE_PROVIDER_SNAPSHOT_IMPORT_DECISION_GATE",
        "ENABLE_PROVIDER_SNAPSHOT_GOVERNED_IMPORT_RUNNER",
        "ENABLE_PROVIDER_SNAPSHOT_GOVERNED_REFRESH_GATE",
        "ENABLE_VOD_DELTA_PREVIEW_DISPOSITION_AUDIT"
    )

    $envRows = @()
    foreach ($name in $envNames) {
        $value = [Environment]::GetEnvironmentVariable($name)
        $isSet = -not [string]::IsNullOrWhiteSpace($value)
        $normalized = if ($isSet) { $value.Trim().ToLowerInvariant() } else { "" }
        $disabled = ($normalized -in @("0", "false", "no", "off", "disabled"))

        $envRows += [pscustomobject][ordered]@{
            control_name = $name
            is_set = $isSet
            disabled = $disabled
            value_shape = $(if ($isSet) { "set_length_$($value.Length)" } else { "not_set" })
            value_printed = $false
            db_reads = $false
            db_writes = $false
            provider_calls = $false
        }
    }

    $reportDefs = @(
        @{ key = "provider_snapshot_delta_import_dryrun"; folder = "runtime\reports\provider_snapshot_delta_import_dryrun"; summary = "provider_snapshot_delta_import_dryrun_summary_*.json"; csv = "provider_snapshot_delta_import_dryrun_*.csv" },
        @{ key = "vod_streams_delta_import_preview"; folder = "runtime\reports\vod_streams_delta_import_preview"; summary = "vod_streams_delta_import_preview_summary_*.json"; csv = "vod_streams_delta_import_preview_*.csv" },
        @{ key = "provider_snapshot_import_execution_plan"; folder = "runtime\reports\provider_snapshot_import_execution_plan"; summary = "provider_snapshot_import_execution_plan_summary_*.json"; csv = "provider_snapshot_import_execution_plan_*.csv" },
        @{ key = "provider_snapshot_import_candidate_selector"; folder = "runtime\reports\provider_snapshot_import_candidate_selector"; summary = "provider_snapshot_import_candidate_selection_summary_*.json"; csv = "provider_snapshot_import_candidate_selection_*.csv" },
        @{ key = "provider_snapshot_import_decision_gate"; folder = "runtime\reports\provider_snapshot_import_decision_gate"; summary = "provider_snapshot_import_decision_gate_summary_*.json"; csv = "provider_snapshot_import_decision_gate_*.csv" },
        @{ key = "provider_snapshot_governed_import_runner"; folder = "runtime\reports\provider_snapshot_governed_import_runner"; summary = "provider_snapshot_governed_import_runner_summary_*.json"; csv = "provider_snapshot_governed_import_runner_*.csv" }
    )

    $artifactRows = @()
    $wrongArtifactSuspected = $false
    $effectiveOff = $false

    foreach ($def in $reportDefs) {
        $folder = Join-Path $RepoRoot $def.folder
        $summaryFile = Get-LatestFile -Folder $folder -Filter $def.summary
        $csvFile = Get-LatestFile -Folder $folder -Filter $def.csv

        $summary = $null
        if ($summaryFile) {
            $summary = Read-JsonFile -Path $summaryFile.FullName
        }

        $headers = @()
        $csvRowCount = -1
        $isLaneSummary = $false
        $isItemArtifact = $false

        if ($csvFile) {
            $headers = Get-CsvHeaders -Path $csvFile.FullName
            $csvRowCount = Get-CsvRowCount -Path $csvFile.FullName
            $isLaneSummary = Test-LaneSummaryHeaders -Headers $headers
            $isItemArtifact = Test-ItemHeaders -Headers $headers
        }

        $previewOnly = Get-BoolText -Object $summary -Name "preview_only"
        $dryRun = Get-BoolText -Object $summary -Name "dry_run"
        $dbWrites = Get-BoolText -Object $summary -Name "db_writes"
        $candidateFound = Get-BoolText -Object $summary -Name "candidate_found"
        $plannedImportCount = Get-IntValue -Object $summary -Name "planned_import_count" -Default 0
        $skippedProviderNoiseCount = Get-IntValue -Object $summary -Name "skipped_provider_noise_count" -Default 0
        $sourceDryrunCsv = Get-Text -Object $summary -Name "source_dryrun_csv" -Default ""
        $sourceSnapshot = Get-Text -Object $summary -Name "source_snapshot" -Default ""
        $disposition = Get-Text -Object $summary -Name "disposition" -Default ""
        if ([string]::IsNullOrWhiteSpace($disposition)) {
            $disposition = Get-Text -Object $summary -Name "selector_disposition" -Default ""
        }

        if ($def.key -eq "vod_streams_delta_import_preview" -and $isLaneSummary) {
            $wrongArtifactSuspected = $true
        }

        if ($def.key -match "preview|dryrun|execution_plan|candidate_selector" -and $plannedImportCount -eq 0 -and $csvRowCount -gt 0 -and $isLaneSummary) {
            $wrongArtifactSuspected = $true
        }

        $artifactRows += [pscustomobject][ordered]@{
            report_key = $def.key
            latest_summary = $(if ($summaryFile) { $summaryFile.FullName } else { "" })
            latest_csv = $(if ($csvFile) { $csvFile.FullName } else { "" })
            csv_row_count = $csvRowCount
            is_lane_summary_artifact = $isLaneSummary
            is_item_artifact = $isItemArtifact
            preview_only = $previewOnly
            dry_run = $dryRun
            db_writes = $dbWrites
            candidate_found = $candidateFound
            planned_import_count = $plannedImportCount
            skipped_provider_noise_count = $skippedProviderNoiseCount
            source_dryrun_csv = $sourceDryrunCsv
            source_snapshot = $sourceSnapshot
            disposition = $disposition
            headers = ($headers -join "|")
            db_reads = $false
            db_writes_report = $false
            provider_calls = $false
        }
    }

    $disabledControls = @($envRows | Where-Object { $_.disabled -eq $true }).Count
    if ($disabledControls -gt 0) {
        $effectiveOff = $true
    }

    $sourceRows = @()
    $sourcePatterns = @(
        "preview_only",
        "dry_run",
        "db_writes",
        "source_dryrun_csv",
        "source_snapshot",
        "planned_import_count",
        "skipped_provider_noise_count",
        "provider_noise",
        "row_disposition",
        "execution_plan_has_no_import_candidate",
        "candidate_found"
    )

    $workerFiles = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot "tools\workers") -Recurse -File -Filter "*.ps1" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch "\\runtime\\" })

    foreach ($file in $workerFiles) {
        if (@($sourceRows).Count -ge $MaxSourceMatches) { break }

        try {
            $matches = Select-String -LiteralPath $file.FullName -Pattern $sourcePatterns -SimpleMatch -ErrorAction SilentlyContinue
        }
        catch {
            continue
        }

        foreach ($match in @($matches)) {
            if (@($sourceRows).Count -ge $MaxSourceMatches) { break }

            $sourceRows += [pscustomobject][ordered]@{
                file_path = $match.Path
                line_number = $match.LineNumber
                line_text = Get-SafeLine -Line $match.Line
                matched_pattern = ($sourcePatterns | Where-Object { $match.Line -like "*$_*" } | Select-Object -First 1)
                db_reads = $false
                db_writes = $false
                provider_calls = $false
            }
        }
    }

    $recommendations = @()

    if ($wrongArtifactSuspected) {
        $recommendations += "vod_import_preview_appears_to_consume_lane_summary_control_artifact_not_item_snapshot_rows"
    }

    if ($effectiveOff) {
        $recommendations += "one_or_more_enable_controls_are_explicitly_disabled"
    }

    $vodPreviewArtifact = $artifactRows | Where-Object { $_.report_key -eq "vod_streams_delta_import_preview" } | Select-Object -First 1
    if ($vodPreviewArtifact -and -not [string]::IsNullOrWhiteSpace($vodPreviewArtifact.source_dryrun_csv)) {
        $recommendations += "vod_preview_source_is_source_dryrun_csv_check_if_this_should_be_source_snapshot"
    }

    if ($vodPreviewArtifact -and -not [string]::IsNullOrWhiteSpace($vodPreviewArtifact.source_snapshot)) {
        $recommendations += "vod_preview_has_source_snapshot_available_use_for_item_level_mapping"
    }

    if (@($recommendations).Count -eq 0) {
        $recommendations += "manual_review_required"
    }

    $status = "pass"
    $disposition = "provider_import_controls_audited"

    if ($wrongArtifactSuspected -or $effectiveOff) {
        $status = "warning"
        $disposition = "provider_import_controls_need_adjustment"
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $envCsv = Join-Path $OutputRoot "provider_import_controls_env_$timestamp.csv"
    $artifactCsv = Join-Path $OutputRoot "provider_import_controls_artifacts_$timestamp.csv"
    $sourceCsv = Join-Path $OutputRoot "provider_import_controls_source_refs_$timestamp.csv"
    $summaryJson = Join-Path $OutputRoot "provider_import_controls_summary_$timestamp.json"
    $diagnosisTxt = Join-Path $OutputRoot "provider_import_controls_diagnosis_$timestamp.txt"

    $envRows | Export-Csv -Path $envCsv -NoTypeInformation
    $artifactRows | Export-Csv -Path $artifactCsv -NoTypeInformation
    $sourceRows | Export-Csv -Path $sourceCsv -NoTypeInformation

    @"
Provider Import Controls Audit

Disposition:
  $disposition

Effective off:
  $effectiveOff

Wrong artifact suspected:
  $wrongArtifactSuspected

Disabled controls:
  $disabledControls

Recommendations:
  $($recommendations -join "`n  ")

No DB reads.
No DB writes.
No provider calls.
"@ | Set-Content -Path $diagnosisTxt -Encoding UTF8

    $summary = [ordered]@{
        status = $status
        disposition = $disposition
        effective_off = $effectiveOff
        wrong_artifact_suspected = $wrongArtifactSuspected
        disabled_control_count = $disabledControls
        recommendations = $recommendations
        db_reads = $false
        db_writes = $false
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        env_csv = $envCsv
        artifact_csv = $artifactCsv
        source_refs_csv = $sourceCsv
        diagnosis_txt = $diagnosisTxt
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $status -Payload $summary
    Emit-LocalSignal -SignalName $DispositionSignal -SignalValue $disposition -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $EffectiveOffSignal -SignalValue $effectiveOff -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $WrongArtifactSignal -SignalValue $wrongArtifactSuspected -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: Provider import controls audited. status=$status disposition=$disposition effective_off=$effectiveOff wrong_artifact_suspected=$wrongArtifactSuspected disabled_controls=$disabledControls db_reads=False db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: env_csv=$envCsv artifact_csv=$artifactCsv source_refs_csv=$sourceCsv diagnosis_txt=$diagnosisTxt summary_json=$summaryJson"
        "`nENV CONTROLS:"
        $envRows | Format-Table -AutoSize
        "`nARTIFACTS:"
        $artifactRows | Format-Table -AutoSize
        "`nRECOMMENDATIONS:"
        $recommendations | ForEach-Object { " - $_" }
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

    Write-Error "FAILED: Provider import controls audit failed. $message run_id=$RunId"
    exit 1
}
