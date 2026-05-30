<#
.SYNOPSIS
  Validate VOD apply DB schema using the promoted safe adapter schema_check path.

.DESCRIPTION
  This worker performs a guarded live schema read for the VOD apply path.

  Safety rules:
    - Requires explicit -AllowDbRead.
    - Uses tools/common/MiraDbSafeAdapter.psm1.
    - Calls Invoke-MiraDbQuerySafe -Mode schema_check -AllowDbRead.
    - Reads schema only.
    - Performs no DB writes.
    - Performs no provider calls.

.CONTRACT-MARKERS
  Write-JobLog
  Emit-Signal
  Emit-WorkerHeartbeat
  vod_apply_db_schema_live_read_completed
  vod_apply_db_schema_live_read_disposition
  vod_apply_db_schema_live_read_schema_valid
  vod_apply_db_schema_live_read_db_read_count
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [switch]$AllowDbRead,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "test_vod_apply_db_schema_live_read"
$Component = "vod_apply_db_schema_live_read"

$CompletedSignal = "vod_apply_db_schema_live_read_completed"
$DispositionSignal = "vod_apply_db_schema_live_read_disposition"
$SchemaValidSignal = "vod_apply_db_schema_live_read_schema_valid"
$DbReadCountSignal = "vod_apply_db_schema_live_read_db_read_count"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\vod_apply_db_schema_live_read"
$LogRoot = Join-Path $RepoRoot "runtime\logs\vod_apply_db_schema_live_read"
$AdapterModulePath = Join-Path $RepoRoot "tools\common\MiraDbSafeAdapter.psm1"

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null

function Get-DurationMs {
    param([datetime]$Start)
    return [int]([Math]::Max(0, ((Get-Date) - $Start).TotalMilliseconds))
}

function Get-LatestFile {
    param(
        [string]$Folder,
        [string]$Filter
    )

    if ([string]::IsNullOrWhiteSpace($Folder)) { return $null }
    if (-not (Test-Path -LiteralPath $Folder)) { return $null }

    return Get-ChildItem -LiteralPath $Folder -Filter $Filter -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
}

function Read-JsonFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-Text {
    param(
        [object]$Object,
        [string]$Name,
        [string]$Default = ""
    )

    if ($null -eq $Object) { return $Default }

    $property = $Object.PSObject.Properties |
        Where-Object { $_.Name -ieq $Name } |
        Select-Object -First 1

    if ($null -eq $property -or $null -eq $property.Value) { return $Default }

    return [string]$property.Value
}

function Get-Bool {
    param(
        [object]$Object,
        [string]$Name,
        [bool]$Default = $false
    )

    if ($null -eq $Object) { return $Default }

    $property = $Object.PSObject.Properties |
        Where-Object { $_.Name -ieq $Name } |
        Select-Object -First 1

    if ($null -eq $property -or $null -eq $property.Value) { return $Default }

    $text = [string]$property.Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }

    return ($text.Trim().ToLowerInvariant() -in @("true", "1", "yes"))
}

function Get-StringArray {
    param(
        [object]$Object,
        [string]$Name,
        [string[]]$Default = @()
    )

    if ($null -eq $Object) { return $Default }

    $property = $Object.PSObject.Properties |
        Where-Object { $_.Name -ieq $Name } |
        Select-Object -First 1

    if ($null -eq $property -or $null -eq $property.Value) { return $Default }

    return @($property.Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-TableShortName {
    param([string]$TableName)

    if ([string]::IsNullOrWhiteSpace($TableName)) { return "vod" }

    $text = $TableName.Trim()
    if ($text -like "*.*") {
        return ($text -split "\.")[-1]
    }

    return $text
}

function Write-LocalJsonLog {
    param(
        [string]$EventName,
        [string]$Status,
        [object]$Data
    )

    $logPath = Join-Path $LogRoot "$WorkerName-$RunId.jsonl"

    $payload = [ordered]@{
        ts_utc = (Get-Date).ToUniversalTime().ToString("o")
        worker_name = $WorkerName
        component = $Component
        environment = $Environment
        event_name = $EventName
        status = $Status
        run_id = $RunId
        data = $Data
    }

    ($payload | ConvertTo-Json -Depth 20 -Compress) | Add-Content -Path $logPath -Encoding UTF8
}

function Emit-LocalSignal {
    param(
        [string]$SignalName,
        [object]$SignalValue,
        [object]$Payload = $null
    )

    $signalRoot = Join-Path $RepoRoot "runtime\signals"
    New-Item -ItemType Directory -Force -Path $signalRoot | Out-Null

    $signalPath = Join-Path $signalRoot "$SignalName.json"

    $signalPayload = [ordered]@{
        ts_utc = (Get-Date).ToUniversalTime().ToString("o")
        signal_name = $SignalName
        signal_value = $SignalValue
        worker_name = $WorkerName
        component = $Component
        environment = $Environment
        run_id = $RunId
        payload = $Payload
    }

    $signalPayload | ConvertTo-Json -Depth 20 | Set-Content -Path $signalPath -Encoding UTF8
}

function Emit-LocalHeartbeat {
    param([string]$Status)

    $heartbeatRoot = Join-Path $RepoRoot "runtime\heartbeats"
    New-Item -ItemType Directory -Force -Path $heartbeatRoot | Out-Null

    $heartbeatPath = Join-Path $heartbeatRoot "$WorkerName.json"

    $heartbeatPayload = [ordered]@{
        ts_utc = (Get-Date).ToUniversalTime().ToString("o")
        worker_name = $WorkerName
        component = $Component
        environment = $Environment
        status = $Status
        run_id = $RunId
    }

    $heartbeatPayload | ConvertTo-Json -Depth 20 | Set-Content -Path $heartbeatPath -Encoding UTF8
}

try {
    Write-LocalJsonLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        allow_db_read = [bool]$AllowDbRead
        db_writes = $false
        provider_calls = $false
        adapter_module_path = $AdapterModulePath
    })

    Emit-LocalHeartbeat -Status "running"

    $gateSummaryFile = Get-LatestFile `
        -Folder (Join-Path $RepoRoot "runtime\reports\vod_schema_validation_execution_gate") `
        -Filter "vod_schema_validation_execution_gate_summary_*.json"

    $schemaContractSummaryFile = Get-LatestFile `
        -Folder (Join-Path $RepoRoot "runtime\reports\vod_apply_db_schema_contract") `
        -Filter "vod_apply_db_schema_contract_summary_*.json"

    $gateSummary = Read-JsonFile -Path $(if ($gateSummaryFile) { $gateSummaryFile.FullName } else { "" })
    $schemaContract = Read-JsonFile -Path $(if ($schemaContractSummaryFile) { $schemaContractSummaryFile.FullName } else { "" })

    $targetTable = Get-Text -Object $schemaContract -Name "target_table" -Default "xpdgxfsp_content.vod"
    $adapterTargetTable = Get-TableShortName -TableName $targetTable
    $requiredUniqueKey = Get-Text -Object $schemaContract -Name "required_unique_key" -Default "provider|provider_vod_id"

    $requiredColumns = Get-StringArray -Object $schemaContract -Name "required_columns" -Default @(
        "provider",
        "provider_vod_id",
        "category_id",
        "title",
        "updated_at"
    )

    if (@($requiredColumns).Count -eq 0) {
        $requiredColumns = @(
            "provider",
            "provider_vod_id",
            "category_id",
            "title",
            "updated_at"
        )
    }

    $optionalColumns = Get-StringArray -Object $schemaContract -Name "optional_columns" -Default @(
        "clean_search_name",
        "provider_poster_url",
        "provider_url",
        "poster_url",
        "cover_url",
        "rating",
        "release_year",
        "duration",
        "primary_genre"
    )

    $status = "warning"
    $disposition = "blocked_requires_explicit_allow_db_read"
    $schemaValid = $false
    $dbReadCount = 0
    $missingColumns = @()
    $keyFound = $false
    $blockers = @()
    $passedChecks = @()

    if ($null -eq $gateSummaryFile) {
        $blockers += "schema_validation_execution_gate_summary_missing"
    }
    else {
        $passedChecks += "schema_validation_execution_gate_summary_present"
    }

    if (-not $AllowDbRead) {
        $blockers += "allow_db_read_not_passed"
    }
    elseif (-not (Test-Path -LiteralPath $AdapterModulePath)) {
        $blockers += "safe_adapter_module_missing"
        $disposition = "blocked_missing_safe_adapter_module"
    }
    else {
        Import-Module $AdapterModulePath -Force
        $passedChecks += "safe_adapter_module_loaded"

        $schemaCheck = Invoke-MiraDbQuerySafe `
            -Mode "schema_check" `
            -AllowDbRead `
            -DatabaseKey "content" `
            -TargetTable $adapterTargetTable `
            -RequiredColumns $requiredColumns `
            -RequiredUniqueKey $requiredUniqueKey

        $schemaCheckDisposition = Get-Text -Object $schemaCheck -Name "disposition" -Default "missing"
        $schemaCheckValid = Get-Bool -Object $schemaCheck -Name "schema_valid" -Default $false
        $schemaCheckDbReads = Get-Bool -Object $schemaCheck -Name "db_reads" -Default $false
        $schemaCheckDbWrites = Get-Bool -Object $schemaCheck -Name "db_writes" -Default $true
        $schemaCheckProviderCalls = Get-Bool -Object $schemaCheck -Name "provider_calls" -Default $true
        $schemaCheckKeyFound = Get-Bool -Object $schemaCheck -Name "key_found" -Default $false

        $dbReadCount = 2

        $missingColumnsText = Get-Text -Object $schemaCheck -Name "missing_required_columns" -Default ""
        if (-not [string]::IsNullOrWhiteSpace($missingColumnsText)) {
            $missingColumns = @($missingColumnsText -split "\|" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }

        $keyFound = $schemaCheckKeyFound

        if ($schemaCheckDisposition -eq "schema_check_validated") {
            $passedChecks += "safe_adapter_schema_check_validated"
        }
        else {
            $blockers += "safe_adapter_schema_check_unexpected_disposition:$schemaCheckDisposition"
        }

        if ($schemaCheckValid) {
            $passedChecks += "required_columns_present"
        }
        else {
            $blockers += "missing_required_columns:" + (($missingColumns) -join ",")
        }

        if ($schemaCheckDbReads -and -not $schemaCheckDbWrites -and -not $schemaCheckProviderCalls) {
            $passedChecks += "safe_adapter_schema_check_read_only"
        }
        else {
            $blockers += "safe_adapter_schema_check_safety_flags_unexpected"
        }

        if ($schemaCheckKeyFound) {
            $passedChecks += "required_identity_index_columns_seen"
        }
        else {
            $blockers += "required_identity_index_columns_not_seen:$requiredUniqueKey"
        }
    }

    if (@($blockers).Count -eq 0) {
        $status = "pass"
        $disposition = "schema_live_read_validated"
        $schemaValid = $true
    }
    elseif ($disposition -eq "blocked_requires_explicit_allow_db_read" -and $AllowDbRead) {
        $disposition = "schema_live_read_completed_with_blocks"
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $reportCsv = Join-Path $OutputRoot "vod_apply_db_schema_live_read_$timestamp.csv"
    $reportJson = Join-Path $OutputRoot "vod_apply_db_schema_live_read_$timestamp.json"
    $summaryJson = Join-Path $OutputRoot "vod_apply_db_schema_live_read_summary_$timestamp.json"

    $row = [pscustomobject][ordered]@{
        disposition = $disposition
        schema_valid = $schemaValid
        allow_db_read = [bool]$AllowDbRead
        db_read_count = $dbReadCount
        db_writes = $false
        provider_calls = $false
        target_table = $targetTable
        adapter_target_table = $adapterTargetTable
        required_unique_key = $requiredUniqueKey
        required_columns = ($requiredColumns -join "|")
        missing_required_columns = ($missingColumns -join "|")
        key_found = $keyFound
        blocker_count = @($blockers).Count
        passed_check_count = @($passedChecks).Count
        blockers = ($blockers -join "|")
        passed_checks = ($passedChecks -join "|")
    }

    $row | Export-Csv -Path $reportCsv -NoTypeInformation -Encoding UTF8
    $row | ConvertTo-Json -Depth 20 | Set-Content -Path $reportJson -Encoding UTF8

    $summary = [ordered]@{
        status = $status
        disposition = $disposition
        schema_valid = $schemaValid
        allow_db_read = [bool]$AllowDbRead
        db_reads = [bool]($dbReadCount -gt 0)
        db_read_count = $dbReadCount
        db_writes = $false
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        target_table = $targetTable
        adapter_target_table = $adapterTargetTable
        required_unique_key = $requiredUniqueKey
        required_columns = $requiredColumns
        optional_columns = $optionalColumns
        missing_required_columns = $missingColumns
        key_found = $keyFound
        blockers = $blockers
        passed_checks = $passedChecks
        gate_summary_json = $(if ($gateSummaryFile) { $gateSummaryFile.FullName } else { "" })
        schema_contract_summary_json = $(if ($schemaContractSummaryFile) { $schemaContractSummaryFile.FullName } else { "" })
        report_csv = $reportCsv
        report_json = $reportJson
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $status -Payload $summary
    Emit-LocalSignal -SignalName $DispositionSignal -SignalValue $disposition -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $SchemaValidSignal -SignalValue $schemaValid -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $DbReadCountSignal -SignalValue $dbReadCount -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: VOD apply DB schema live-read worker completed. status=$status disposition=$disposition schema_valid=$schemaValid allow_db_read=$([bool]$AllowDbRead) db_read_count=$dbReadCount db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: report_csv=$reportCsv report_json=$reportJson summary_json=$summaryJson"
        Import-Csv $reportCsv | Format-List
    }

    if ($status -ne "pass") {
        exit 1
    }

    exit 0
}
catch {
    $message = $_.Exception.Message

    try {
        Emit-LocalHeartbeat -Status "failed"
        Write-LocalJsonLog -EventName "job_failed" -Status "failed" -Data ([ordered]@{
            error = $message
            run_id = $RunId
            db_writes = $false
            provider_calls = $false
        })
    }
    catch {}

    Write-Error "FAILED: VOD apply DB schema live-read worker failed. $message run_id=$RunId"
    exit 1
}