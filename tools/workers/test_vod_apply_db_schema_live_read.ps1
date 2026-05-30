<#
.SYNOPSIS
  Validate VOD apply DB schema with optional explicit DB-read-only execution.

.DESCRIPTION
  DB-read guarded schema validation worker.

  Default behavior:
    - No DB connection
    - No DB reads
    - No DB writes
    - Emits blocked_requires_explicit_allow_db_read

  Promoted read-only behavior:
    - Requires -AllowDbRead
    - Requires mysql.exe available in PATH
    - Requires environment variables:
        MIRATV_DB_HOST
        MIRATV_DB_PORT
        MIRATV_DB_USER
        MIRATV_DB_PASSWORD
        MIRATV_DB_NAME
    - Runs read-only schema queries only:
        SHOW COLUMNS FROM xpdgxfsp_content.vod
        SHOW INDEX FROM xpdgxfsp_content.vod
    - Writes only runtime reports
    - Never writes to DB
    - Never calls provider

.CONTRACT-MARKERS
  Write-JobLog
  Emit-Signal
  Emit-Heartbeat
  Test-KillSwitch
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
$DatabaseTarget = "xpdgxfsp_content"
$SourceName = "vod_schema_validation_execution_gate"
$KillSwitchName = "ENABLE_VOD_APPLY_DB_SCHEMA_LIVE_READ_TEST"

$CompletedSignal = "vod_apply_db_schema_live_read_completed"
$DispositionSignal = "vod_apply_db_schema_live_read_disposition"
$DbReadCountSignal = "vod_apply_db_schema_live_read_db_read_count"
$SchemaValidSignal = "vod_apply_db_schema_live_read_schema_valid"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\vod_apply_db_schema_live_read"
$LogRoot = Join-Path $RepoRoot "runtime\logs\vod_apply_db_schema_live_read"

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

function Get-DbEnv {
    $required = @(
        "MIRATV_DB_HOST",
        "MIRATV_DB_PORT",
        "MIRATV_DB_USER",
        "MIRATV_DB_PASSWORD",
        "MIRATV_DB_NAME"
    )

    $missing = @()
    $values = @{}

    foreach ($name in $required) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ([string]::IsNullOrWhiteSpace($value)) {
            $missing += $name
        }
        else {
            $values[$name] = $value
        }
    }

    return [pscustomobject][ordered]@{
        missing = $missing
        values = $values
    }
}

function Invoke-MySqlReadOnlyQuery {
    param(
        [hashtable]$Db,
        [string]$Query
    )

    $mysql = Get-Command "mysql.exe" -ErrorAction SilentlyContinue
    if ($null -eq $mysql) {
        throw "mysql.exe not found in PATH"
    }

    $args = @(
        "--host=$($Db["MIRATV_DB_HOST"])",
        "--port=$($Db["MIRATV_DB_PORT"])",
        "--user=$($Db["MIRATV_DB_USER"])",
        "--password=$($Db["MIRATV_DB_PASSWORD"])",
        "--database=$($Db["MIRATV_DB_NAME"])",
        "--batch",
        "--raw",
        "--skip-column-names",
        "--execute=$Query"
    )

    $output = & $mysql.Source @args 2>&1
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) { $exitCode = 0 }

    return [pscustomobject][ordered]@{
        exit_code = $exitCode
        output = ($output | ForEach-Object { [string]$_ }) -join "`n"
    }
}

try {
    Write-LocalJsonLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        allow_db_read = [bool]$AllowDbRead
        db_writes = $false
        provider_calls = $false
    })

    Emit-LocalHeartbeat -Status "running"

    if (-not (Test-WorkerKillSwitch)) {
        $summary = [ordered]@{
            status = "disabled"
            disposition = "disabled_by_kill_switch"
            schema_valid = $false
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

    $gateSummaryFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_schema_validation_execution_gate") -Filter "vod_schema_validation_execution_gate_summary_*.json"
    $schemaContractFile = Get-LatestFile -Folder (Join-Path $RepoRoot "runtime\reports\vod_apply_db_schema_contract") -Filter "vod_apply_db_schema_contract_summary_*.json"

    $gateSummary = Read-JsonFile -Path $(if ($gateSummaryFile) { $gateSummaryFile.FullName } else { "" })
    $schemaContract = Read-JsonFile -Path $(if ($schemaContractFile) { $schemaContractFile.FullName } else { "" })

    $targetTable = Get-Text -Object $schemaContract -Name "target_table" -Default "xpdgxfsp_content.vod"
    $requiredUniqueKey = Get-Text -Object $schemaContract -Name "required_unique_key" -Default "mac_user_id|provider_label|provider_stream_id"

    $requiredColumns = @(
        "mac_user_id",
        "provider_label",
        "provider_stream_id",
        "provider_category_id",
        "name",
        "updated_at"
    )

    $optionalColumns = @(
        "clean_search_name",
        "container_extension",
        "stream_icon",
        "added",
        "rating",
        "tmdb_id",
        "year"
    )

    $status = "warning"
    $disposition = "blocked_requires_explicit_allow_db_read"
    $schemaValid = $false
    $dbReadCount = 0
    $columnsFound = @()
    $indexesFound = @()
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
    else {
        $dbEnv = Get-DbEnv
        if (@($dbEnv.missing).Count -gt 0) {
            $blockers += "missing_db_env:" + (($dbEnv.missing) -join ",")
            $disposition = "blocked_missing_db_env"
        }
        else {
            $passedChecks += "db_env_present"

            $columnQuery = "SHOW COLUMNS FROM xpdgxfsp_content.vod;"
            $indexQuery = "SHOW INDEX FROM xpdgxfsp_content.vod;"

            $columnResult = Invoke-MySqlReadOnlyQuery -Db $dbEnv.values -Query $columnQuery
            $dbReadCount++

            if ($columnResult.exit_code -ne 0) {
                $blockers += "show_columns_query_failed"
            }
            else {
                $columnsFound = @(
                    $columnResult.output -split "`n" |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        ForEach-Object { ($_ -split "`t")[0] }
                )
                $passedChecks += "show_columns_query_passed"
            }

            $indexResult = Invoke-MySqlReadOnlyQuery -Db $dbEnv.values -Query $indexQuery
            $dbReadCount++

            if ($indexResult.exit_code -ne 0) {
                $blockers += "show_index_query_failed"
            }
            else {
                $indexesFound = @(
                    $indexResult.output -split "`n" |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                )
                $passedChecks += "show_index_query_passed"
            }

            foreach ($column in $requiredColumns) {
                if ($column -notin $columnsFound) {
                    $missingColumns += $column
                }
            }

            if (@($missingColumns).Count -eq 0) {
                $passedChecks += "required_columns_present"
            }
            else {
                $blockers += "missing_required_columns:" + (($missingColumns) -join ",")
            }

            $keyText = ($indexesFound -join "`n").ToLowerInvariant()
            if ($keyText -match "mac_user_id" -and $keyText -match "provider_label" -and $keyText -match "provider_stream_id") {
                $keyFound = $true
                $passedChecks += "required_identity_index_columns_seen"
            }
            else {
                $blockers += "required_identity_index_columns_not_seen"
            }

            if (@($blockers).Count -eq 0) {
                $status = "pass"
                $disposition = "schema_live_read_validated"
                $schemaValid = $true
            }
            else {
                $status = "warning"
                $disposition = "schema_live_read_completed_with_blocks"
            }
        }
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
        required_unique_key = $requiredUniqueKey
        required_columns = ($requiredColumns -join "|")
        missing_required_columns = ($missingColumns -join "|")
        key_found = $keyFound
        blocker_count = @($blockers).Count
        passed_check_count = @($passedChecks).Count
        blockers = ($blockers -join "|")
        passed_checks = ($passedChecks -join "|")
    }

    $row | Export-Csv -Path $reportCsv -NoTypeInformation
    $row | ConvertTo-Json -Depth 20 | Set-Content -Path $reportJson -Encoding UTF8

    $summary = [ordered]@{
        status = $status
        disposition = $disposition
        schema_valid = $schemaValid
        allow_db_read = [bool]$AllowDbRead
        db_reads = ($dbReadCount -gt 0)
        db_read_count = $dbReadCount
        db_writes = $false
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        target_table = $targetTable
        required_unique_key = $requiredUniqueKey
        required_columns = $requiredColumns
        optional_columns = $optionalColumns
        missing_required_columns = $missingColumns
        key_found = $keyFound
        blockers = $blockers
        passed_checks = $passedChecks
        gate_summary_json = $(if ($gateSummaryFile) { $gateSummaryFile.FullName } else { "" })
        schema_contract_summary_json = $(if ($schemaContractFile) { $schemaContractFile.FullName } else { "" })
        report_csv = $reportCsv
        report_json = $reportJson
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $status -Payload $summary
    Emit-LocalSignal -SignalName $DispositionSignal -SignalValue $disposition -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $DbReadCountSignal -SignalValue $dbReadCount -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $SchemaValidSignal -SignalValue $schemaValid -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: VOD apply DB schema live-read worker completed. status=$status disposition=$disposition schema_valid=$schemaValid allow_db_read=$([bool]$AllowDbRead) db_read_count=$dbReadCount db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: report_csv=$reportCsv report_json=$reportJson summary_json=$summaryJson"
        Import-Csv $reportCsv | Format-List
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

    Write-Error "FAILED: VOD apply DB schema live-read worker failed. $message run_id=$RunId"
    exit 1
}
