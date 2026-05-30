<#
.SYNOPSIS
  Test VOD streams apply mapping using local fixture rows.

.DESCRIPTION
  Fixture-only worker for proving the row mapping contract that a future real VOD apply
  worker will use. It writes only runtime report files.

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
    [int]$MacUserId = 6,
    [string]$ProviderLabel = "eldervpn",
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "test_vod_streams_apply_mapping_fixture"
$Component = "vod_streams_apply_mapping_fixture"
$DatabaseTarget = "xpdgxfsp_content"
$SourceName = "synthetic_vod_streams_fixture"
$KillSwitchName = "ENABLE_VOD_STREAMS_APPLY_MAPPING_FIXTURE_TEST"

$CompletedSignal = "vod_streams_apply_mapping_fixture_test_completed"
$DispositionSignal = "vod_streams_apply_mapping_fixture_test_disposition"
$MappedCountSignal = "vod_streams_apply_mapping_fixture_test_mapped_count"
$RejectedCountSignal = "vod_streams_apply_mapping_fixture_test_rejected_count"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\vod_streams_apply_mapping_fixture"
$LogRoot = Join-Path $RepoRoot "runtime\logs\vod_streams_apply_mapping_fixture"

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

function Get-FirstValue {
    param([object]$Row, [string[]]$Names)

    if ($null -eq $Row) { return $null }

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

    return $null
}

function New-CleanTitle {
    param([string]$Title)

    if ([string]::IsNullOrWhiteSpace($Title)) { return "" }

    $clean = $Title.Trim()
    $clean = $clean -replace '^\s*[A-Z]{2}\|\s*', ''
    $clean = $clean -replace '\s+', ' '
    return $clean.Trim()
}

function New-VodMappingPreview {
    param([object]$InputRow)

    $providerStreamId = Get-FirstValue -Row $InputRow -Names @("stream_id", "provider_stream_id", "id")
    $name = Get-FirstValue -Row $InputRow -Names @("name", "title", "stream_display_name")
    $categoryId = Get-FirstValue -Row $InputRow -Names @("category_id", "provider_category_id")
    $containerExtension = Get-FirstValue -Row $InputRow -Names @("container_extension", "container", "extension")
    $streamIcon = Get-FirstValue -Row $InputRow -Names @("stream_icon", "movie_image", "cover", "icon")
    $added = Get-FirstValue -Row $InputRow -Names @("added", "added_at")
    $rating = Get-FirstValue -Row $InputRow -Names @("rating", "rating_5based")
    $tmdb = Get-FirstValue -Row $InputRow -Names @("tmdb", "tmdb_id")
    $year = Get-FirstValue -Row $InputRow -Names @("year", "release_year")

    $missing = @()
    if ([string]::IsNullOrWhiteSpace($providerStreamId)) { $missing += "provider_stream_id" }
    if ([string]::IsNullOrWhiteSpace($name)) { $missing += "name" }
    if ([string]::IsNullOrWhiteSpace($categoryId)) { $missing += "category_id" }

    $disposition = "mapped_preview"
    if (@($missing).Count -gt 0) {
        $disposition = "rejected_missing_required"
    }

    return [pscustomobject][ordered]@{
        row_disposition = $disposition
        missing_required_fields = ($missing -join "|")
        mac_user_id = $MacUserId
        provider_label = $ProviderLabel
        provider_stream_id = $providerStreamId
        provider_category_id = $categoryId
        title_raw = $name
        title_clean = New-CleanTitle -Title $name
        container_extension = $containerExtension
        stream_icon = $streamIcon
        added = $added
        rating = $rating
        tmdb_id = $tmdb
        year = $year
        proposed_table = "vod_streams_or_catalog_target_pending_confirmation"
        proposed_operation = "upsert_preview_only"
        protected_fields_rule = "do_not_overwrite_enriched_fields_with_blank_provider_values"
        db_writes = $false
        provider_calls = $false
        fixture_only = $true
    }
}

try {
    Write-LocalJsonLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        fixture_only = $true
        db_writes = $false
        provider_calls = $false
        mac_user_id = $MacUserId
        provider_label = $ProviderLabel
    })

    Emit-LocalHeartbeat -Status "running"

    if (-not (Test-WorkerKillSwitch)) {
        $summary = [ordered]@{
            status = "disabled"
            disposition = "disabled_by_kill_switch"
            fixture_only = $true
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

    $fixtureRows = @(
        [pscustomobject][ordered]@{
            stream_id = "999001"
            name = "EN| Fixture Movie Example"
            category_id = "120"
            container_extension = "mkv"
            stream_icon = "https://example.invalid/fixture_movie.jpg"
            added = "1717000000"
            rating = "6.8"
            tmdb = "123456"
            year = "2026"
        },
        [pscustomobject][ordered]@{
            stream_id = ""
            name = "EN| Missing ID Fixture"
            category_id = "120"
            container_extension = "mp4"
        }
    )

    $mappedRows = @()
    foreach ($fixture in $fixtureRows) {
        $mappedRows += New-VodMappingPreview -InputRow $fixture
    }

    $mappedCount = @($mappedRows | Where-Object { $_.row_disposition -eq "mapped_preview" }).Count
    $rejectedCount = @($mappedRows | Where-Object { $_.row_disposition -ne "mapped_preview" }).Count

    $disposition = "fixture_mapping_passed"
    $status = "pass"
    if ($rejectedCount -gt 0) {
        $disposition = "fixture_mapping_passed_with_expected_rejections"
        $status = "warning"
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $reportCsv = Join-Path $OutputRoot "vod_streams_apply_mapping_fixture_$timestamp.csv"
    $reportJson = Join-Path $OutputRoot "vod_streams_apply_mapping_fixture_$timestamp.json"
    $summaryJson = Join-Path $OutputRoot "vod_streams_apply_mapping_fixture_summary_$timestamp.json"

    $mappedRows | Export-Csv -Path $reportCsv -NoTypeInformation
    $mappedRows | ConvertTo-Json -Depth 20 | Set-Content -Path $reportJson -Encoding UTF8

    $summary = [ordered]@{
        status = $status
        disposition = $disposition
        fixture_only = $true
        db_writes = $false
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        mac_user_id = $MacUserId
        provider_label = $ProviderLabel
        total_rows = @($mappedRows).Count
        mapped_count = $mappedCount
        rejected_count = $rejectedCount
        report_csv = $reportCsv
        report_json = $reportJson
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $status -Payload $summary
    Emit-LocalSignal -SignalName $DispositionSignal -SignalValue $disposition -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $MappedCountSignal -SignalValue $mappedCount -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $RejectedCountSignal -SignalValue $rejectedCount -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: VOD streams apply mapping fixture test completed. status=$status disposition=$disposition mapped=$mappedCount rejected=$rejectedCount db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: report_csv=$reportCsv report_json=$reportJson summary_json=$summaryJson"
        $mappedRows | Format-Table -AutoSize
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

    Write-Error "FAILED: VOD streams apply mapping fixture test failed. $message run_id=$RunId"
    exit 1
}
