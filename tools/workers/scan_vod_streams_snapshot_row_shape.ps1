<#
.SYNOPSIS
  Read-only row-shape scan for the latest VOD streams provider snapshot.

.DESCRIPTION
  Scans sampled rows from the latest runtime/provider_snapshots/vod_streams snapshot and
  assigns row-level dispositions without provider calls, DB reads, DB writes, import, or mutation.
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [int]$MacUserId = 6,
    [string]$ProviderLabel = "eldervpn",
    [string]$SnapshotPath,
    [int]$Limit = 250,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "scan_vod_streams_snapshot_row_shape"
$Component = "provider_snapshot_vod_streams_row_shape_scan"
$DatabaseTarget = "none"
$SourceName = "provider_vod_streams_snapshot"
$KillSwitchName = "ENABLE_PROVIDER_SNAPSHOT_VOD_STREAMS_ROW_SHAPE_SCAN"
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$StartedAt = Get-Date
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\vod_streams_snapshot_row_shape_scan"
$LogRoot = Join-Path $RepoRoot "runtime\logs\vod_streams_snapshot_row_shape_scan"

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null

$LoggingModule = Join-Path $RepoRoot "tools\common\Logging.psm1"
if (Test-Path -LiteralPath $LoggingModule) {
    Import-Module $LoggingModule -Force
}

function Write-LocalJsonLog {
    param([string]$EventName, [string]$Status, [hashtable]$Data = @{})

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
    Add-Content -Path $logPath -Value ($record | ConvertTo-Json -Depth 12 -Compress)
}

function Invoke-ContractLog {
    param([string]$EventName, [string]$Status, [hashtable]$Data = @{})

    # Contract marker: Write-JobLog
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
        } catch {}
    }

    Write-LocalJsonLog -EventName $EventName -Status $Status -Data $Data
}

function Invoke-ContractSignal {
    param([string]$SignalName, [object]$SignalValue, [hashtable]$Payload = @{})

    # Contract marker: Emit-Signal
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
        } catch {}
    }

    Write-LocalJsonLog -EventName "signal_emitted" -Status "ok" -Data @{ signal_name = $SignalName; signal_value = $SignalValue; payload = $Payload }
}

function Invoke-ContractHeartbeat {
    param([string]$Status = "ok")

    # Contract marker: Emit-Heartbeat
    if (Get-Command Emit-Heartbeat -ErrorAction SilentlyContinue) {
        try {
            Emit-Heartbeat `
                -RunId $RunId `
                -JobName $WorkerName `
                -WorkerName $WorkerName `
                -Component $Component `
                -Environment $Environment `
                -Status $Status | Out-Null
            return
        } catch {}
    }

    Write-LocalJsonLog -EventName "heartbeat" -Status $Status -Data @{}
}

function Test-WorkerKillSwitch {
    # Contract marker: Test-KillSwitch
    if (Get-Command Test-KillSwitch -ErrorAction SilentlyContinue) {
        try {
            return [bool](Test-KillSwitch -Name $KillSwitchName -DefaultEnabled $true)
        } catch {}
    }

    $raw = [Environment]::GetEnvironmentVariable($KillSwitchName)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $true }
    return ($raw.Trim().ToLowerInvariant() -notin @("0", "false", "no", "off", "disabled"))
}

function Get-FirstValue {
    param([object]$Row, [string[]]$Names, [object]$Default = $null)

    if ($null -eq $Row) { return $Default }
    $properties = @($Row.PSObject.Properties)

    foreach ($name in $Names) {
        $match = $properties | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
        if ($null -ne $match -and $null -ne $match.Value -and -not [string]::IsNullOrWhiteSpace([string]$match.Value)) {
            return $match.Value
        }
    }

    return $Default
}

function Get-LatestVodStreamsSnapshotPath {
    if (-not [string]::IsNullOrWhiteSpace($SnapshotPath)) {
        if (-not (Test-Path -LiteralPath $SnapshotPath)) { throw "SnapshotPath not found: $SnapshotPath" }
        return (Resolve-Path -LiteralPath $SnapshotPath).Path
    }

    $snapshotRoot = Join-Path $RepoRoot ("runtime\provider_snapshots\vod_streams\mac_{0}\{1}" -f $MacUserId, $ProviderLabel)
    if (-not (Test-Path -LiteralPath $snapshotRoot)) {
        throw "VOD streams snapshot folder not found: $snapshotRoot"
    }

    $latest = Get-ChildItem -LiteralPath $snapshotRoot -Filter "vod_streams_*.json" -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    if ($null -eq $latest) {
        throw "No vod_streams_*.json snapshot found under: $snapshotRoot"
    }

    return $latest.FullName
}

function Get-SampledRows {
    param([string]$Path, [int]$MaxRows)

    if ($MaxRows -lt 1) { $MaxRows = 250 }

    $json = Get-Content -LiteralPath $Path -Raw
    $data = $json | ConvertFrom-Json

    if ($data -is [System.Array]) {
        return @($data | Select-Object -First $MaxRows)
    }

    foreach ($propertyName in @("items", "data", "results", "streams", "vod_streams")) {
        $property = $data.PSObject.Properties | Where-Object { $_.Name -ieq $propertyName } | Select-Object -First 1
        if ($null -ne $property -and $null -ne $property.Value) {
            return @($property.Value | Select-Object -First $MaxRows)
        }
    }

    return @($data | Select-Object -First $MaxRows)
}

function Get-RowDisposition {
    param([object]$Row)

    $streamId = Get-FirstValue -Row $Row -Names @("stream_id", "provider_stream_id", "id", "provider_id", "vod_id")
    $categoryId = Get-FirstValue -Row $Row -Names @("category_id", "provider_category_id")
    $name = Get-FirstValue -Row $Row -Names @("name", "title", "stream_display_name", "display_title")
    $container = Get-FirstValue -Row $Row -Names @("container_extension", "container", "extension")

    $missing = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace([string]$streamId)) { $missing.Add("provider_stream_id") | Out-Null }
    if ([string]::IsNullOrWhiteSpace([string]$categoryId)) { $missing.Add("category_id") | Out-Null }
    if ([string]::IsNullOrWhiteSpace([string]$name)) { $missing.Add("title") | Out-Null }
    if ([string]::IsNullOrWhiteSpace([string]$container)) { $missing.Add("container_extension") | Out-Null }

    if ($missing.Count -gt 0) {
        $disposition = "missing_required_field"
        if ($missing -contains "provider_stream_id") { $disposition = "missing_provider_id" }
        elseif ($missing -contains "category_id") { $disposition = "missing_category" }

        return [pscustomobject]@{
            disposition = $disposition
            reason = "missing=" + (($missing.ToArray()) -join "|")
        }
    }

    return [pscustomobject]@{
        disposition = "would_compare_for_insert_or_update"
        reason = "required_fields_present"
    }
}

try {
    if ($Limit -lt 1) { $Limit = 250 }

    Invoke-ContractLog -EventName "job_started" -Status "running" -Data @{
        preview_only = $true
        db_writes = $false
        limit = $Limit
        mac_user_id = $MacUserId
        provider_label = $ProviderLabel
    }
    Invoke-ContractHeartbeat -Status "running"

    if (-not (Test-WorkerKillSwitch)) {
        $summary = [ordered]@{
            status = "disabled"
            preview_only = $true
            db_writes = $false
            run_id = $RunId
        }
        Invoke-ContractSignal -SignalName "provider_snapshot_vod_streams_row_shape_scan_completed" -SignalValue "disabled" -Payload $summary
        Invoke-ContractLog -EventName "job_completed" -Status "disabled" -Data $summary
        Write-Output "SKIPPED: $KillSwitchName is disabled. run_id=$RunId"
        exit 0
    }

    $snapshotFile = Get-LatestVodStreamsSnapshotPath
    $sampledRows = @(Get-SampledRows -Path $snapshotFile -MaxRows $Limit)

    $index = 0
    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($row in $sampledRows) {
        $index++
        try {
            $disp = Get-RowDisposition -Row $row

            $rows.Add([pscustomobject][ordered]@{
                row_number = $index
                provider_stream_id = Get-FirstValue -Row $row -Names @("stream_id", "provider_stream_id", "id", "provider_id", "vod_id")
                category_id = Get-FirstValue -Row $row -Names @("category_id", "provider_category_id")
                title = Get-FirstValue -Row $row -Names @("name", "title", "stream_display_name", "display_title")
                container_extension = Get-FirstValue -Row $row -Names @("container_extension", "container", "extension")
                row_disposition = [string]$disp.disposition
                reason = [string]$disp.reason
                would_write_db = $false
            }) | Out-Null
        }
        catch {
            $rows.Add([pscustomobject][ordered]@{
                row_number = $index
                provider_stream_id = $null
                category_id = $null
                title = $null
                container_extension = $null
                row_disposition = "malformed_json"
                reason = $_.Exception.Message
                would_write_db = $false
            }) | Out-Null
        }
    }

    $totalRows = @($rows).Count
    $wouldCompareCount = @($rows | Where-Object { $_.row_disposition -eq "would_compare_for_insert_or_update" }).Count
    $missingProviderIdCount = @($rows | Where-Object { $_.row_disposition -eq "missing_provider_id" }).Count
    $missingCategoryCount = @($rows | Where-Object { $_.row_disposition -eq "missing_category" }).Count
    $missingRequiredFieldCount = @($rows | Where-Object { $_.row_disposition -eq "missing_required_field" }).Count
    $malformedJsonCount = @($rows | Where-Object { $_.row_disposition -eq "malformed_json" }).Count
    $manualReviewCount = $missingProviderIdCount + $missingCategoryCount + $missingRequiredFieldCount + $malformedJsonCount

    $status = if ($manualReviewCount -gt 0) { "warning" } else { "pass" }
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $csvPath = Join-Path $OutputRoot "vod_streams_snapshot_row_shape_scan_$timestamp.csv"
    $jsonPath = Join-Path $OutputRoot "vod_streams_snapshot_row_shape_scan_summary_$timestamp.json"

    $rows | Export-Csv -Path $csvPath -NoTypeInformation

    $summary = [ordered]@{
        status = $status
        preview_only = $true
        db_writes = $false
        worker_name = $WorkerName
        run_id = $RunId
        mac_user_id = $MacUserId
        provider_label = $ProviderLabel
        source_snapshot = $snapshotFile
        limit = $Limit
        sampled_rows = $totalRows
        would_compare_count = $wouldCompareCount
        manual_review_count = $manualReviewCount
        missing_provider_id_count = $missingProviderIdCount
        missing_category_count = $missingCategoryCount
        missing_required_field_count = $missingRequiredFieldCount
        malformed_json_count = $malformedJsonCount
        row_preview_csv = $csvPath
        summary_json = $jsonPath
    }

    $summary | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Encoding UTF8

    Invoke-ContractSignal -SignalName "provider_snapshot_vod_streams_row_shape_scan_completed" -SignalValue $status -Payload $summary
    Invoke-ContractSignal -SignalName "provider_snapshot_vod_streams_row_shape_scan_sampled_count" -SignalValue $totalRows -Payload @{ run_id = $RunId }
    Invoke-ContractSignal -SignalName "provider_snapshot_vod_streams_row_shape_scan_manual_review_count" -SignalValue $manualReviewCount -Payload @{ run_id = $RunId }
    Invoke-ContractSignal -SignalName "provider_snapshot_vod_streams_row_shape_scan_missing_required_count" -SignalValue ($missingProviderIdCount + $missingCategoryCount + $missingRequiredFieldCount + $malformedJsonCount) -Payload @{ run_id = $RunId }
    Invoke-ContractHeartbeat -Status "ok"
    Invoke-ContractLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: VOD streams snapshot row shape scan completed. status=$status preview_only=True db_writes=False sampled_rows=$totalRows would_compare=$wouldCompareCount manual_review=$manualReviewCount run_id=$RunId"
        Write-Output "FILES: row_shape_csv=$csvPath summary_json=$jsonPath"
        $rows | Select-Object -First 25 | Format-Table row_number, provider_stream_id, category_id, container_extension, row_disposition, would_write_db -AutoSize
    }

    exit 0
}
catch {
    $message = $_.Exception.Message
    Invoke-ContractSignal -SignalName "provider_snapshot_vod_streams_row_shape_scan_completed" -SignalValue "fail" -Payload @{ run_id = $RunId; error_message = $message }
    Invoke-ContractHeartbeat -Status "failed"
    Invoke-ContractLog -EventName "job_failed" -Status "failed" -Data @{ error_message = $message }
    Write-Error "FAILED: VOD streams snapshot row shape scan failed. $message run_id=$RunId"
    exit 1
}
