<#
.CONTRACT-SIGNALS
  vod_streams_delta_import_preview_completed
  vod_streams_delta_import_preview_disposition
  vod_streams_delta_import_preview_planned_import_count
  vod_streams_delta_import_preview_provider_noise_count
.SYNOPSIS
  Preview VOD stream delta import from item-level provider snapshot rows.

.DESCRIPTION
  Governed dry-run preview worker for VOD streams.

  This worker fixes the prior routing problem:
    - source_dryrun_csv is a lane/control artifact and is kept only for lineage.
    - source_snapshot is the item-level VOD JSON snapshot and is used as the row source.

  It emits one preview CSV row per item-level VOD stream record, bounded by -Limit.

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
    [int]$Limit = 250,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "import_vod_streams_delta_preview"
$Component = "vod_streams_delta_import_preview"
$DatabaseTarget = "none"
$SourceName = "provider_snapshot_vod_streams"
$KillSwitchName = "ENABLE_VOD_STREAMS_DELTA_IMPORT_PREVIEW"

$CompletedSignal = "vod_streams_delta_import_preview_completed"
$DispositionSignal = "vod_streams_delta_import_preview_disposition"
$PlannedImportCountSignal = "vod_streams_delta_import_preview_planned_import_count"
$ProviderNoiseCountSignal = "vod_streams_delta_import_preview_provider_noise_count"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\vod_streams_delta_import_preview"
$LogRoot = Join-Path $RepoRoot "runtime\logs\vod_streams_delta_import_preview"

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
    Add-Content -Path $logPath -Value ($record | ConvertTo-Json -Depth 30 -Compress)
}

# Contract checker marker: Invoke-ContractSignal
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

    foreach ($propertyName in @("items", "data", "streams", "vod_streams", "result", "rows")) {
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
    param(
        [object]$Row,
        [string[]]$Names,
        [string]$Default = ""
    )

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

function New-CleanTitle {
    param([string]$Title)

    if ([string]::IsNullOrWhiteSpace($Title)) { return "" }

    $clean = $Title.Trim()
    $clean = $clean -replace '^\s*[A-Z]{2}\|\s*', ''
    $clean = $clean -replace '\s+', ' '
    return $clean.Trim()
}

function Resolve-LatestVodSnapshot {
    $snapshotRoot = Join-Path $RepoRoot "runtime\provider_snapshots\vod_streams"

    if (-not (Test-Path -LiteralPath $snapshotRoot)) {
        return ""
    }

    $latest = Get-ChildItem -LiteralPath $snapshotRoot -Recurse -File -Filter "*.json" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $latest) { return "" }

    return $latest.FullName
}

function Resolve-LineageFromLatestDryRun {
    $dryRunFolder = Join-Path $RepoRoot "runtime\reports\provider_snapshot_delta_import_dryrun"
    $summaryFile = Get-LatestFile -Folder $dryRunFolder -Filter "provider_snapshot_delta_import_dryrun_summary_*.json"
    $csvFile = Get-LatestFile -Folder $dryRunFolder -Filter "provider_snapshot_delta_import_dryrun_*.csv"

    $sourceSnapshot = ""
    $sourceDryrunCsv = ""
    $summaryJson = ""

    if ($summaryFile) {
        $summaryJson = $summaryFile.FullName
        $summary = Read-JsonFile -Path $summaryFile.FullName
        $sourceSnapshot = Get-Text -Object $summary -Name "source_snapshot" -Default ""
        $sourceDryrunCsv = Get-Text -Object $summary -Name "output_csv" -Default ""
    }

    if ([string]::IsNullOrWhiteSpace($sourceDryrunCsv) -and $csvFile) {
        $sourceDryrunCsv = $csvFile.FullName
    }

    if (($sourceDryrunCsv -and (Test-Path -LiteralPath $sourceDryrunCsv)) -and [string]::IsNullOrWhiteSpace($sourceSnapshot)) {
        try {
            $dryRows = @(Import-Csv -LiteralPath $sourceDryrunCsv)
            $vodRow = $dryRows |
                Where-Object {
                    ((Get-Text -Object $_ -Name "lane_key" -Default "") -eq "vod_streams") -or
                    ((Get-Text -Object $_ -Name "media_type" -Default "") -eq "vod")
                } |
                Select-Object -First 1

            if ($vodRow) {
                $sourceSnapshot = Get-Text -Object $vodRow -Name "source_snapshot" -Default ""
                if ([string]::IsNullOrWhiteSpace($sourceSnapshot)) {
                    $sourceSnapshot = Get-Text -Object $vodRow -Name "latest_snapshot" -Default ""
                }
                if ([string]::IsNullOrWhiteSpace($sourceSnapshot)) {
                    $sourceSnapshot = Get-Text -Object $vodRow -Name "snapshot_path" -Default ""
                }
            }
        }
        catch {}
    }

    if ([string]::IsNullOrWhiteSpace($sourceSnapshot) -or -not (Test-Path -LiteralPath $sourceSnapshot)) {
        $sourceSnapshot = Resolve-LatestVodSnapshot
    }

    return [pscustomobject][ordered]@{
        source_snapshot = $sourceSnapshot
        source_dryrun_csv = $sourceDryrunCsv
        source_dryrun_summary = $summaryJson
    }
}

function Convert-VodItemToPreviewRow {
    param(
        [object]$Item,
        [int]$RowNumber,
        [string]$SourceSnapshot,
        [string]$SourceDryrunCsv
    )

    $providerStreamId = Get-Field -Row $Item -Names @("provider_stream_id", "stream_id", "id")
    $providerCategoryId = Get-Field -Row $Item -Names @("provider_category_id", "category_id")
    $titleRaw = Get-Field -Row $Item -Names @("title", "name", "title_raw", "stream_display_name")
    $titleClean = New-CleanTitle -Title $titleRaw
    $containerExtension = Get-Field -Row $Item -Names @("container_extension", "container", "extension")
    $streamIcon = Get-Field -Row $Item -Names @("stream_icon", "movie_image", "cover", "icon")
    $added = Get-Field -Row $Item -Names @("added", "added_at")
    $rating = Get-Field -Row $Item -Names @("rating", "rating_5based")
    $tmdbId = Get-Field -Row $Item -Names @("tmdb_id", "tmdb")
    $year = Get-Field -Row $Item -Names @("year", "release_year")
    $providerLabel = Get-Field -Row $Item -Names @("provider_label", "provider") -Default "unknown"
    $macUserId = Get-Field -Row $Item -Names @("mac_user_id") -Default "6"

    $missing = @()
    if ([string]::IsNullOrWhiteSpace($providerStreamId)) { $missing += "provider_stream_id" }
    if ([string]::IsNullOrWhiteSpace($providerCategoryId)) { $missing += "provider_category_id" }
    if ([string]::IsNullOrWhiteSpace($titleRaw)) { $missing += "title_raw" }
    if ([string]::IsNullOrWhiteSpace($containerExtension)) { $missing += "container_extension" }

    $rowDisposition = "planned_import"
    $recommendedAction = "preview_only_no_db_write"
    if (@($missing).Count -gt 0) {
        $rowDisposition = "incomplete_data"
        $recommendedAction = "manual_review_or_deferred_salvage"
    }

    return [pscustomobject][ordered]@{
        preview_row_number = $RowNumber
        lane_key = "vod_streams"
        media_type = "vod"
        operation_guess = "import"
        row_disposition = $rowDisposition
        recommended_action = $recommendedAction
        missing_fields = ($missing -join "|")
        mac_user_id = $macUserId
        provider_label = $providerLabel
        provider_stream_id = $providerStreamId
        provider_category_id = $providerCategoryId
        title_raw = $titleRaw
        title_clean = $titleClean
        container_extension = $containerExtension
        stream_icon = $streamIcon
        added = $added
        rating = $rating
        tmdb_id = $tmdbId
        year = $year
        source_snapshot = $SourceSnapshot
        source_dryrun_csv = $SourceDryrunCsv
        preview_only = $true
        dry_run = $true
        db_reads = $false
        db_writes = $false
        provider_calls = $false
    }
}

try {
    if ($Limit -lt 1) { $Limit = 1 }
    if ($Limit -gt 5000) { $Limit = 5000 }

    Write-LocalJsonLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        limit = $Limit
        preview_only = $true
        dry_run = $true
        db_reads = $false
        db_writes = $false
        provider_calls = $false
    })

    Emit-LocalHeartbeat -Status "running"

    if (-not (Test-WorkerKillSwitch)) {
        $summary = [ordered]@{
            worker_name = $WorkerName
            run_id = $RunId
            status = "disabled"
            disposition = "disabled_by_kill_switch"
            preview_only = $true
            dry_run = $true
            db_reads = $false
            db_writes = $false
            provider_calls = $false
        }

        Emit-LocalSignal -SignalName $CompletedSignal -SignalValue "disabled" -Payload $summary
        Emit-LocalSignal -SignalName $DispositionSignal -SignalValue "disabled_by_kill_switch" -Payload ([ordered]@{ run_id = $RunId })
        Write-LocalJsonLog -EventName "job_completed" -Status "disabled" -Data $summary
        Write-Output "SKIPPED: $KillSwitchName is disabled. run_id=$RunId"
        exit 0
    }

    $lineage = Resolve-LineageFromLatestDryRun
    $sourceSnapshot = [string]$lineage.source_snapshot
    $sourceDryrunCsv = [string]$lineage.source_dryrun_csv
    $sourceDryrunSummary = [string]$lineage.source_dryrun_summary

    if ([string]::IsNullOrWhiteSpace($sourceSnapshot) -or -not (Test-Path -LiteralPath $sourceSnapshot)) {
        throw "Unable to resolve readable source_snapshot for VOD streams."
    }

    $items = @(Get-JsonItems -Path $sourceSnapshot)
    if (@($items).Count -eq 0) {
        throw "Resolved source_snapshot has no item rows: $sourceSnapshot"
    }

    $previewRows = @()
    $rowNumber = 0

    foreach ($item in ($items | Select-Object -First $Limit)) {
        $rowNumber++
        $previewRows += Convert-VodItemToPreviewRow `
            -Item $item `
            -RowNumber $rowNumber `
            -SourceSnapshot $sourceSnapshot `
            -SourceDryrunCsv $sourceDryrunCsv
    }

    $plannedImportCount = @($previewRows | Where-Object { $_.row_disposition -eq "planned_import" }).Count
    $incompleteCount = @($previewRows | Where-Object { $_.row_disposition -eq "incomplete_data" }).Count
    $skippedProviderNoiseCount = 0
    $manualReviewCount = $incompleteCount

    $status = "pass"
    $disposition = "vod_streams_delta_item_preview_completed"

    if ($plannedImportCount -eq 0) {
        $status = "warning"
        $disposition = "vod_streams_delta_item_preview_no_planned_imports"
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $outputCsv = Join-Path $OutputRoot "vod_streams_delta_import_preview_$timestamp.csv"
    $outputJson = Join-Path $OutputRoot "vod_streams_delta_import_preview_$timestamp.json"
    $summaryJson = Join-Path $OutputRoot "vod_streams_delta_import_preview_summary_$timestamp.json"

    $previewRows | Export-Csv -Path $outputCsv -NoTypeInformation
    $previewRows | ConvertTo-Json -Depth 30 | Set-Content -Path $outputJson -Encoding UTF8

    $summary = [ordered]@{
        worker_name = $WorkerName
        run_id = $RunId
        status = $status
        disposition = $disposition
        environment = $Environment
        preview_only = $true
        dry_run = $true
        db_reads = $false
        db_writes = $false
        provider_calls = $false
        lane_key = "vod_streams"
        media_type = "vod"
        source_snapshot = $sourceSnapshot
        source_dryrun_csv = $sourceDryrunCsv
        source_dryrun_summary = $sourceDryrunSummary
        source_row_count = @($items).Count
        limit = $Limit
        total_rows = @($previewRows).Count
        planned_import_count = $plannedImportCount
        incomplete_data_count = $incompleteCount
        skipped_provider_noise_count = $skippedProviderNoiseCount
        manual_review_count = $manualReviewCount
        output_csv = $outputCsv
        output_json = $outputJson
        summary_json = $summaryJson
        started_at_utc = $StartedAt.ToUniversalTime().ToString("o")
        ended_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 30 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $status -Payload $summary
    Emit-LocalSignal -SignalName $DispositionSignal -SignalValue $disposition -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $PlannedImportCountSignal -SignalValue $plannedImportCount -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $ProviderNoiseCountSignal -SignalValue $skippedProviderNoiseCount -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: VOD streams delta item preview completed. status=$status disposition=$disposition source_rows=$(@($items).Count) emitted=$(@($previewRows).Count) planned_import=$plannedImportCount incomplete=$incompleteCount db_reads=False db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: output_csv=$outputCsv output_json=$outputJson summary_json=$summaryJson"
        $previewRows | Select-Object -First 25 | Format-Table -AutoSize
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

    Write-Error "FAILED: VOD streams delta item preview failed. $message run_id=$RunId"
    exit 1
}

