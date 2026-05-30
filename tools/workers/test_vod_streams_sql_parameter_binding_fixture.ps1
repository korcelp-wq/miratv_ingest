<#
.SYNOPSIS
  Test VOD streams apply SQL parameter binding using fixture rows.

.DESCRIPTION
  Fixture-only SQL parameter binding validator.

  This worker consumes:
    - latest VOD streams apply SQL contract
    - latest VOD streams apply mapping fixture report

  It validates:
    - required parameters are present for mapped rows
    - rejected rows are not bindable
    - parameter names align with the SQL contract
    - blank provider values are flagged before any future DB adapter work

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
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "test_vod_streams_sql_parameter_binding_fixture"
$Component = "vod_streams_sql_parameter_binding_fixture"
$DatabaseTarget = "xpdgxfsp_content"
$SourceName = "vod_streams_apply_sql_contract"
$KillSwitchName = "ENABLE_VOD_STREAMS_SQL_PARAMETER_BINDING_FIXTURE_TEST"

$CompletedSignal = "vod_streams_sql_parameter_binding_fixture_completed"
$DispositionSignal = "vod_streams_sql_parameter_binding_fixture_disposition"
$BindableCountSignal = "vod_streams_sql_parameter_binding_fixture_bindable_count"
$RejectedCountSignal = "vod_streams_sql_parameter_binding_fixture_rejected_count"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\vod_streams_sql_parameter_binding_fixture"
$LogRoot = Join-Path $RepoRoot "runtime\logs\vod_streams_sql_parameter_binding_fixture"

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
        db_writes = $false
        provider_calls = $false
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

    $contractSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_streams_apply_sql_contract") -Filter "vod_streams_apply_sql_contract_summary_*.json"
    if ($null -eq $contractSummaryFile) {
        throw "SQL contract summary not found. Run plan_vod_streams_apply_sql_contract.ps1 first."
    }

    $contractSummary = Read-JsonFile -Path $contractSummaryFile.FullName
    $parameterCsv = Get-Text -Object $contractSummary -Name "parameter_csv" -Default ""
    $fixtureSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_streams_apply_mapping_fixture") -Filter "vod_streams_apply_mapping_fixture_summary_*.json"
    if ($null -eq $fixtureSummaryFile) {
        throw "Mapping fixture summary not found. Run test_vod_streams_apply_mapping_fixture.ps1 first."
    }

    $fixtureSummary = Read-JsonFile -Path $fixtureSummaryFile.FullName
    $fixtureReportCsv = Get-Text -Object $fixtureSummary -Name "report_csv" -Default ""

    if ([string]::IsNullOrWhiteSpace($parameterCsv) -or -not (Test-Path -LiteralPath $parameterCsv)) {
        throw "SQL contract parameter CSV missing: $parameterCsv"
    }

    if ([string]::IsNullOrWhiteSpace($fixtureReportCsv) -or -not (Test-Path -LiteralPath $fixtureReportCsv)) {
        throw "Mapping fixture report CSV missing: $fixtureReportCsv"
    }

    $parameterRows = @(Import-Csv -LiteralPath $parameterCsv)
    $fixtureRows = @(Import-Csv -LiteralPath $fixtureReportCsv)

    $requiredParameters = @($parameterRows | Where-Object { ([string]$_.required).Trim().ToLowerInvariant() -eq "true" } | ForEach-Object { [string]$_.parameter_name })
    $allParameters = @($parameterRows | ForEach-Object { [string]$_.parameter_name })

    $bindingRows = @()

    foreach ($row in $fixtureRows) {
        $rowDisposition = Get-Field -Row $row -Name "row_disposition"
        $missing = @()
        $blankOptional = @()

        foreach ($parameter in $requiredParameters) {
            $value = Get-Field -Row $row -Name $parameter -Default ""
            if ([string]::IsNullOrWhiteSpace($value)) {
                $missing += $parameter
            }
        }

        foreach ($parameter in $allParameters) {
            if ($parameter -in $requiredParameters) { continue }
            $value = Get-Field -Row $row -Name $parameter -Default ""
            if ([string]::IsNullOrWhiteSpace($value)) {
                $blankOptional += $parameter
            }
        }

        $bindingDisposition = "bindable_preview"
        if ($rowDisposition -ne "mapped_preview") {
            $bindingDisposition = "not_bindable_source_row_rejected"
        }
        elseif (@($missing).Count -gt 0) {
            $bindingDisposition = "not_bindable_missing_required_parameters"
        }

        $bindingRows += [pscustomobject][ordered]@{
            binding_disposition = $bindingDisposition
            source_row_disposition = $rowDisposition
            provider_stream_id = Get-Field -Row $row -Name "provider_stream_id"
            provider_category_id = Get-Field -Row $row -Name "provider_category_id"
            title_raw = Get-Field -Row $row -Name "title_raw"
            required_parameters_missing = ($missing -join "|")
            optional_parameters_blank = ($blankOptional -join "|")
            parameter_count = @($allParameters).Count
            required_parameter_count = @($requiredParameters).Count
            db_writes = $false
            provider_calls = $false
            fixture_only = $true
        }
    }

    $bindableCount = @($bindingRows | Where-Object { $_.binding_disposition -eq "bindable_preview" }).Count
    $rejectedCount = @($bindingRows | Where-Object { $_.binding_disposition -ne "bindable_preview" }).Count

    $status = "pass"
    $disposition = "parameter_binding_fixture_passed"
    if ($rejectedCount -gt 0) {
        $status = "warning"
        $disposition = "parameter_binding_fixture_passed_with_expected_rejections"
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $bindingCsv = Join-Path $OutputRoot "vod_streams_sql_parameter_binding_fixture_$timestamp.csv"
    $bindingJson = Join-Path $OutputRoot "vod_streams_sql_parameter_binding_fixture_$timestamp.json"
    $summaryJson = Join-Path $OutputRoot "vod_streams_sql_parameter_binding_fixture_summary_$timestamp.json"

    $bindingRows | Export-Csv -Path $bindingCsv -NoTypeInformation
    $bindingRows | ConvertTo-Json -Depth 20 | Set-Content -Path $bindingJson -Encoding UTF8

    $summary = [ordered]@{
        status = $status
        disposition = $disposition
        fixture_only = $true
        db_writes = $false
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        contract_summary_json = $contractSummaryFile.FullName
        parameter_csv = $parameterCsv
        fixture_summary_json = $fixtureSummaryFile.FullName
        fixture_report_csv = $fixtureReportCsv
        total_rows = @($bindingRows).Count
        bindable_count = $bindableCount
        rejected_count = $rejectedCount
        binding_csv = $bindingCsv
        binding_json = $bindingJson
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $status -Payload $summary
    Emit-LocalSignal -SignalName $DispositionSignal -SignalValue $disposition -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $BindableCountSignal -SignalValue $bindableCount -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $RejectedCountSignal -SignalValue $rejectedCount -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: VOD streams SQL parameter binding fixture completed. status=$status disposition=$disposition bindable=$bindableCount rejected=$rejectedCount db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: binding_csv=$bindingCsv binding_json=$bindingJson summary_json=$summaryJson"
        $bindingRows | Format-Table -AutoSize
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

    Write-Error "FAILED: VOD streams SQL parameter binding fixture failed. $message run_id=$RunId"
    exit 1
}
