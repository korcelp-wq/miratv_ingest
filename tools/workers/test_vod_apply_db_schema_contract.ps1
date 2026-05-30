<#
.SYNOPSIS
  Plan and validate the VOD apply DB schema contract.

.DESCRIPTION
  Read-only schema contract planner.

  This worker consumes:
    - latest VOD apply adapter selection summary
    - latest VOD streams apply SQL contract summary

  It emits the exact schema checks a future adapter must pass before any real DB write:
    - target table expected
    - required columns expected
    - key/unique-index strategy expected
    - no destructive operations allowed
    - future DB validation query templates

  This worker does not connect to the database.
  This worker does not read from the database.
  This worker does not write to the database.
  This worker does not call providers.
  This worker does not mutate snapshots.

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

$WorkerName = "test_vod_apply_db_schema_contract"
$Component = "vod_apply_db_schema_contract"
$DatabaseTarget = "xpdgxfsp_content"
$SourceName = "vod_apply_adapter_selection"
$KillSwitchName = "ENABLE_VOD_APPLY_DB_SCHEMA_CONTRACT_TEST"

$CompletedSignal = "vod_apply_db_schema_contract_test_completed"
$DispositionSignal = "vod_apply_db_schema_contract_test_disposition"
$RequiredColumnCountSignal = "vod_apply_db_schema_contract_required_column_count"
$SchemaReadinessSignal = "vod_apply_db_schema_contract_readiness"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\vod_apply_db_schema_contract"
$LogRoot = Join-Path $RepoRoot "runtime\logs\vod_apply_db_schema_contract"

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

function New-ColumnContractRow {
    param(
        [string]$ColumnName,
        [string]$Requirement,
        [string]$MappedParameter,
        [string]$ExpectedPurpose,
        [bool]$Required
    )

    return [pscustomobject][ordered]@{
        column_name = $ColumnName
        requirement = $Requirement
        mapped_parameter = $MappedParameter
        expected_purpose = $ExpectedPurpose
        required_for_first_apply = $Required
        db_writes = $false
        provider_calls = $false
    }
}

try {
    Write-LocalJsonLog -EventName "job_started" -Status "running" -Data ([ordered]@{
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

    $adapterSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_apply_adapter_selection") -Filter "vod_apply_adapter_selection_summary_*.json"
    $sqlContractSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_streams_apply_sql_contract") -Filter "vod_streams_apply_sql_contract_summary_*.json"

    if ($null -eq $adapterSummaryFile) {
        throw "VOD apply adapter selection summary not found. Run plan_vod_apply_adapter_selection.ps1 first."
    }

    if ($null -eq $sqlContractSummaryFile) {
        throw "VOD streams SQL contract summary not found. Run plan_vod_streams_apply_sql_contract.ps1 first."
    }

    $adapterSummary = Read-JsonFile -Path $adapterSummaryFile.FullName
    $sqlContractSummary = Read-JsonFile -Path $sqlContractSummaryFile.FullName

    $selectedAdapter = Get-Text -Object $adapterSummary -Name "selected_adapter" -Default "unknown"
    $adapterReadiness = Get-Text -Object $adapterSummary -Name "readiness" -Default "unknown"
    $adapterReviewRequired = Get-Bool -Object $adapterSummary -Name "review_required" -Default $true

    $targetTable = Get-Text -Object $sqlContractSummary -Name "target_table" -Default "unknown"
    $applyMode = Get-Text -Object $sqlContractSummary -Name "apply_mode" -Default "unknown"
    $parameterCount = Get-Text -Object $sqlContractSummary -Name "parameter_count" -Default "0"

    $columnRows = @(
        New-ColumnContractRow -ColumnName "provider" -Requirement "required" -MappedParameter "provider_label" -ExpectedPurpose "provider namespace / catalog source" -Required $true
        New-ColumnContractRow -ColumnName "provider_vod_id" -Requirement "required" -MappedParameter "provider_stream_id" -ExpectedPurpose "provider VOD identity" -Required $true
        New-ColumnContractRow -ColumnName "category_id" -Requirement "required" -MappedParameter "provider_category_id" -ExpectedPurpose "provider category grouping" -Required $true
        New-ColumnContractRow -ColumnName "title" -Requirement "required" -MappedParameter "title_raw" -ExpectedPurpose "provider display title" -Required $true
        New-ColumnContractRow -ColumnName "updated_at" -Requirement "required" -MappedParameter "CURRENT_TIMESTAMP" -ExpectedPurpose "write/update timestamp" -Required $true
        New-ColumnContractRow -ColumnName "clean_search_name" -Requirement "optional" -MappedParameter "title_clean" -ExpectedPurpose "normalized search title" -Required $false
        New-ColumnContractRow -ColumnName "provider_poster_url" -Requirement "optional" -MappedParameter "stream_icon" -ExpectedPurpose "provider artwork fallback" -Required $false
        New-ColumnContractRow -ColumnName "provider_url" -Requirement "optional" -MappedParameter "provider_url" -ExpectedPurpose "provider playback/details URL metadata" -Required $false
        New-ColumnContractRow -ColumnName "poster_url" -Requirement "optional" -MappedParameter "poster_url" -ExpectedPurpose "enriched poster artwork" -Required $false
        New-ColumnContractRow -ColumnName "cover_url" -Requirement "optional" -MappedParameter "cover_url" -ExpectedPurpose "enriched cover/backdrop artwork" -Required $false
        New-ColumnContractRow -ColumnName "rating" -Requirement "optional" -MappedParameter "rating" -ExpectedPurpose "provider/enriched rating fallback" -Required $false
        New-ColumnContractRow -ColumnName "release_year" -Requirement "optional" -MappedParameter "year" -ExpectedPurpose "release year fallback" -Required $false
        New-ColumnContractRow -ColumnName "duration" -Requirement "optional" -MappedParameter "duration" -ExpectedPurpose "runtime fallback" -Required $false
        New-ColumnContractRow -ColumnName "primary_genre" -Requirement "optional" -MappedParameter "primary_genre" -ExpectedPurpose "primary genre/category grouping" -Required $false
    )

    $uniqueKeyRows = @(
        [pscustomobject][ordered]@{
            key_name = "preferred_unique_vod_provider_identity"
            key_columns = "provider|provider_vod_id"
            required_before_apply = $true
            validation_query_name = "show_unique_indexes_for_vod"
            db_writes = $false
            provider_calls = $false
        }
    )

    $validationQueries = [ordered]@{
        show_columns = "SHOW COLUMNS FROM xpdgxfsp_content.vod;"
        show_indexes = "SHOW INDEX FROM xpdgxfsp_content.vod;"
        check_required_columns = "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = 'xpdgxfsp_content' AND TABLE_NAME = 'vod';"
        check_unique_keys = "SELECT INDEX_NAME, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) AS columns_in_key, NON_UNIQUE FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA = 'xpdgxfsp_content' AND TABLE_NAME = 'vod' GROUP BY INDEX_NAME, NON_UNIQUE;"
    }

    $blockedReasons = @()

    if ($selectedAdapter -ne "new_safe_powershell_db_adapter") {
        $blockedReasons += "selected_adapter_not_new_safe_powershell_db_adapter"
    }

    if ($adapterReadiness -ne "adapter_selected_schema_validation_needed") {
        $blockedReasons += "adapter_readiness_not_schema_validation_needed"
    }

    if ($adapterReviewRequired) {
        $blockedReasons += "adapter_review_required"
    }

    if ($targetTable -ne "xpdgxfsp_content.vod") {
        $blockedReasons += "target_table_not_xpdgxfsp_content_vod"
    }

    if ($applyMode -ne "planned_dry_run_only_until_db_adapter_selected") {
        $blockedReasons += "unexpected_apply_mode"
    }

    $schemaReadiness = "schema_contract_planned_db_validation_needed"
    $status = "pass"
    $disposition = "schema_contract_planned"

    if (@($blockedReasons).Count -gt 0) {
        $status = "warning"
        $disposition = "schema_contract_planned_with_blocks"
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $columnCsv = Join-Path $OutputRoot "vod_apply_db_schema_contract_columns_$timestamp.csv"
    $keyCsv = Join-Path $OutputRoot "vod_apply_db_schema_contract_keys_$timestamp.csv"
    $queryJson = Join-Path $OutputRoot "vod_apply_db_schema_contract_validation_queries_$timestamp.json"
    $contractJson = Join-Path $OutputRoot "vod_apply_db_schema_contract_$timestamp.json"
    $summaryJson = Join-Path $OutputRoot "vod_apply_db_schema_contract_summary_$timestamp.json"

    $columnRows | Export-Csv -Path $columnCsv -NoTypeInformation
    $uniqueKeyRows | Export-Csv -Path $keyCsv -NoTypeInformation
    $validationQueries | ConvertTo-Json -Depth 10 | Set-Content -Path $queryJson -Encoding UTF8

    $contract = [ordered]@{
        contract_name = "vod_apply_db_schema_contract_v1"
        status = $status
        disposition = $disposition
        selected_adapter = $selectedAdapter
        target_table = $targetTable
        schema_readiness = $schemaReadiness
        parameter_count = $parameterCount
        required_columns = @($columnRows | Where-Object { $_.required_for_first_apply -eq $true } | ForEach-Object { $_.column_name })
        optional_columns = @($columnRows | Where-Object { $_.required_for_first_apply -ne $true } | ForEach-Object { $_.column_name })
        required_unique_key = "provider|provider_vod_id"
        validation_queries_file = $queryJson
        blocked_reasons = $blockedReasons
        db_reads = $false
        db_writes = $false
        provider_calls = $false
    }

    $contract | ConvertTo-Json -Depth 20 | Set-Content -Path $contractJson -Encoding UTF8

    $summary = [ordered]@{
        status = $status
        disposition = $disposition
        db_reads = $false
        db_writes = $false
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        selected_adapter = $selectedAdapter
        target_table = $targetTable
        schema_readiness = $schemaReadiness
        required_column_count = @($columnRows | Where-Object { $_.required_for_first_apply -eq $true }).Count
        total_column_count = @($columnRows).Count
        required_unique_key = "provider|provider_vod_id"
        blocked_reasons = $blockedReasons
        adapter_summary_json = $adapterSummaryFile.FullName
        sql_contract_summary_json = $sqlContractSummaryFile.FullName
        column_csv = $columnCsv
        key_csv = $keyCsv
        validation_queries_json = $queryJson
        contract_json = $contractJson
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $status -Payload $summary
    Emit-LocalSignal -SignalName $DispositionSignal -SignalValue $disposition -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $RequiredColumnCountSignal -SignalValue $summary.required_column_count -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $SchemaReadinessSignal -SignalValue $schemaReadiness -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: VOD apply DB schema contract planned. status=$status disposition=$disposition target=$targetTable readiness=$schemaReadiness db_reads=False db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: column_csv=$columnCsv key_csv=$keyCsv validation_queries_json=$queryJson contract_json=$contractJson summary_json=$summaryJson"
        Import-Csv $columnCsv | Format-Table -AutoSize
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

    Write-Error "FAILED: VOD apply DB schema contract test failed. $message run_id=$RunId"
    exit 1
}
