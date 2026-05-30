<#
.SYNOPSIS
  Test VOD apply integration with the Mira DB safe adapter.

.DESCRIPTION
  Fixture-only integration test.

  This worker proves that a mapped VOD apply row can flow through:
    - latest VOD streams SQL contract
    - latest VOD apply mapping fixture
    - tools/common/MiraDbSafeAdapter.psm1
    - dry-run adapter invocation

  It also proves rejected rows are not passed to the adapter.

  No DB connections.
  No DB reads.
  No DB writes.
  No provider calls.
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
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "test_vod_apply_safe_adapter_integration_fixture"
$Component = "vod_apply_safe_adapter_integration_fixture"
$DatabaseTarget = "none"
$SourceName = "vod_streams_apply_mapping_fixture"
$KillSwitchName = "ENABLE_VOD_APPLY_SAFE_ADAPTER_INTEGRATION_FIXTURE_TEST"

$CompletedSignal = "vod_apply_safe_adapter_integration_fixture_completed"
$DispositionSignal = "vod_apply_safe_adapter_integration_fixture_disposition"
$DryRunCountSignal = "vod_apply_safe_adapter_integration_fixture_dry_run_count"
$RejectedCountSignal = "vod_apply_safe_adapter_integration_fixture_rejected_count"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\vod_apply_safe_adapter_integration_fixture"
$LogRoot = Join-Path $RepoRoot "runtime\logs\vod_apply_safe_adapter_integration_fixture"
$ModulePath = Join-Path $RepoRoot "tools\common\MiraDbSafeAdapter.psm1"

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

function Get-Field {
    param([object]$Row, [string]$Name, [string]$Default = "")

    if ($null -eq $Row) { return $Default }

    $property = $Row.PSObject.Properties |
        Where-Object { $_.Name -ieq $Name } |
        Select-Object -First 1

    if ($null -eq $property -or $null -eq $property.Value) { return $Default }

    return [string]$property.Value
}

try {
    Write-LocalJsonLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        fixture_only = $true
        db_reads = $false
        db_writes = $false
        provider_calls = $false
        module_path = $ModulePath
    })

    Emit-LocalHeartbeat -Status "running"

    if (-not (Test-WorkerKillSwitch)) {
        $summary = [ordered]@{
            status = "disabled"
            disposition = "disabled_by_kill_switch"
            fixture_only = $true
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

    if (-not (Test-Path -LiteralPath $ModulePath)) {
        throw "Required module not found: $ModulePath"
    }

    Import-Module $ModulePath -Force

    $contractSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_streams_apply_sql_contract") -Filter "vod_streams_apply_sql_contract_summary_*.json"
    $mappingSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_streams_apply_mapping_fixture") -Filter "vod_streams_apply_mapping_fixture_summary_*.json"

    if ($null -eq $contractSummaryFile) {
        throw "VOD streams SQL contract summary not found. Run plan_vod_streams_apply_sql_contract.ps1 first."
    }

    if ($null -eq $mappingSummaryFile) {
        throw "VOD apply mapping fixture summary not found. Run test_vod_streams_apply_mapping_fixture.ps1 first."
    }

    $contractSummary = Read-JsonFile -Path $contractSummaryFile.FullName
    $mappingSummary = Read-JsonFile -Path $mappingSummaryFile.FullName

    $sqlTemplateFile = Get-Text -Object $contractSummary -Name "sql_template_file" -Default ""
    $parameterCsv = Get-Text -Object $contractSummary -Name "parameter_csv" -Default ""
    $mappingCsv = Get-Text -Object $mappingSummary -Name "report_csv" -Default ""

    if ([string]::IsNullOrWhiteSpace($sqlTemplateFile) -or -not (Test-Path -LiteralPath $sqlTemplateFile)) {
        throw "SQL template file missing: $sqlTemplateFile"
    }

    if ([string]::IsNullOrWhiteSpace($parameterCsv) -or -not (Test-Path -LiteralPath $parameterCsv)) {
        throw "Parameter CSV missing: $parameterCsv"
    }

    if ([string]::IsNullOrWhiteSpace($mappingCsv) -or -not (Test-Path -LiteralPath $mappingCsv)) {
        throw "Mapping CSV missing: $mappingCsv"
    }

    $sqlTemplate = Get-Content -LiteralPath $sqlTemplateFile -Raw
    $parameterRows = @(Import-Csv -LiteralPath $parameterCsv)
    $mappingRows = @(Import-Csv -LiteralPath $mappingCsv)

    $requiredParameters = @(
        $parameterRows |
            Where-Object { ([string]$_.required).Trim().ToLowerInvariant() -eq "true" } |
            ForEach-Object { [string]$_.parameter_name }
    )

    $adapterRows = @()

    foreach ($row in $mappingRows) {
        $rowDisposition = Get-Field -Row $row -Name "row_disposition"
        $providerStreamId = Get-Field -Row $row -Name "provider_stream_id"

        if ($rowDisposition -ne "mapped_preview") {
            $adapterRows += [pscustomobject][ordered]@{
                source_row_disposition = $rowDisposition
                adapter_disposition = "not_sent_to_adapter_source_row_rejected"
                provider_stream_id = $providerStreamId
                adapter_status = "skipped"
                db_reads = $false
                db_writes = $false
                provider_calls = $false
            }
            continue
        }

        $parameters = @{
            mac_user_id = Get-Field -Row $row -Name "mac_user_id"
            provider_label = Get-Field -Row $row -Name "provider_label"
            provider_stream_id = Get-Field -Row $row -Name "provider_stream_id"
            provider_category_id = Get-Field -Row $row -Name "provider_category_id"
            title_raw = Get-Field -Row $row -Name "title_raw"
            title_clean = Get-Field -Row $row -Name "title_clean"
            container_extension = Get-Field -Row $row -Name "container_extension"
            stream_icon = Get-Field -Row $row -Name "stream_icon"
            added = Get-Field -Row $row -Name "added"
            rating = Get-Field -Row $row -Name "rating"
            tmdb_id = Get-Field -Row $row -Name "tmdb_id"
            year = Get-Field -Row $row -Name "year"
        }

        $adapterResult = Invoke-MiraDbQuerySafe `
            -Mode "dry_run" `
            -Sql $sqlTemplate `
            -Parameters $parameters `
            -RequiredParameterNames $requiredParameters `
            -Limit 25

        $adapterRows += [pscustomobject][ordered]@{
            source_row_disposition = $rowDisposition
            adapter_disposition = [string]$adapterResult.disposition
            provider_stream_id = $providerStreamId
            adapter_status = [string]$adapterResult.status
            supplied_parameter_count = [string]$adapterResult.supplied_parameter_count
            sql_is_safe = [string]$adapterResult.sql_is_safe
            parameters_valid = [string]$adapterResult.parameters_valid
            db_reads = [bool]$adapterResult.db_reads
            db_writes = [bool]$adapterResult.db_writes
            provider_calls = [bool]$adapterResult.provider_calls
        }
    }

    $dryRunCount = @($adapterRows | Where-Object { $_.adapter_disposition -eq "dry_run_preview" }).Count
    $rejectedCount = @($adapterRows | Where-Object { $_.adapter_disposition -ne "dry_run_preview" }).Count
    $unexpectedWriteCount = @($adapterRows | Where-Object { $_.db_reads -eq $true -or $_.db_writes -eq $true -or $_.provider_calls -eq $true }).Count

    $status = "pass"
    $disposition = "safe_adapter_integration_fixture_passed"

    if ($dryRunCount -lt 1 -or $unexpectedWriteCount -gt 0) {
        $status = "fail"
        $disposition = "safe_adapter_integration_fixture_failed"
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $reportCsv = Join-Path $OutputRoot "vod_apply_safe_adapter_integration_fixture_$timestamp.csv"
    $reportJson = Join-Path $OutputRoot "vod_apply_safe_adapter_integration_fixture_$timestamp.json"
    $summaryJson = Join-Path $OutputRoot "vod_apply_safe_adapter_integration_fixture_summary_$timestamp.json"

    $adapterRows | Export-Csv -Path $reportCsv -NoTypeInformation
    $adapterRows | ConvertTo-Json -Depth 20 | Set-Content -Path $reportJson -Encoding UTF8

    $summary = [ordered]@{
        status = $status
        disposition = $disposition
        fixture_only = $true
        db_reads = $false
        db_writes = $false
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        module_path = $ModulePath
        contract_summary_json = $contractSummaryFile.FullName
        mapping_summary_json = $mappingSummaryFile.FullName
        sql_template_file = $sqlTemplateFile
        parameter_csv = $parameterCsv
        mapping_csv = $mappingCsv
        total_rows = @($adapterRows).Count
        dry_run_count = $dryRunCount
        rejected_count = $rejectedCount
        unexpected_write_count = $unexpectedWriteCount
        report_csv = $reportCsv
        report_json = $reportJson
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $status -Payload $summary
    Emit-LocalSignal -SignalName $DispositionSignal -SignalValue $disposition -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $DryRunCountSignal -SignalValue $dryRunCount -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $RejectedCountSignal -SignalValue $rejectedCount -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: VOD apply safe adapter integration fixture completed. status=$status disposition=$disposition dry_run=$dryRunCount rejected=$rejectedCount db_reads=False db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: report_csv=$reportCsv report_json=$reportJson summary_json=$summaryJson"
        $adapterRows | Format-Table -AutoSize
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

    Write-Error "FAILED: VOD apply safe adapter integration fixture failed. $message run_id=$RunId"
    exit 1
}
