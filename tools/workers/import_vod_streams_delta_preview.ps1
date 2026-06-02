<#
.CONTRACT-SIGNALS
  provider_snapshot_vod_streams_import_preview_completed
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

  Master Control DB path:
    - writes direct DB logging rows to:
        xpdgxfsp_content.mc_vod_streams_delta_import_preview_summary
        xpdgxfsp_content.mc_vod_streams_delta_import_preview
    - keeps existing CSV/JSON outputs as debug/fallback artifacts.

  It does not call providers.
  It reads DB to exclude VOD rows already imported into xpdgxfsp_content.vod.
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

$CompletedSignal = "provider_snapshot_vod_streams_import_preview_completed"
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

$DbQueryModule = Join-Path $RepoRoot "tools\common\DbQuery.psm1"
if (-not (Test-Path -LiteralPath $DbQueryModule)) {
    throw "Required DB query module not found: $DbQueryModule"
}
Import-Module $DbQueryModule -Force


function Get-DurationMs {
    param([datetime]$Start)
    return [int][Math]::Round(((Get-Date) - $Start).TotalMilliseconds)
}


function ConvertTo-HashtableLocal {
    param([Parameter(Mandatory = $true)][object]$Object)

    $hash = @{}
    foreach ($property in $Object.PSObject.Properties) {
        $hash[$property.Name] = $property.Value
    }
    return $hash
}

function Get-FileMetaLocal {
    param(
        [string]$Path,
        [string]$Pattern
    )

    $sha = ""
    $lastWriteUtc = ""

    if (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path)) {
        try { $sha = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash } catch { $sha = "" }
        try { $lastWriteUtc = (Get-Item -LiteralPath $Path).LastWriteTimeUtc.ToString("o") } catch { $lastWriteUtc = "" }
    }

    if (Get-Command New-McSourceMeta -ErrorAction SilentlyContinue) {
        return New-McSourceMeta `
            -SourceFilePath $Path `
            -SourceFilePattern $Pattern `
            -SourceFileSha256 $sha `
            -SourceFileLastWriteUtc $lastWriteUtc
    }

    $sourceFileName = ""
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        try { $sourceFileName = Split-Path -Path $Path -Leaf } catch { $sourceFileName = "" }
    }

    return [ordered]@{
        source_file_path = $Path
        source_file_name = $sourceFileName
        source_file_pattern = $Pattern
        source_file_sha256 = $sha
        source_file_last_write_utc = $lastWriteUtc
    }
}

function Initialize-MasterControlDbLocal {
    param([string]$RepoRoot)

    $result = [ordered]@{
        available = $false
        error = ""
    }

    try {
        $mcDbModule = Join-Path $RepoRoot "tools\common\MasterControlDb.psm1"
        if (-not (Test-Path -LiteralPath $mcDbModule)) {
            throw "MasterControlDb module not found: $mcDbModule"
        }

        Import-Module $mcDbModule -Force -ErrorAction Stop

        $required = @(
            "Write-McVodStreamsDeltaImportPreviewSummary",
            "Write-McVodStreamsDeltaImportPreviewRow"
        )

        foreach ($commandName in $required) {
            if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
                throw "Required command missing: $commandName"
            }
        }

        $result.available = $true
    }
    catch {
        $result.available = $false
        $result.error = $_.Exception.Message
    }

    return [pscustomobject]$result
}

function Write-MasterControlVodPreviewLocal {
    param(
        [bool]$McDbAvailable,
        [object]$Summary,
        [object[]]$PreviewRows,
        [string]$OutputCsv,
        [string]$SummaryJson
    )

    $writeResult = [ordered]@{
        available = $McDbAvailable
        attempted = $false
        summary_written = $false
        detail_written_count = 0
        error = ""
    }

    if (-not $McDbAvailable) {
        return [pscustomobject]$writeResult
    }

    try {
        $writeResult.attempted = $true

        $summaryHash = ConvertTo-HashtableLocal -Object $Summary
        $summarySource = Get-FileMetaLocal `
            -Path $SummaryJson `
            -Pattern "vod_streams_delta_import_preview_summary_TIMESTAMP.json"

        Write-McVodStreamsDeltaImportPreviewSummary `
            -Summary $summaryHash `
            -SourceMeta $summarySource | Out-Null

        $writeResult.summary_written = $true

        $detailSource = Get-FileMetaLocal `
            -Path $OutputCsv `
            -Pattern "vod_streams_delta_import_preview_TIMESTAMP.csv"

        foreach ($row in $PreviewRows) {
            $rowHash = ConvertTo-HashtableLocal -Object $row

            Write-McVodStreamsDeltaImportPreviewRow `
                -PreviewRow $rowHash `
                -SourceMeta $detailSource | Out-Null

            $writeResult.detail_written_count++
        }
    }
    catch {
        $writeResult.error = $_.Exception.Message
    }

    return [pscustomobject]$writeResult
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

function Get-ProviderLabelFromSnapshotPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    $normalized = $Path -replace '/', '\'
    $parts = @($normalized -split '\\' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($parts[$i] -eq "vod_streams" -and ($i + 2) -lt $parts.Count) {
            $macPart = [string]$parts[$i + 1]
            $providerPart = [string]$parts[$i + 2]

            if ($macPart -match '^mac_\d+$' -and -not [string]::IsNullOrWhiteSpace($providerPart)) {
                return $providerPart
            }
        }
    }

    return ""
}

function ConvertTo-SqlLiteralLocal {
    param([string]$Value)

    if ($null -eq $Value) {
        return "NULL"
    }

    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function Get-ExistingVodProviderVodIdSet {
    param(
        [string]$ProviderLabel,
        [string[]]$ProviderVodIds
    )

    $set = @{}

    if ([string]::IsNullOrWhiteSpace($ProviderLabel)) {
        throw "Provider label is required before checking existing VOD rows."
    }

    $ids = @(
        $ProviderVodIds |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { [string]$_ } |
            Sort-Object -Unique
    )

    if (@($ids).Count -eq 0) {
        return $set
    }

    $providerSql = ConvertTo-SqlLiteralLocal -Value $ProviderLabel
    $chunkSize = 500

    for ($i = 0; $i -lt $ids.Count; $i += $chunkSize) {
        $end = [Math]::Min($i + $chunkSize - 1, $ids.Count - 1)
        $chunk = @($ids[$i..$end])
        $idList = ($chunk | ForEach-Object { ConvertTo-SqlLiteralLocal -Value $_ }) -join ","

        $sql = @"
SELECT provider_vod_id
FROM xpdgxfsp_content.vod
WHERE provider = $providerSql
  AND provider_vod_id IN ($idList);
"@

        $result = Invoke-DogOpenProc -DatabaseKey "content" -Sql $sql -TimeoutSec 120

        foreach ($row in @($result.rows)) {
            $existingId = Get-Text -Object $row -Name "provider_vod_id" -Default ""
            if (-not [string]::IsNullOrWhiteSpace($existingId)) {
                $set[$existingId] = $true
            }
        }
    }

    return $set
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
    $providerLabel = Get-Field -Row $Item -Names @("provider_label", "provider") -Default ""
    if ([string]::IsNullOrWhiteSpace($providerLabel) -or $providerLabel.Trim().ToLowerInvariant() -eq "unknown") {
        $providerLabel = Get-ProviderLabelFromSnapshotPath -Path $SourceSnapshot
    }
    if ([string]::IsNullOrWhiteSpace($providerLabel)) {
        $providerLabel = "unknown"
    }
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
        import_status = ""
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
        db_reads = $true
        db_writes = $false
        provider_calls = $false
    }
}

$mcDb = Initialize-MasterControlDbLocal -RepoRoot $RepoRoot

try {
    if ($Limit -lt 1) { $Limit = 1 }
    if ($Limit -gt 5000) { $Limit = 5000 }

    Write-LocalJsonLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        limit = $Limit
        preview_only = $true
        dry_run = $true
        db_reads = $true
        db_writes = $false
        provider_calls = $false
        mc_db_available = [bool]$mcDb.available
        mc_db_error = [string]$mcDb.error
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
            db_reads = $true
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

    $providerLabelFromSnapshot = Get-ProviderLabelFromSnapshotPath -Path $sourceSnapshot
    if ([string]::IsNullOrWhiteSpace($providerLabelFromSnapshot)) {
        $providerLabelFromSnapshot = "unknown"
    }

    $candidateProviderVodIds = @(
        foreach ($item in $items) {
            Get-Field -Row $item -Names @("provider_stream_id", "stream_id", "id")
        }
    )

    $existingVodIds = Get-ExistingVodProviderVodIdSet `
        -ProviderLabel $providerLabelFromSnapshot `
        -ProviderVodIds $candidateProviderVodIds

    $previewRows = @()
    $rowNumber = 0
    $skippedAlreadyImportedCount = 0

    foreach ($item in $items) {
        $candidateProviderStreamId = Get-Field -Row $item -Names @("provider_stream_id", "stream_id", "id")

        if (-not [string]::IsNullOrWhiteSpace($candidateProviderStreamId) -and $existingVodIds.ContainsKey($candidateProviderStreamId)) {
            $skippedAlreadyImportedCount++
            continue
        }

        $rowNumber++
        $previewRows += Convert-VodItemToPreviewRow `
            -Item $item `
            -RowNumber $rowNumber `
            -SourceSnapshot $sourceSnapshot `
            -SourceDryrunCsv $sourceDryrunCsv

        if (@($previewRows).Count -ge $Limit) {
            break
        }
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
        db_reads = $true
        db_writes = $false
        provider_calls = $false
        lane_key = "vod_streams"
        media_type = "vod"
        source_snapshot = $sourceSnapshot
        source_dryrun_csv = $sourceDryrunCsv
        source_dryrun_summary = $sourceDryrunSummary
        source_row_count = @($items).Count
        skipped_already_imported_count = $skippedAlreadyImportedCount
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

    $mcWrite = Write-MasterControlVodPreviewLocal `
        -McDbAvailable ([bool]$mcDb.available) `
        -Summary ([pscustomobject]$summary) `
        -PreviewRows @($previewRows) `
        -OutputCsv $outputCsv `
        -SummaryJson $summaryJson

    $summary["mc_db_available"] = [bool]$mcDb.available
    $summary["mc_db_attempted"] = [bool]$mcWrite.attempted
    $summary["mc_db_summary_written"] = [bool]$mcWrite.summary_written
    $summary["mc_db_detail_written_count"] = [int]$mcWrite.detail_written_count
    $summary["mc_db_error"] = [string]$mcWrite.error

    $summary | ConvertTo-Json -Depth 30 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $status -Payload $summary
    Emit-LocalSignal -SignalName $DispositionSignal -SignalValue $disposition -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $PlannedImportCountSignal -SignalValue $plannedImportCount -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $ProviderNoiseCountSignal -SignalValue $skippedProviderNoiseCount -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: VOD streams delta item preview completed. status=$status disposition=$disposition source_rows=$(@($items).Count) emitted=$(@($previewRows).Count) planned_import=$plannedImportCount incomplete=$incompleteCount db_reads=True db_writes=False provider_calls=False skipped_already_imported=$skippedAlreadyImportedCount mc_db_available=$($mcDb.available) mc_db_attempted=$($mcWrite.attempted) mc_db_summary_written=$($mcWrite.summary_written) mc_db_detail_written_count=$($mcWrite.detail_written_count) run_id=$RunId"
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
            mc_db_available = if ($null -ne $mcDb) { [bool]$mcDb.available } else { $false }
            mc_db_error = if ($null -ne $mcDb) { [string]$mcDb.error } else { "" }
        })
    }
    catch {}

    Write-Error "FAILED: VOD streams delta item preview failed. $message run_id=$RunId"
    exit 1
}





