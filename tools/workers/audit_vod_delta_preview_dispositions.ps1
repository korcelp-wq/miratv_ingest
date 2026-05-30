<#
.SYNOPSIS
  Audit VOD delta preview dispositions and no-import reasons.

.DESCRIPTION
  Read-only diagnostic worker.

  This worker inspects latest VOD/provider delta preview outputs and answers:
    - Which CSV is producing zero planned imports?
    - What dispositions are present?
    - What reason fields are present?
    - Are rows being classified as provider noise?
    - Are rows missing key fields?
    - Are we comparing the wrong snapshots or reading the wrong file?
    - What should be adjusted next?

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
    [int]$SampleRows = 25,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "audit_vod_delta_preview_dispositions"
$Component = "vod_delta_preview_dispositions"
$DatabaseTarget = "none"
$SourceName = "runtime_vod_delta_preview_reports"
$KillSwitchName = "ENABLE_VOD_DELTA_PREVIEW_DISPOSITION_AUDIT"

$CompletedSignal = "vod_delta_preview_disposition_audit_completed"
$DispositionSignal = "vod_delta_preview_disposition_audit_disposition"
$PlannedImportCountSignal = "vod_delta_preview_disposition_audit_planned_import_count"
$ProviderNoiseCountSignal = "vod_delta_preview_disposition_audit_provider_noise_count"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\vod_delta_preview_disposition_audit"
$LogRoot = Join-Path $RepoRoot "runtime\logs\vod_delta_preview_disposition_audit"

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

function Get-IntValue {
    param([object]$Object, [string]$Name, [int]$Default = 0)

    $text = Get-Text -Object $Object -Name $Name -Default ""
    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }

    $value = 0
    if ([int]::TryParse($text, [ref]$value)) { return $value }

    return $Default
}

function Get-RowValue {
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

function New-CountRows {
    param(
        [object[]]$Rows,
        [string]$FieldName,
        [string]$SourceKey
    )

    $counts = @()

    if ($null -eq $Rows -or @($Rows).Count -eq 0) {
        return @()
    }

    $hasField = $false
    foreach ($row in $Rows) {
        if ($row.PSObject.Properties.Name -contains $FieldName) {
            $hasField = $true
            break
        }
    }

    if (-not $hasField) {
        return @()
    }

    $groups = $Rows | Group-Object -Property $FieldName | Sort-Object Count -Descending
    foreach ($group in $groups) {
        $value = [string]$group.Name
        if ([string]::IsNullOrWhiteSpace($value)) { $value = "<blank>" }

        $counts += [pscustomobject][ordered]@{
            source_key = $SourceKey
            field_name = $FieldName
            field_value = $value
            row_count = $group.Count
            db_reads = $false
            db_writes = $false
            provider_calls = $false
        }
    }

    return $counts
}

function Get-MissingKeyCounts {
    param([object[]]$Rows, [string]$SourceKey)

    $keyMap = [ordered]@{
        provider_stream_id = @("provider_stream_id", "stream_id", "id")
        provider_category_id = @("provider_category_id", "category_id")
        title = @("title", "name", "title_raw", "stream_display_name")
        container_extension = @("container_extension", "container", "extension")
    }

    $output = @()

    foreach ($keyName in $keyMap.Keys) {
        $missing = 0
        foreach ($row in $Rows) {
            $value = Get-RowValue -Row $row -Names $keyMap[$keyName]
            if ([string]::IsNullOrWhiteSpace($value)) {
                $missing++
            }
        }

        $output += [pscustomobject][ordered]@{
            source_key = $SourceKey
            field_name = $keyName
            missing_count = $missing
            total_rows = @($Rows).Count
            db_reads = $false
            db_writes = $false
            provider_calls = $false
        }
    }

    return $output
}

try {
    if ($SampleRows -lt 1) { $SampleRows = 25 }
    if ($SampleRows -gt 250) { $SampleRows = 250 }

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

    $sources = @(
        [ordered]@{
            key = "provider_snapshot_delta_import_dryrun"
            folder = Join-Path $RepoRoot "runtime\reports\provider_snapshot_delta_import_dryrun"
            summary_filter = "provider_snapshot_delta_import_dryrun_summary_*.json"
            csv_filter = "provider_snapshot_delta_import_dryrun_*.csv"
        },
        [ordered]@{
            key = "vod_streams_delta_import_preview"
            folder = Join-Path $RepoRoot "runtime\reports\vod_streams_delta_import_preview"
            summary_filter = "vod_streams_delta_import_preview_summary_*.json"
            csv_filter = "vod_streams_delta_import_preview_*.csv"
        },
        [ordered]@{
            key = "provider_snapshot_import_candidate_selector"
            folder = Join-Path $RepoRoot "runtime\reports\provider_snapshot_import_candidate_selector"
            summary_filter = "provider_snapshot_import_candidate_selection_summary_*.json"
            csv_filter = "provider_snapshot_import_candidate_selection_*.csv"
        }
    )

    $sourceRows = @()
    $fieldCountRows = @()
    $missingRows = @()
    $sampleOutputRows = @()

    $plannedImportTotal = 0
    $providerNoiseTotal = 0
    $totalCsvRows = 0
    $recommendations = @()

    foreach ($source in $sources) {
        $summaryFile = Get-LatestFile -Folder $source.folder -Filter $source.summary_filter
        $csvFile = Get-LatestFile -Folder $source.folder -Filter $source.csv_filter

        $summary = $null
        if ($summaryFile) {
            $summary = Read-JsonFile -Path $summaryFile.FullName
        }

        $plannedImportCount = Get-IntValue -Object $summary -Name "planned_import_count" -Default 0
        $providerNoiseCount = Get-IntValue -Object $summary -Name "skipped_provider_noise_count" -Default 0
        $manualReviewCount = Get-IntValue -Object $summary -Name "manual_review_count" -Default 0
        $totalRowsFromSummary = Get-IntValue -Object $summary -Name "total_rows" -Default 0
        $sourceRowsFromSummary = Get-IntValue -Object $summary -Name "source_row_count" -Default 0
        $disposition = Get-Text -Object $summary -Name "disposition" -Default ""
        if ([string]::IsNullOrWhiteSpace($disposition)) {
            $disposition = Get-Text -Object $summary -Name "selector_disposition" -Default ""
        }
        $candidateFound = Get-Text -Object $summary -Name "candidate_found" -Default ""

        $rows = @()
        if ($csvFile) {
            try {
                $rows = @(Import-Csv -LiteralPath $csvFile.FullName)
            }
            catch {
                $rows = @()
            }
        }

        $csvRowCount = @($rows).Count
        $totalCsvRows += $csvRowCount
        $plannedImportTotal += $plannedImportCount
        $providerNoiseTotal += $providerNoiseCount

        $headers = @()
        if ($csvRowCount -gt 0) {
            $headers = @($rows[0].PSObject.Properties.Name)
        }

        $sourceRows += [pscustomobject][ordered]@{
            source_key = $source.key
            latest_summary = $(if ($summaryFile) { $summaryFile.FullName } else { "" })
            latest_csv = $(if ($csvFile) { $csvFile.FullName } else { "" })
            csv_row_count = $csvRowCount
            summary_total_rows = $totalRowsFromSummary
            summary_source_row_count = $sourceRowsFromSummary
            planned_import_count = $plannedImportCount
            skipped_provider_noise_count = $providerNoiseCount
            manual_review_count = $manualReviewCount
            candidate_found = $candidateFound
            disposition = $disposition
            headers = ($headers -join "|")
            db_reads = $false
            db_writes = $false
            provider_calls = $false
        }

        if ($csvRowCount -gt 0) {
            $candidateFieldNames = @(
                "action",
                "disposition",
                "row_disposition",
                "reason",
                "skip_reason",
                "decision",
                "classification",
                "lane_key",
                "media_type",
                "change_type",
                "provider_noise",
                "recommended_action"
            )

            foreach ($fieldName in $candidateFieldNames) {
                $fieldCountRows += New-CountRows -Rows $rows -FieldName $fieldName -SourceKey $source.key
            }

            $missingRows += Get-MissingKeyCounts -Rows $rows -SourceKey $source.key

            foreach ($row in ($rows | Select-Object -First $SampleRows)) {
                $sampleOutputRows += [pscustomobject][ordered]@{
                    source_key = $source.key
                    provider_stream_id = Get-RowValue -Row $row -Names @("provider_stream_id", "stream_id", "id")
                    provider_category_id = Get-RowValue -Row $row -Names @("provider_category_id", "category_id")
                    title = Get-RowValue -Row $row -Names @("title", "name", "title_raw", "stream_display_name")
                    action = Get-RowValue -Row $row -Names @("action")
                    disposition = Get-RowValue -Row $row -Names @("disposition", "row_disposition")
                    reason = Get-RowValue -Row $row -Names @("reason", "skip_reason", "classification")
                    recommended_action = Get-RowValue -Row $row -Names @("recommended_action")
                    db_reads = $false
                    db_writes = $false
                    provider_calls = $false
                }
            }
        }
    }

    if ($plannedImportTotal -eq 0 -and $providerNoiseTotal -gt 0) {
        $recommendations += "inspect_provider_noise_rules"
    }

    if ($plannedImportTotal -eq 0 -and $totalCsvRows -gt 0) {
        $recommendations += "inspect_disposition_action_values_in_latest_csv"
    }

    if ($totalCsvRows -eq 0) {
        $recommendations += "preview_csv_missing_or_empty"
    }

    $vodPreviewSource = $sourceRows | Where-Object { $_.source_key -eq "vod_streams_delta_import_preview" } | Select-Object -First 1
    if ($vodPreviewSource -and [int]$vodPreviewSource.csv_row_count -gt 0 -and [int]$vodPreviewSource.planned_import_count -eq 0) {
        $recommendations += "vod_preview_has_rows_but_no_planned_imports"
    }

    $status = "pass"
    $disposition = "vod_delta_preview_dispositions_audited"

    if ($plannedImportTotal -eq 0) {
        $status = "warning"
        $disposition = "vod_delta_preview_zero_planned_imports_explained"
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $sourcesCsv = Join-Path $OutputRoot "vod_delta_preview_disposition_sources_$timestamp.csv"
    $fieldCountsCsv = Join-Path $OutputRoot "vod_delta_preview_disposition_field_counts_$timestamp.csv"
    $missingCsv = Join-Path $OutputRoot "vod_delta_preview_disposition_missing_keys_$timestamp.csv"
    $sampleCsv = Join-Path $OutputRoot "vod_delta_preview_disposition_sample_rows_$timestamp.csv"
    $summaryJson = Join-Path $OutputRoot "vod_delta_preview_disposition_summary_$timestamp.json"
    $diagnosisTxt = Join-Path $OutputRoot "vod_delta_preview_disposition_diagnosis_$timestamp.txt"

    $sourceRows | Export-Csv -Path $sourcesCsv -NoTypeInformation
    $fieldCountRows | Export-Csv -Path $fieldCountsCsv -NoTypeInformation
    $missingRows | Export-Csv -Path $missingCsv -NoTypeInformation
    $sampleOutputRows | Export-Csv -Path $sampleCsv -NoTypeInformation

    @"
VOD Delta Preview Disposition Audit

Disposition:
  $disposition

Planned import total:
  $plannedImportTotal

Provider noise total:
  $providerNoiseTotal

Total CSV rows inspected:
  $totalCsvRows

Recommendations:
  $($recommendations -join "`n  ")

No DB reads.
No DB writes.
No provider calls.
"@ | Set-Content -Path $diagnosisTxt -Encoding UTF8

    $summary = [ordered]@{
        status = $status
        disposition = $disposition
        planned_import_total = [int]$plannedImportTotal
        provider_noise_total = [int]$providerNoiseTotal
        total_csv_rows = [int]$totalCsvRows
        recommendations = $recommendations
        db_reads = $false
        db_writes = $false
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        sources_csv = $sourcesCsv
        field_counts_csv = $fieldCountsCsv
        missing_keys_csv = $missingCsv
        sample_rows_csv = $sampleCsv
        diagnosis_txt = $diagnosisTxt
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $status -Payload $summary
    Emit-LocalSignal -SignalName $DispositionSignal -SignalValue $disposition -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $PlannedImportCountSignal -SignalValue ([int]$plannedImportTotal) -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $ProviderNoiseCountSignal -SignalValue ([int]$providerNoiseTotal) -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: VOD delta preview dispositions audited. status=$status disposition=$disposition planned_import_total=$plannedImportTotal provider_noise_total=$providerNoiseTotal total_csv_rows=$totalCsvRows db_reads=False db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: sources_csv=$sourcesCsv field_counts_csv=$fieldCountsCsv missing_keys_csv=$missingCsv sample_rows_csv=$sampleCsv diagnosis_txt=$diagnosisTxt summary_json=$summaryJson"
        "`nSOURCES:"
        $sourceRows | Format-Table -AutoSize
        "`nFIELD COUNTS:"
        $fieldCountRows | Select-Object -First 50 | Format-Table -AutoSize
        "`nMISSING KEYS:"
        $missingRows | Format-Table -AutoSize
        "`nSAMPLES:"
        $sampleOutputRows | Select-Object -First $SampleRows | Format-Table -AutoSize
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

    Write-Error "FAILED: VOD delta preview disposition audit failed. $message run_id=$RunId"
    exit 1
}
