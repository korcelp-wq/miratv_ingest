<#
.SYNOPSIS
  Apply VOD streams delta with strict bounded controls.

.DESCRIPTION
  Governed VOD streams limited apply worker.

  Current behavior:
    - Default is dry-run.
    - DB writes are disabled.
    - Provider calls are disabled.
    - Real apply is refused until a later promoted implementation.
    - The worker self-blocks unless the latest real selector says:
        candidate_found=True
        selected_lane=vod_streams
        next_worker=apply_vod_streams_delta_limited.ps1
    - Synthetic simulator output is never accepted as apply authorization.
    - When a real candidate exists, this worker routes candidate rows through
      tools/common/MiraDbSafeAdapter.psm1 in dry-run mode only.
    - Row-level disposition discipline is enforced.

.CONTRACT-MARKERS
  Write-JobLog
  Emit-Signal
  Emit-Heartbeat
  Test-KillSwitch
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [int]$Limit = 25,
    [switch]$Apply,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "apply_vod_streams_delta_limited"
$Component = "vod_streams_delta_limited_apply"
$DatabaseTarget = "xpdgxfsp_content"
$SourceName = "provider_snapshot_import_candidate_selector"
$KillSwitchName = "ENABLE_VOD_STREAMS_DELTA_LIMITED_APPLY"

$CompletedSignal = "vod_streams_delta_limited_apply_completed"
$DispositionSignal = "vod_streams_delta_limited_apply_disposition"
$WouldWriteCountSignal = "vod_streams_delta_limited_apply_would_write_count"
$ActualWriteCountSignal = "vod_streams_delta_limited_apply_actual_write_count"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\vod_streams_delta_limited_apply"
$LogRoot = Join-Path $RepoRoot "runtime\logs\vod_streams_delta_limited_apply"
$AdapterModulePath = Join-Path $RepoRoot "tools\common\MiraDbSafeAdapter.psm1"

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

function Get-Bool {
    param([object]$Object, [string]$Name, [bool]$Default = $false)

    $text = Get-Text -Object $Object -Name $Name -Default ""
    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }

    return ($text.Trim().ToLowerInvariant() -in @("true", "1", "yes"))
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

function New-CleanTitle {
    param([string]$Title)

    if ([string]::IsNullOrWhiteSpace($Title)) { return "" }

    $clean = $Title.Trim()
    $clean = $clean -replace '^\s*[A-Z]{2}\|\s*', ''
    $clean = $clean -replace '\s+', ' '
    return $clean.Trim()
}

function Convert-ToAdapterParameters {
    param([object]$Row)

    $titleRaw = Get-RowValue -Row $Row -Names @("title_raw", "name", "title", "stream_display_name")
    $titleClean = Get-RowValue -Row $Row -Names @("title_clean", "clean_search_name") -Default (New-CleanTitle -Title $titleRaw)

    return @{
        mac_user_id = Get-RowValue -Row $Row -Names @("mac_user_id") -Default "6"
        provider_label = Get-RowValue -Row $Row -Names @("provider_label", "provider") -Default "unknown"
        provider_stream_id = Get-RowValue -Row $Row -Names @("provider_stream_id", "stream_id", "id")
        provider_category_id = Get-RowValue -Row $Row -Names @("provider_category_id", "category_id")
        title_raw = $titleRaw
        title_clean = $titleClean
        container_extension = Get-RowValue -Row $Row -Names @("container_extension", "container", "extension")
        stream_icon = Get-RowValue -Row $Row -Names @("stream_icon", "movie_image", "cover", "icon")
        added = Get-RowValue -Row $Row -Names @("added", "added_at")
        rating = Get-RowValue -Row $Row -Names @("rating", "rating_5based")
        tmdb_id = Get-RowValue -Row $Row -Names @("tmdb_id", "tmdb")
        year = Get-RowValue -Row $Row -Names @("year", "release_year")
    }
}

function Get-LatestRealSelectorSummary {
    $latest = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\provider_snapshot_import_candidate_selector") -Filter "provider_snapshot_import_candidate_selection_summary_*.json"
    if ($null -eq $latest) { return $null }
    return Read-JsonFile -Path $latest.FullName
}

function Get-LatestVodPreviewSummary {
    $latest = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_streams_delta_import_preview") -Filter "vod_streams_delta_import_preview_summary_*.json"
    if ($null -eq $latest) { return $null }
    return Read-JsonFile -Path $latest.FullName
}

function Get-LatestSqlContractSummary {
    $latest = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_streams_apply_sql_contract") -Filter "vod_streams_apply_sql_contract_summary_*.json"
    if ($null -eq $latest) { return $null }
    return Read-JsonFile -Path $latest.FullName
}

try {
    if ($Limit -lt 1) { $Limit = 1 }
    if ($Limit -gt 100) { $Limit = 100 }

    $dryRun = -not [bool]$Apply

    Write-LocalJsonLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        dry_run = $dryRun
        apply_requested = [bool]$Apply
        limit = $Limit
        provider_calls = $false
        db_writes = $false
        adapter_module_path = $AdapterModulePath
    })

    Emit-LocalHeartbeat -Status "running"

    if (-not (Test-WorkerKillSwitch)) {
        $summary = [ordered]@{
            status = "disabled"
            disposition = "disabled_by_kill_switch"
            dry_run = $dryRun
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

    $selector = Get-LatestRealSelectorSummary
    $vodPreview = Get-LatestVodPreviewSummary
    $sqlContract = Get-LatestSqlContractSummary

    $candidateFound = Get-Bool -Object $selector -Name "candidate_found" -Default $false
    $selectedLane = Get-Text -Object $selector -Name "selected_lane" -Default "none"
    $selectorDisposition = Get-Text -Object $selector -Name "selector_disposition" -Default "unknown"
    $selectorNextWorker = Get-Text -Object $selector -Name "next_worker" -Default "none"

    $plannedImportCount = Get-IntValue -Object $vodPreview -Name "planned_import_count" -Default 0
    $sourceRowCount = Get-IntValue -Object $vodPreview -Name "source_row_count" -Default 0
    $manualReviewCount = Get-IntValue -Object $vodPreview -Name "manual_review_count" -Default 0
    $skippedProviderNoiseCount = Get-IntValue -Object $vodPreview -Name "skipped_provider_noise_count" -Default 0
    $vodPreviewOutputCsv = Get-Text -Object $vodPreview -Name "output_csv" -Default ""

    $sqlTemplateFile = Get-Text -Object $sqlContract -Name "sql_template_file" -Default ""
    $parameterCsv = Get-Text -Object $sqlContract -Name "parameter_csv" -Default ""

    $blockReasons = @()
    $disposition = "blocked_no_real_candidate"
    $wouldWriteCount = 0
    $actualWriteCount = 0
    $dryRunCount = 0
    $rejectedCount = 0
    $dbWrites = $false
    $adapterRows = @()

    if ($null -eq $selector) { $blockReasons += "real_selector_summary_missing" }
    if (-not $candidateFound) { $blockReasons += "real_selector_candidate_found_false" }
    if ($selectedLane -ne "vod_streams") { $blockReasons += "real_selector_selected_lane_not_vod_streams" }
    if ($selectorNextWorker -ne "apply_vod_streams_delta_limited.ps1") { $blockReasons += "real_selector_next_worker_not_this_worker" }
    if ($plannedImportCount -le 0) { $blockReasons += "vod_preview_planned_import_count_zero" }
    if ($manualReviewCount -gt 0) { $blockReasons += "vod_preview_manual_review_count_gt_zero" }
    if ([string]::IsNullOrWhiteSpace($vodPreviewOutputCsv) -or -not (Test-Path -LiteralPath $vodPreviewOutputCsv)) { $blockReasons += "vod_preview_output_csv_missing" }
    if ([string]::IsNullOrWhiteSpace($sqlTemplateFile) -or -not (Test-Path -LiteralPath $sqlTemplateFile)) { $blockReasons += "sql_template_file_missing" }
    if ([string]::IsNullOrWhiteSpace($parameterCsv) -or -not (Test-Path -LiteralPath $parameterCsv)) { $blockReasons += "parameter_csv_missing" }
    if (-not (Test-Path -LiteralPath $AdapterModulePath)) { $blockReasons += "safe_adapter_module_missing" }

    if (@($blockReasons).Count -eq 0) {
        if ($Apply) {
            $disposition = "blocked_apply_not_implemented_yet"
            $blockReasons += "real_db_apply_not_promoted"
        }
        else {
            Import-Module $AdapterModulePath -Force

            $sqlTemplate = Get-Content -LiteralPath $sqlTemplateFile -Raw
            $parameterRows = @(Import-Csv -LiteralPath $parameterCsv)
            $requiredParameters = @(
                $parameterRows |
                    Where-Object { ([string]$_.required).Trim().ToLowerInvariant() -eq "true" } |
                    ForEach-Object { [string]$_.parameter_name }
            )

            $candidateRows = @(Import-Csv -LiteralPath $vodPreviewOutputCsv | Select-Object -First $Limit)

            foreach ($row in $candidateRows) {
                $parameters = Convert-ToAdapterParameters -Row $row

                $missingRequired = @()
                foreach ($requiredName in $requiredParameters) {
                    if (-not $parameters.ContainsKey($requiredName) -or [string]::IsNullOrWhiteSpace([string]$parameters[$requiredName])) {
                        $missingRequired += $requiredName
                    }
                }

                if (@($missingRequired).Count -gt 0) {
                    $rejectedCount++
                    $adapterRows += [pscustomobject][ordered]@{
                        source_row_disposition = "rejected_missing_required_parameters"
                        adapter_disposition = "not_sent_to_adapter_missing_required_parameters"
                        provider_stream_id = [string]$parameters.provider_stream_id
                        missing_required_parameters = ($missingRequired -join "|")
                        adapter_status = "skipped"
                        db_reads = $false
                        db_writes = $false
                        provider_calls = $false
                    }
                    continue
                }

                $adapterResult = Invoke-MiraDbQuerySafe `
                    -Mode "dry_run" `
                    -Sql $sqlTemplate `
                    -Parameters $parameters `
                    -RequiredParameterNames $requiredParameters `
                    -Limit $Limit

                if ([string]$adapterResult.disposition -eq "dry_run_preview") {
                    $dryRunCount++
                }
                else {
                    $rejectedCount++
                }

                $adapterRows += [pscustomobject][ordered]@{
                    source_row_disposition = "planned_import"
                    adapter_disposition = [string]$adapterResult.disposition
                    provider_stream_id = [string]$parameters.provider_stream_id
                    missing_required_parameters = [string]$adapterResult.missing_parameters
                    adapter_status = [string]$adapterResult.status
                    db_reads = [bool]$adapterResult.db_reads
                    db_writes = [bool]$adapterResult.db_writes
                    provider_calls = [bool]$adapterResult.provider_calls
                }
            }

            $disposition = "dry_run_adapter_preview_completed"
            $wouldWriteCount = $dryRunCount
            $actualWriteCount = 0
            $dbWrites = $false
        }
    }

    $status = "pass"
    if ($disposition -match "^blocked") { $status = "warning" }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $reportCsv = Join-Path $OutputRoot "vod_streams_delta_limited_apply_$timestamp.csv"
    $reportJson = Join-Path $OutputRoot "vod_streams_delta_limited_apply_$timestamp.json"
    $summaryJson = Join-Path $OutputRoot "vod_streams_delta_limited_apply_summary_$timestamp.json"

    if (@($adapterRows).Count -eq 0) {
        $adapterRows += [pscustomobject][ordered]@{
            source_row_disposition = "not_evaluated"
            adapter_disposition = $disposition
            provider_stream_id = ""
            missing_required_parameters = ""
            adapter_status = $status
            db_reads = $false
            db_writes = $false
            provider_calls = $false
        }
    }

    $adapterRows | Export-Csv -Path $reportCsv -NoTypeInformation
    $adapterRows | ConvertTo-Json -Depth 20 | Set-Content -Path $reportJson -Encoding UTF8

    $summary = [ordered]@{
        status = $status
        disposition = $disposition
        dry_run = $dryRun
        apply_requested = [bool]$Apply
        db_writes = $dbWrites
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        candidate_found = $candidateFound
        selected_lane = $selectedLane
        selector_disposition = $selectorDisposition
        selector_next_worker = $selectorNextWorker
        planned_import_count = $plannedImportCount
        source_row_count = $sourceRowCount
        manual_review_count = $manualReviewCount
        skipped_provider_noise_count = $skippedProviderNoiseCount
        dry_run_adapter_count = $dryRunCount
        rejected_count = $rejectedCount
        would_write_count = $wouldWriteCount
        actual_write_count = $actualWriteCount
        block_reasons = $blockReasons
        adapter_module_path = $AdapterModulePath
        sql_template_file = $sqlTemplateFile
        parameter_csv = $parameterCsv
        report_csv = $reportCsv
        report_json = $reportJson
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $status -Payload $summary
    Emit-LocalSignal -SignalName $DispositionSignal -SignalValue $disposition -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $WouldWriteCountSignal -SignalValue $wouldWriteCount -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $ActualWriteCountSignal -SignalValue $actualWriteCount -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: VOD streams limited apply gate evaluated. status=$status disposition=$disposition dry_run=$dryRun adapter_dry_run=$dryRunCount rejected=$rejectedCount would_write=$wouldWriteCount actual_write=$actualWriteCount db_writes=$dbWrites provider_calls=False run_id=$RunId"
        Write-Output "FILES: report_csv=$reportCsv report_json=$reportJson summary_json=$summaryJson"
        Import-Csv $reportCsv | Format-Table -AutoSize
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

    Write-Error "FAILED: VOD streams limited apply gate failed. $message run_id=$RunId"
    exit 1
}
