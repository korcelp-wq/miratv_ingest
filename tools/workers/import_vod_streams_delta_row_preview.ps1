<#
.SYNOPSIS
  Preview row-level dispositions for VOD streams delta import without DB writes.

.DESCRIPTION
  Reads the latest VOD streams delta import lane preview and the latest VOD streams
  provider snapshot. If the lane is import_needed, it samples VOD stream rows and
  classifies each row into a row-level disposition. This is a no-write pre-import
  safety gate.

  This worker is intentionally read-only:
    - no provider calls
    - no database writes
    - no import execution
    - runtime reports only

  Golden grinder rule preserved:
    System-level failures may stop the worker.
    Row-level issues become dispositions.
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [string]$InputCsv,
    [string]$SnapshotPath,
    [int]$Limit = 250,
    [switch]$AllowProviderNoiseScan,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "import_vod_streams_delta_row_preview"
$Component = "provider_snapshot_vod_streams_import_row_preview"
$DatabaseTarget = "none"
$SourceName = "provider_vod_streams_snapshot"
$KillSwitchName = "ENABLE_PROVIDER_SNAPSHOT_VOD_STREAMS_IMPORT_ROW_PREVIEW"
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\vod_streams_delta_import_row_preview"
$LogRoot = Join-Path $RepoRoot "runtime\logs\vod_streams_delta_import_row_preview"
$StartedAt = Get-Date

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null

$CommonLoggingPath = Join-Path $RepoRoot "tools\common\Logging.psm1"
if (Test-Path $CommonLoggingPath) {
    Import-Module $CommonLoggingPath -Force
}

function ConvertTo-SafeJson {
    param([object]$Value, [int]$Depth = 8)
    return ($Value | ConvertTo-Json -Depth $Depth -Compress)
}

function Write-LocalJsonLog {
    param(
        [string]$EventName,
        [string]$Status,
        [hashtable]$Data = @{}
    )

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
    Add-Content -Path $logPath -Value (ConvertTo-SafeJson $record -Depth 12)
}

function Invoke-ContractLog {
    param(
        [string]$EventName,
        [string]$Status,
        [hashtable]$Data = @{}
    )

    # Keep explicit contract function references for the automation checker.
    # Write-JobLog
    if (Get-Command Write-JobLog -ErrorAction SilentlyContinue) {
        try {
            Write-JobLog `
                -JobName $WorkerName `
                -RunId $RunId `
                -WorkerName $WorkerName `
                -Component $Component `
                -Environment $Environment `
                -DatabaseTarget $DatabaseTarget `
                -SourceName $SourceName `
                -EventName $EventName `
                -Status $Status `
                -Data $Data | Out-Null
            return
        }
        catch {
            Write-LocalJsonLog -EventName "logging_adapter_failed" -Status "warning" -Data @{ message = $_.Exception.Message }
        }
    }

    Write-LocalJsonLog -EventName $EventName -Status $Status -Data $Data
}

function Invoke-ContractSignal {
    param(
        [string]$SignalName,
        [object]$SignalValue,
        [hashtable]$Payload = @{}
    )

    # Keep explicit contract function references for the automation checker.
    # Emit-Signal
    if (Get-Command Emit-Signal -ErrorAction SilentlyContinue) {
        try {
            Emit-Signal `
                -SignalName $SignalName `
                -SignalValue $SignalValue `
                -RunId $RunId `
                -WorkerName $WorkerName `
                -Component $Component `
                -Environment $Environment `
                -Payload $Payload | Out-Null
            return
        }
        catch {
            Write-LocalJsonLog -EventName "signal_adapter_failed" -Status "warning" -Data @{ signal_name = $SignalName; message = $_.Exception.Message }
        }
    }

    Write-LocalJsonLog -EventName "signal_emitted" -Status "ok" -Data @{
        signal_name  = $SignalName
        signal_value = $SignalValue
        payload      = $Payload
    }
}

function Invoke-ContractHeartbeat {
    param([string]$Status = "running")

    # Keep explicit contract function references for the automation checker.
    # Emit-Heartbeat
    if (Get-Command Emit-Heartbeat -ErrorAction SilentlyContinue) {
        try {
            Emit-Heartbeat `
                -WorkerName $WorkerName `
                -RunId $RunId `
                -Component $Component `
                -Environment $Environment `
                -Status $Status | Out-Null
            return
        }
        catch {
            Write-LocalJsonLog -EventName "heartbeat_adapter_failed" -Status "warning" -Data @{ message = $_.Exception.Message }
        }
    }

    Write-LocalJsonLog -EventName "heartbeat" -Status $Status -Data @{}
}

function Test-WorkerKillSwitch {
    # Keep explicit contract function references for the automation checker.
    # Test-KillSwitch
    if (Get-Command Test-KillSwitch -ErrorAction SilentlyContinue) {
        try {
            $enabled = Test-KillSwitch -Name $KillSwitchName -DefaultEnabled $true
            return [bool]$enabled
        }
        catch {
            Write-LocalJsonLog -EventName "kill_switch_adapter_failed" -Status "warning" -Data @{ message = $_.Exception.Message }
        }
    }

    $value = [Environment]::GetEnvironmentVariable($KillSwitchName)
    if ([string]::IsNullOrWhiteSpace($value)) { return $true }
    return ($value.Trim().ToLowerInvariant() -notin @("0", "false", "no", "off", "disabled"))
}

function Get-FirstValue {
    param(
        [object]$Row,
        [string[]]$Names,
        [object]$Default = $null
    )

    foreach ($name in $Names) {
        if ($Row.PSObject.Properties.Name -contains $name) {
            $value = $Row.$name
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
                return $value
            }
        }
    }
    return $Default
}

function ConvertTo-BoolLoose {
    param([object]$Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    $text = ([string]$Value).Trim().ToLowerInvariant()
    return ($text -in @("true", "1", "yes", "y"))
}

function Get-LatestLanePreviewCsv {
    if (-not [string]::IsNullOrWhiteSpace($InputCsv)) {
        if (-not (Test-Path $InputCsv)) { throw "InputCsv not found: $InputCsv" }
        return (Resolve-Path $InputCsv).Path
    }

    $previewRoot = Join-Path $RepoRoot "runtime\reports\vod_streams_delta_import_preview"
    if (-not (Test-Path $previewRoot)) {
        throw "VOD streams delta import preview report folder not found: $previewRoot"
    }

    $candidates = Get-ChildItem -Path $previewRoot -Filter "*.csv" -File -Recurse |
        Where-Object { $_.Name -match "vod_streams_delta_import_preview" } |
        Sort-Object LastWriteTimeUtc -Descending

    if (-not $candidates -or $candidates.Count -eq 0) {
        throw "No VOD streams delta import preview CSV report found under: $previewRoot"
    }

    return $candidates[0].FullName
}

function Get-LatestVodStreamsSnapshotPath {
    if (-not [string]::IsNullOrWhiteSpace($SnapshotPath)) {
        if (-not (Test-Path $SnapshotPath)) { throw "SnapshotPath not found: $SnapshotPath" }
        return (Resolve-Path $SnapshotPath).Path
    }

    $snapshotRoot = Join-Path $RepoRoot "runtime\provider_snapshots\vod_streams"
    if (-not (Test-Path $snapshotRoot)) {
        throw "VOD streams provider snapshot folder not found: $snapshotRoot"
    }

    $candidates = Get-ChildItem -Path $snapshotRoot -File -Recurse |
        Where-Object { $_.Extension.ToLowerInvariant() -in @(".csv", ".json", ".jsonl") } |
        Sort-Object LastWriteTimeUtc -Descending

    if (-not $candidates -or $candidates.Count -eq 0) {
        throw "No VOD streams snapshot file found under: $snapshotRoot"
    }

    return $candidates[0].FullName
}

function Get-SampledSnapshotRows {
    param([string]$Path, [int]$MaxRows)

    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -eq ".csv") {
        return @(Import-Csv -Path $Path | Select-Object -First $MaxRows)
    }

    if ($extension -eq ".jsonl") {
        $rows = New-Object System.Collections.Generic.List[object]
        Get-Content -Path $Path -TotalCount $MaxRows | ForEach-Object {
            if (-not [string]::IsNullOrWhiteSpace($_)) {
                try { $rows.Add(($_ | ConvertFrom-Json)) | Out-Null }
                catch {
                    $rows.Add([pscustomobject]@{ raw_line = $_; parse_error = $_.Exception.Message }) | Out-Null
                }
            }
        }
        return @($rows)
    }

    if ($extension -eq ".json") {
        $jsonText = Get-Content -Path $Path -Raw
        $parsed = $jsonText | ConvertFrom-Json

        if ($parsed -is [System.Array]) {
            return @($parsed | Select-Object -First $MaxRows)
        }

        foreach ($candidateProperty in @("rows", "items", "data", "results", "snapshot", "streams")) {
            if ($parsed.PSObject.Properties.Name -contains $candidateProperty) {
                $value = $parsed.$candidateProperty
                if ($value -is [System.Array]) {
                    return @($value | Select-Object -First $MaxRows)
                }
            }
        }

        return @($parsed | Select-Object -First 1)
    }

    throw "Unsupported snapshot file extension for row preview: $extension"
}

function Get-RowDisposition {
    param([object]$Row)

    if ($Row.PSObject.Properties.Name -contains "parse_error") {
        return @{ disposition = "malformed_json"; reason = [string]$Row.parse_error }
    }

    $streamId = Get-FirstValue -Row $Row -Names @("stream_id", "provider_stream_id", "id", "provider_id", "vod_id")
    $categoryId = Get-FirstValue -Row $Row -Names @("category_id", "provider_category_id")
    $name = Get-FirstValue -Row $Row -Names @("name", "title", "stream_display_name", "display_title")
    $containerExtension = Get-FirstValue -Row $Row -Names @("container_extension", "container", "extension")

    if ([string]::IsNullOrWhiteSpace([string]$streamId)) {
        return @{ disposition = "missing_provider_id"; reason = "stream_id/provider_stream_id/id missing" }
    }

    if ([string]::IsNullOrWhiteSpace([string]$categoryId)) {
        return @{ disposition = "missing_category"; reason = "category_id/provider_category_id missing" }
    }

    if ([string]::IsNullOrWhiteSpace([string]$name)) {
        return @{ disposition = "missing_required_field"; reason = "name/title missing" }
    }

    # Snapshot-only preview cannot know insert/update/unchanged without DB compare.
    # Treat valid rows as candidates for later compare/import.
    return @{
        disposition = "would_compare_for_insert_or_update"
        reason = "required snapshot fields present; DB compare not executed in preview"
        stream_id = [string]$streamId
        category_id = [string]$categoryId
        container_extension = [string]$containerExtension
    }
}

try {
    Invoke-ContractLog -EventName "job_started" -Status "running" -Data @{
        preview_only = $true
        allow_provider_noise_scan = [bool]$AllowProviderNoiseScan
        db_writes    = $false
        limit        = $Limit
    }
    Invoke-ContractHeartbeat -Status "running"

    if (-not (Test-WorkerKillSwitch)) {
        $summary = [ordered]@{
            status       = "disabled"
            preview_only = $true
        allow_provider_noise_scan = [bool]$AllowProviderNoiseScan
            db_writes    = $false
            run_id       = $RunId
        }
        Invoke-ContractSignal -SignalName "provider_snapshot_vod_streams_import_row_preview_completed" -SignalValue "disabled" -Payload $summary
        Invoke-ContractLog -EventName "job_completed" -Status "disabled" -Data $summary
        Write-Output "SKIPPED: $KillSwitchName is disabled. run_id=$RunId"
        exit 0
    }

    if ($Limit -lt 1) { $Limit = 250 }

    Invoke-ContractSignal -SignalName "provider_snapshot_vod_streams_import_row_preview_completed" -SignalValue "running" -Payload @{ preview_only = $true
        allow_provider_noise_scan = [bool]$AllowProviderNoiseScan; db_writes = $false; limit = $Limit }

    $lanePreviewCsv = Get-LatestLanePreviewCsv
    $laneRows = @(Import-Csv -Path $lanePreviewCsv)
    $vodLane = $laneRows | Where-Object { ([string](Get-FirstValue -Row $_ -Names @("lane_key"))).Trim() -eq "vod_streams" } | Select-Object -First 1

    if ($null -eq $vodLane) {
        throw "No vod_streams lane found in lane preview CSV: $lanePreviewCsv"
    }

    $laneDisposition = [string](Get-FirstValue -Row $vodLane -Names @("lane_disposition", "import_disposition", "preview_disposition") -Default "manual_review")
    $wouldImport = ConvertTo-BoolLoose (Get-FirstValue -Row $vodLane -Names @("would_import") -Default $false)

    $rows = @()
    $snapshotFile = $null
    $laneSkipped = $false

    if (-not $wouldImport -or $laneDisposition -ne "import_needed") {
        $laneSkipped = $true
        $rows = @([pscustomobject][ordered]@{
            row_number       = 1
            lane_key         = "vod_streams"
            source_file      = $null
            provider_stream_id = $null
            category_id      = $null
            title            = $null
            container_extension = $null
            row_disposition  = if ($laneDisposition -eq "skip_provider_noise" -and -not $AllowProviderNoiseScan) { "skipped_provider_noise" } else { "manual_review" }
            reason           = "lane_disposition=$laneDisposition; would_import=$wouldImport"
            would_write_db   = $false
        })
    }
    else {
        $snapshotFile = Get-LatestVodStreamsSnapshotPath
        $sampledRows = @(Get-SampledSnapshotRows -Path $snapshotFile -MaxRows $Limit)

        $index = 0
        $previewRows = New-Object System.Collections.Generic.List[object]
        foreach ($row in $sampledRows) {
            $index++
            $dispositionInfo = Get-RowDisposition -Row $row
            $streamId = Get-FirstValue -Row $row -Names @("stream_id", "provider_stream_id", "id", "provider_id", "vod_id")
            $categoryId = Get-FirstValue -Row $row -Names @("category_id", "provider_category_id")
            $name = Get-FirstValue -Row $row -Names @("name", "title", "stream_display_name", "display_title")
            $containerExtension = Get-FirstValue -Row $row -Names @("container_extension", "container", "extension")

            $previewRows.Add([pscustomobject][ordered]@{
                row_number          = $index
                lane_key            = "vod_streams"
                source_file         = $snapshotFile
                provider_stream_id  = $streamId
                category_id         = $categoryId
                title               = $name
                container_extension = $containerExtension
                row_disposition     = [string]$dispositionInfo.disposition
                reason              = [string]$dispositionInfo.reason
                would_write_db      = $false
            }) | Out-Null
        }

        $rows = @($previewRows)
    }

    $totalRows = @($rows).Count
    $validCompareCount = @($rows | Where-Object { $_.row_disposition -eq "would_compare_for_insert_or_update" }).Count
    $missingProviderIdCount = @($rows | Where-Object { $_.row_disposition -eq "missing_provider_id" }).Count
    $missingCategoryCount = @($rows | Where-Object { $_.row_disposition -eq "missing_category" }).Count
    $missingRequiredFieldCount = @($rows | Where-Object { $_.row_disposition -eq "missing_required_field" }).Count
    $malformedJsonCount = @($rows | Where-Object { $_.row_disposition -eq "malformed_json" }).Count
    $manualReviewCount = @($rows | Where-Object { $_.row_disposition -eq "manual_review" }).Count
    $skippedProviderNoiseCount = @($rows | Where-Object { $_.row_disposition -eq "skipped_provider_noise" }).Count

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $csvPath = Join-Path $OutputRoot "vod_streams_delta_import_row_preview_$timestamp.csv"
    $jsonPath = Join-Path $OutputRoot "vod_streams_delta_import_row_preview_summary_$timestamp.json"

    $rows | Export-Csv -Path $csvPath -NoTypeInformation

    $status = "pass"
    if (($missingProviderIdCount + $missingCategoryCount + $missingRequiredFieldCount + $malformedJsonCount + $manualReviewCount) -gt 0) {
        $status = "warning"
    }

    $summary = [ordered]@{
        status                         = $status
        preview_only                   = $true
        db_writes                      = $false
        lane                           = "vod_streams"
        lane_disposition               = $laneDisposition
        would_import                   = $wouldImport
        lane_skipped                   = $laneSkipped
        limit                          = $Limit
        sampled_rows                   = $totalRows
        source_snapshot                = $snapshotFile
        lane_preview_csv               = $lanePreviewCsv
        would_compare_count            = $validCompareCount
        missing_provider_id_count      = $missingProviderIdCount
        missing_category_count         = $missingCategoryCount
        missing_required_field_count   = $missingRequiredFieldCount
        malformed_json_count           = $malformedJsonCount
        manual_review_count            = $manualReviewCount
        skipped_provider_noise_count   = $skippedProviderNoiseCount
        would_write_db                 = $false
        run_id                         = $RunId
        output_csv                     = $csvPath
        output_json                    = $jsonPath
    }

    $summary | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Encoding UTF8

    Invoke-ContractSignal -SignalName "provider_snapshot_vod_streams_import_row_preview_completed" -SignalValue $status -Payload $summary
    Invoke-ContractSignal -SignalName "provider_snapshot_vod_streams_import_row_preview_sampled_count" -SignalValue $totalRows -Payload @{ run_id = $RunId }
    Invoke-ContractSignal -SignalName "provider_snapshot_vod_streams_import_row_preview_manual_review_count" -SignalValue $manualReviewCount -Payload @{ run_id = $RunId }
    Invoke-ContractSignal -SignalName "provider_snapshot_vod_streams_import_row_preview_missing_required_count" -SignalValue ($missingProviderIdCount + $missingCategoryCount + $missingRequiredFieldCount + $malformedJsonCount) -Payload @{ run_id = $RunId }

    Invoke-ContractHeartbeat -Status "ok"
    Invoke-ContractLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: VOD streams delta row preview completed. status=$status preview_only=True db_writes=False lane=vod_streams sampled_rows=$totalRows would_compare=$validCompareCount manual_review=$manualReviewCount missing_required=$($missingProviderIdCount + $missingCategoryCount + $missingRequiredFieldCount + $malformedJsonCount) run_id=$RunId"
        Write-Output "FILES: row_preview_csv=$csvPath summary_json=$jsonPath"
        $rows | Select-Object -First 25 | Format-Table row_number, provider_stream_id, category_id, container_extension, row_disposition, would_write_db -AutoSize
    }

    exit 0
}
catch {
    $message = $_.Exception.Message
    $summary = [ordered]@{
        status       = "fail"
        preview_only = $true
        allow_provider_noise_scan = [bool]$AllowProviderNoiseScan
        db_writes    = $false
        error        = $message
        run_id       = $RunId
    }

    Invoke-ContractSignal -SignalName "provider_snapshot_vod_streams_import_row_preview_completed" -SignalValue "fail" -Payload $summary
    Invoke-ContractHeartbeat -Status "failed"
    Invoke-ContractLog -EventName "job_failed" -Status "failed" -Data @{ error_message = $message }
    Write-Error "FAILED: VOD streams delta row preview failed. $message run_id=$RunId"
    exit 1
}


