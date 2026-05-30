<#
.SYNOPSIS
  Plan fix for VOD delta preview item-source routing.

.DESCRIPTION
  Read-only planner.

  Current discovered issue:
    VOD delta preview appears to consume source_dryrun_csv, which is a lane/control
    artifact, instead of source_snapshot, which contains item-level VOD stream data.

  This worker inspects:
    - latest VOD delta preview summary
    - latest source_dryrun_csv
    - latest source_snapshot
    - current import_vod_streams_delta_preview.ps1 source
    - fields available in the item-level snapshot

  It produces a fix plan for replacing/adjusting import_vod_streams_delta_preview.ps1
  so the preview maps item-level VOD records from source_snapshot.

  It does not call providers.
  It does not read DB.
  It does not write DB.
  It does not mutate snapshots.
  It does not modify source files.

.CONTRACT-MARKERS
  Write-JobLog
  Emit-Signal
  Emit-Heartbeat
  Test-KillSwitch
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [int]$SampleRows = 10,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "plan_vod_delta_preview_item_source_fix"
$Component = "vod_delta_preview_item_source_fix"
$DatabaseTarget = "none"
$SourceName = "vod_streams_delta_import_preview"
$KillSwitchName = "ENABLE_VOD_DELTA_PREVIEW_ITEM_SOURCE_FIX_PLANNER"

$CompletedSignal = "vod_delta_preview_item_source_fix_planned_completed"
$DispositionSignal = "vod_delta_preview_item_source_fix_disposition"
$SourceSnapshotReadableSignal = "vod_delta_preview_item_source_fix_source_snapshot_readable"
$ItemRowsAvailableSignal = "vod_delta_preview_item_source_fix_item_rows_available"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\vod_delta_preview_item_source_fix"
$LogRoot = Join-Path $RepoRoot "runtime\logs\vod_delta_preview_item_source_fix"

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
        event_ts = (Get-Date).ToUniversalTime().ToString("o")
        event_name = $EventName
        job_name = $WorkerName
        run_id = $RunId
        worker_name = $WorkerName
        component = $Component
        environment = $Environment
        database_target = $DatabaseTarget
        source_name = $SourceName
        status = $Status
        attempt = 1
        error_code = $null
        error_message = $null
        data = $Data
    }

    $logPath = Join-Path $LogRoot "$WorkerName-$($StartedAt.ToUniversalTime().ToString('yyyyMMdd')).jsonl"
    Add-Content -Path $logPath -Value ($record | ConvertTo-Json -Depth 20 -Compress)
}

function Emit-LocalSignal {
    param([string]$SignalName, [object]$SignalValue, [object]$Payload = $null)

    # Contract marker: Emit-Signal
    Write-LocalJsonLog -EventName "signal_emitted" -Status "ok" -Data ([ordered]@{
        signal_name = $SignalName
        signal_value = $SignalValue
        payload = $Payload
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

function Get-JsonItems {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    try {
        $json = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        return @()
    }

    if ($json -is [System.Array]) {
        return @($json)
    }

    $candidateProperties = @("items", "data", "streams", "vod_streams", "result", "rows")
    foreach ($propertyName in $candidateProperties) {
        $property = $json.PSObject.Properties |
            Where-Object { $_.Name -ieq $propertyName } |
            Select-Object -First 1

        if ($null -ne $property -and $null -ne $property.Value) {
            return @($property.Value)
        }
    }

    return @($json)
}

function Get-Field {
    param([object]$Row, [string[]]$Names, [string]$Default = "")

    if ($null -eq $Row) { return $Default }

    foreach ($name in $Names) {
        $property = $Row.PSObject.Properties |
            Where-Object { $_.Name -ieq $name } |
            Select-Object -First 1

        if ($null -ne $property -and $null -ne $property.Value) {
            $value = [string]$property.Value
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value.Trim()
            }
        }
    }

    return $Default
}

function Get-SafeText {
    param([string]$Value, [int]$MaxLength = 240)

    if ($null -eq $Value) { return "" }
    $text = $Value.Trim()
    if ($text.Length -gt $MaxLength) { return $text.Substring(0, $MaxLength) }
    return $text
}

try {
    if ($SampleRows -lt 1) { $SampleRows = 10 }
    if ($SampleRows -gt 100) { $SampleRows = 100 }

    Write-LocalJsonLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        sample_rows = $SampleRows
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

    $previewSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_streams_delta_import_preview") -Filter "vod_streams_delta_import_preview_summary_*.json"
    if ($null -eq $previewSummaryFile) {
        throw "Latest VOD preview summary not found."
    }

    $previewSummary = Read-JsonFile -Path $previewSummaryFile.FullName
    $sourceDryrunCsv = Get-Text -Object $previewSummary -Name "source_dryrun_csv" -Default ""
    $sourceSnapshot = Get-Text -Object $previewSummary -Name "source_snapshot" -Default ""
    $currentOutputCsv = Get-Text -Object $previewSummary -Name "output_csv" -Default ""

    $sourceSnapshotReadable = (-not [string]::IsNullOrWhiteSpace($sourceSnapshot) -and (Test-Path -LiteralPath $sourceSnapshot))
    $sourceDryrunReadable = (-not [string]::IsNullOrWhiteSpace($sourceDryrunCsv) -and (Test-Path -LiteralPath $sourceDryrunCsv))

    $snapshotItems = @()
    if ($sourceSnapshotReadable) {
        $snapshotItems = @(Get-JsonItems -Path $sourceSnapshot)
    }

    $itemRowsAvailable = (@($snapshotItems).Count -gt 0)

    $sampleRows = @()
    foreach ($item in ($snapshotItems | Select-Object -First $SampleRows)) {
        $sampleRows += [pscustomobject][ordered]@{
            provider_stream_id = Get-Field -Row $item -Names @("provider_stream_id", "stream_id", "id")
            provider_category_id = Get-Field -Row $item -Names @("provider_category_id", "category_id")
            title = Get-Field -Row $item -Names @("title", "name", "title_raw", "stream_display_name")
            container_extension = Get-Field -Row $item -Names @("container_extension", "container", "extension")
            stream_icon = Get-Field -Row $item -Names @("stream_icon", "movie_image", "cover")
            added = Get-Field -Row $item -Names @("added", "added_at")
            rating = Get-Field -Row $item -Names @("rating", "rating_5based")
            db_reads = $false
            db_writes = $false
            provider_calls = $false
        }
    }

    $fieldAvailabilityRows = @()
    $fieldMap = [ordered]@{
        provider_stream_id = @("provider_stream_id", "stream_id", "id")
        provider_category_id = @("provider_category_id", "category_id")
        title = @("title", "name", "title_raw", "stream_display_name")
        container_extension = @("container_extension", "container", "extension")
        stream_icon = @("stream_icon", "movie_image", "cover")
        added = @("added", "added_at")
        rating = @("rating", "rating_5based")
        tmdb_id = @("tmdb_id", "tmdb")
        year = @("year", "release_year")
    }

    foreach ($fieldName in $fieldMap.Keys) {
        $present = 0
        $missing = 0

        foreach ($item in $snapshotItems) {
            $value = Get-Field -Row $item -Names $fieldMap[$fieldName]
            if ([string]::IsNullOrWhiteSpace($value)) {
                $missing++
            }
            else {
                $present++
            }
        }

        $fieldAvailabilityRows += [pscustomobject][ordered]@{
            field_name = $fieldName
            present_count = $present
            missing_count = $missing
            total_rows = @($snapshotItems).Count
            db_reads = $false
            db_writes = $false
            provider_calls = $false
        }
    }

    $workerPath = Join-Path $RepoRoot "tools\workers\import_vod_streams_delta_preview.ps1"
    $sourceInspectionRows = @()

    if (Test-Path -LiteralPath $workerPath) {
        $patterns = @(
            "source_dryrun_csv",
            "source_snapshot",
            "Import-Csv",
            "ConvertFrom-Json",
            "planned_import_count",
            "skipped_provider_noise_count",
            "provider_stream_id",
            "category_id",
            "container_extension"
        )

        $matches = Select-String -LiteralPath $workerPath -Pattern $patterns -SimpleMatch -ErrorAction SilentlyContinue
        foreach ($match in @($matches)) {
            $lineText = Get-SafeText -Value ([string]$match.Line)
            $sourceInspectionRows += [pscustomobject][ordered]@{
                file_path = $match.Path
                line_number = $match.LineNumber
                line_text = $lineText
                db_reads = $false
                db_writes = $false
                provider_calls = $false
            }
        }
    }

    $blockers = @()
    $passedChecks = @()
    $recommendations = @()

    if ($sourceDryrunReadable) { $passedChecks += "source_dryrun_csv_readable" } else { $blockers += "source_dryrun_csv_missing" }
    if ($sourceSnapshotReadable) { $passedChecks += "source_snapshot_readable" } else { $blockers += "source_snapshot_missing" }
    if ($itemRowsAvailable) { $passedChecks += "source_snapshot_has_item_rows" } else { $blockers += "source_snapshot_has_no_item_rows" }

    $providerStreamPresent = ($fieldAvailabilityRows | Where-Object { $_.field_name -eq "provider_stream_id" -and $_.present_count -gt 0 } | Select-Object -First 1)
    $titlePresent = ($fieldAvailabilityRows | Where-Object { $_.field_name -eq "title" -and $_.present_count -gt 0 } | Select-Object -First 1)

    if ($providerStreamPresent) { $passedChecks += "provider_stream_id_available_in_snapshot" } else { $blockers += "provider_stream_id_not_available_in_snapshot" }
    if ($titlePresent) { $passedChecks += "title_available_in_snapshot" } else { $blockers += "title_not_available_in_snapshot" }

    $recommendations += "replace_vod_preview_item_source_from_source_dryrun_csv_to_source_snapshot"
    $recommendations += "parse_source_snapshot_json_items"
    $recommendations += "emit_one_preview_row_per_vod_item_with_provider_stream_id_provider_category_id_title_container_extension"
    $recommendations += "keep_db_writes_false_and_provider_calls_false"
    $recommendations += "preserve_summary_source_dryrun_csv_for_lineage_only_not_item_iteration"

    $status = "pass"
    $disposition = "vod_delta_preview_item_source_fix_planned"

    if (@($blockers).Count -gt 0) {
        $status = "warning"
        $disposition = "vod_delta_preview_item_source_fix_planned_with_blocks"
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $sampleCsv = Join-Path $OutputRoot "vod_delta_preview_item_source_fix_sample_rows_$timestamp.csv"
    $fieldCsv = Join-Path $OutputRoot "vod_delta_preview_item_source_fix_field_availability_$timestamp.csv"
    $sourceInspectionCsv = Join-Path $OutputRoot "vod_delta_preview_item_source_fix_source_inspection_$timestamp.csv"
    $planTxt = Join-Path $OutputRoot "vod_delta_preview_item_source_fix_plan_$timestamp.txt"
    $summaryJson = Join-Path $OutputRoot "vod_delta_preview_item_source_fix_summary_$timestamp.json"

    $sampleRows | Export-Csv -Path $sampleCsv -NoTypeInformation
    $fieldAvailabilityRows | Export-Csv -Path $fieldCsv -NoTypeInformation
    $sourceInspectionRows | Export-Csv -Path $sourceInspectionCsv -NoTypeInformation

    @"
VOD Delta Preview Item Source Fix Plan

Disposition:
  $disposition

Current problem:
  import_vod_streams_delta_preview is treating source_dryrun_csv as the item source.
  That CSV is a lane/control artifact, not item-level VOD stream data.

Correct item source:
  $sourceSnapshot

Lineage/control source:
  $sourceDryrunCsv

Current output CSV:
  $currentOutputCsv

Item rows available:
  $(@($snapshotItems).Count)

Required fix:
  1. Read source_snapshot JSON for VOD item rows.
  2. Keep source_dryrun_csv only as lineage/control context.
  3. Emit one preview row per item, bounded by Limit.
  4. Required row fields:
       mac_user_id
       provider_label
       provider_stream_id
       provider_category_id
       title_raw
       title_clean
       container_extension
       stream_icon
       added
       rating
       tmdb_id
       year
       row_disposition
  5. Set planned_import_count from item rows eligible for preview.
  6. Keep preview_only=true, dry_run=true, db_writes=false, provider_calls=false.
  7. Do not write DB.
  8. Do not call provider.

Recommendations:
  $($recommendations -join "`n  ")

Blockers:
  $($blockers -join "`n  ")
"@ | Set-Content -Path $planTxt -Encoding UTF8

    $summary = [ordered]@{
        status = $status
        disposition = $disposition
        source_snapshot = $sourceSnapshot
        source_snapshot_readable = $sourceSnapshotReadable
        source_dryrun_csv = $sourceDryrunCsv
        source_dryrun_readable = $sourceDryrunReadable
        current_output_csv = $currentOutputCsv
        item_rows_available = $itemRowsAvailable
        item_row_count = @($snapshotItems).Count
        blockers = $blockers
        passed_checks = $passedChecks
        recommendations = $recommendations
        db_reads = $false
        db_writes = $false
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        sample_csv = $sampleCsv
        field_availability_csv = $fieldCsv
        source_inspection_csv = $sourceInspectionCsv
        plan_txt = $planTxt
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $status -Payload $summary
    Emit-LocalSignal -SignalName $DispositionSignal -SignalValue $disposition -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $SourceSnapshotReadableSignal -SignalValue $sourceSnapshotReadable -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $ItemRowsAvailableSignal -SignalValue $itemRowsAvailable -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: VOD delta preview item-source fix planned. status=$status disposition=$disposition source_snapshot_readable=$sourceSnapshotReadable item_rows=$(@($snapshotItems).Count) db_reads=False db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: sample_csv=$sampleCsv field_csv=$fieldCsv source_inspection_csv=$sourceInspectionCsv plan_txt=$planTxt summary_json=$summaryJson"
        "`nFIELD AVAILABILITY:"
        $fieldAvailabilityRows | Format-Table -AutoSize
        "`nSAMPLE ITEMS:"
        $sampleRows | Format-Table -AutoSize
        "`nSOURCE INSPECTION:"
        $sourceInspectionRows | Select-Object -First 50 | Format-Table -AutoSize
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

    Write-Error "FAILED: VOD delta preview item-source fix planner failed. $message run_id=$RunId"
    exit 1
}
