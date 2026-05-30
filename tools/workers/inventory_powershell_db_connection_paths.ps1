<#
.SYNOPSIS
  Inventory PowerShell DB connection and query adapter candidates.

.DESCRIPTION
  Read-only repository scanner.

  This worker searches the repo for existing PowerShell database connection/query
  patterns before the VOD apply adapter is implemented. It helps decide whether to
  reuse an existing DB module/helper or create a small governed adapter.

  It does not connect to the database.
  It does not read from the database.
  It does not write to the database.
  It does not call providers.

.CONTRACT-MARKERS
  Write-JobLog
  Emit-Signal
  Emit-Heartbeat
  Test-KillSwitch
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [int]$MaxMatches = 500,
    [switch]$IncludeRuntime,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "inventory_powershell_db_connection_paths"
$Component = "powershell_db_connection_path_inventory"
$DatabaseTarget = "none"
$SourceName = "repo_source_scan"
$KillSwitchName = "ENABLE_POWERSHELL_DB_CONNECTION_PATH_INVENTORY"

$CompletedSignal = "powershell_db_connection_path_inventory_completed"
$CandidateCountSignal = "powershell_db_connection_path_inventory_candidate_count"
$HighConfidenceSignal = "powershell_db_connection_path_inventory_high_confidence_count"
$SelectedHintSignal = "powershell_db_connection_path_inventory_selected_hint"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\powershell_db_connection_path_inventory"
$LogRoot = Join-Path $RepoRoot "runtime\logs\powershell_db_connection_path_inventory"

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

function Get-SearchFiles {
    $include = @("*.ps1", "*.psm1", "*.psd1", "*.sql", "*.json", "*.xml", "*.config", "*.ini", "*.env", "*.txt", "*.md", "*.bat", "*.cmd")
    $files = @()

    foreach ($pattern in $include) {
        $files += Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -notmatch "\\.git\\" -and
                $_.FullName -notmatch "\\node_modules\\" -and
                $_.FullName -notmatch "\\build\\" -and
                $_.FullName -notmatch "\\runtime\\logs\\" -and
                ($IncludeRuntime -or $_.FullName -notmatch "\\runtime\\")
            }
    }

    return @($files | Sort-Object FullName -Unique)
}

function Get-MatchKind {
    param([string]$Line, [string]$Path)

    $text = ($Line + " " + $Path).ToLowerInvariant()
    $kinds = @()

    if ($text -match "mysql|mariadb|odbc|oledb|mysqlconnection|mysql.data|mysqlconnector") { $kinds += "mysql_connection_reference" }
    if ($text -match "invoke-sql|invoke-mysql|invoke-db|executequery|executenonquery|createcommand|mysqlcommand") { $kinds += "query_execution_reference" }
    if ($text -match "connectionstring|server=.*database|uid=|pwd=|password|db_host|db_user|db_name") { $kinds += "connection_string_reference" }
    if ($text -match "information_schema|show columns|show index|show tables") { $kinds += "schema_validation_reference" }
    if ($text -match "dog_opens|cvi|query_content|query_file|query file") { $kinds += "query_wrapper_reference" }
    if ($text -match "insert into|update .* set|replace into|on duplicate key") { $kinds += "write_sql_reference" }
    if ($text -match "select .* from|select count|from xpdgxfsp") { $kinds += "read_sql_reference" }
    if ($text -match "import-module|using module|tools\\common|tools/common") { $kinds += "module_reference" }

    if (@($kinds).Count -eq 0) { return "generic_db_reference" }
    return ($kinds -join "|")
}

function Get-Confidence {
    param([string]$Kind, [string]$Line, [string]$Path)

    $score = 0
    $text = ($Line + " " + $Path).ToLowerInvariant()

    if ($Kind -match "mysql_connection_reference") { $score += 30 }
    if ($Kind -match "query_execution_reference") { $score += 35 }
    if ($Kind -match "connection_string_reference") { $score += 20 }
    if ($Kind -match "schema_validation_reference") { $score += 25 }
    if ($Kind -match "query_wrapper_reference") { $score += 20 }
    if ($Kind -match "read_sql_reference") { $score += 15 }
    if ($Kind -match "write_sql_reference") { $score += 10 }
    if ($text -match "function\s+invoke|function\s+get-|function\s+new-") { $score += 20 }
    if ($text -match "\.psm1|tools\\common|tools/common") { $score += 20 }
    if ($text -match "runtime\\reports|inventory_powershell_db_connection_paths") { $score -= 80 }

    if ($score -ge 70) { return "high" }
    if ($score -ge 40) { return "medium" }
    return "low"
}

function Get-AdapterHint {
    param([string]$Kind, [string]$Line, [string]$Path)

    $text = ($Line + " " + $Path).ToLowerInvariant()

    if ($text -match "dog_opens|cvi|query_content|query_file") { return "existing_query_wrapper_candidate" }
    if ($text -match "\.psm1|tools\\common|tools/common") { return "existing_module_candidate" }
    if ($text -match "mysqlconnection|mysql.data|mysqlconnector|mysqlcommand") { return "native_mysql_powershell_candidate" }
    if ($text -match "information_schema|show columns|show index") { return "schema_validation_pattern_candidate" }
    if ($text -match "connectionstring|db_host|db_user|db_name") { return "connection_config_candidate" }

    return "manual_review"
}

try {
    if ($MaxMatches -lt 1) { $MaxMatches = 500 }
    if ($MaxMatches -gt 5000) { $MaxMatches = 5000 }

    Write-LocalJsonLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        db_reads = $false
        db_writes = $false
        provider_calls = $false
        max_matches = $MaxMatches
        include_runtime = [bool]$IncludeRuntime
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
        Write-LocalJsonLog -EventName "job_completed" -Status "disabled" -Data $summary
        Write-Output "SKIPPED: $KillSwitchName is disabled. run_id=$RunId"
        exit 0
    }

    $patterns = @(
        "MySql",
        "MariaDB",
        "ODBC",
        "OleDb",
        "ConnectionString",
        "MySqlConnection",
        "MySqlCommand",
        "ExecuteReader",
        "ExecuteNonQuery",
        "Invoke-Sql",
        "Invoke-MySql",
        "Invoke-Db",
        "INFORMATION_SCHEMA",
        "SHOW COLUMNS",
        "SHOW INDEX",
        "dog_opens",
        "query_content",
        "query_file",
        "db_host",
        "db_user",
        "db_name",
        "xpdgxfsp_content"
    )

    $rows = @()
    $files = Get-SearchFiles

    foreach ($file in $files) {
        if (@($rows).Count -ge $MaxMatches) { break }

        try {
            $matches = Select-String -LiteralPath $file.FullName -Pattern $patterns -SimpleMatch -ErrorAction SilentlyContinue
        }
        catch {
            continue
        }

        foreach ($match in @($matches)) {
            if (@($rows).Count -ge $MaxMatches) { break }

            $kind = Get-MatchKind -Line $match.Line -Path $match.Path
            $confidence = Get-Confidence -Kind $kind -Line $match.Line -Path $match.Path
            $adapterHint = Get-AdapterHint -Kind $kind -Line $match.Line -Path $match.Path

            $rows += [pscustomobject][ordered]@{
                match_order = @($rows).Count + 1
                confidence = $confidence
                adapter_hint = $adapterHint
                match_kind = $kind
                file_path = $match.Path
                line_number = $match.LineNumber
                line_text = $match.Line.Trim()
                db_reads = $false
                db_writes = $false
                provider_calls = $false
            }
        }
    }

    $candidateCount = @($rows).Count
    $highConfidenceCount = @($rows | Where-Object { $_.confidence -eq "high" }).Count

    $selectedHint = "manual_review"
    $preferred = $rows |
        Where-Object { $_.confidence -eq "high" -and $_.adapter_hint -in @("existing_module_candidate", "native_mysql_powershell_candidate", "schema_validation_pattern_candidate", "existing_query_wrapper_candidate") } |
        Sort-Object adapter_hint, file_path, line_number |
        Select-Object -First 1

    if ($preferred) {
        $selectedHint = [string]$preferred.adapter_hint
    }
    elseif ($highConfidenceCount -gt 0) {
        $selectedHint = "high_confidence_manual_review"
    }

    $status = "pass"
    $disposition = "inventory_completed"
    if ($candidateCount -eq 0) {
        $status = "warning"
        $disposition = "no_db_connection_candidates_found"
    }
    elseif ($selectedHint -eq "manual_review") {
        $status = "warning"
        $disposition = "inventory_completed_manual_review_needed"
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $reportCsv = Join-Path $OutputRoot "powershell_db_connection_path_inventory_$timestamp.csv"
    $reportJson = Join-Path $OutputRoot "powershell_db_connection_path_inventory_$timestamp.json"
    $summaryJson = Join-Path $OutputRoot "powershell_db_connection_path_inventory_summary_$timestamp.json"

    $rows | Export-Csv -Path $reportCsv -NoTypeInformation
    $rows | ConvertTo-Json -Depth 20 | Set-Content -Path $reportJson -Encoding UTF8

    $summary = [ordered]@{
        status = $status
        disposition = $disposition
        db_reads = $false
        db_writes = $false
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        candidate_count = $candidateCount
        high_confidence_count = $highConfidenceCount
        selected_hint = $selectedHint
        preferred_file = $(if ($preferred) { $preferred.file_path } else { "" })
        preferred_line = $(if ($preferred) { $preferred.line_number } else { "" })
        report_csv = $reportCsv
        report_json = $reportJson
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $status -Payload $summary
    Emit-LocalSignal -SignalName $CandidateCountSignal -SignalValue $candidateCount -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $HighConfidenceSignal -SignalValue $highConfidenceCount -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $SelectedHintSignal -SignalValue $selectedHint -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: PowerShell DB connection path inventory completed. status=$status disposition=$disposition candidates=$candidateCount high_confidence=$highConfidenceCount selected_hint=$selectedHint db_reads=False db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: report_csv=$reportCsv report_json=$reportJson summary_json=$summaryJson"
        $rows |
            Sort-Object @{Expression = { if ($_.confidence -eq "high") { 0 } elseif ($_.confidence -eq "medium") { 1 } else { 2 } }}, adapter_hint, file_path, line_number |
            Select-Object -First 50 confidence, adapter_hint, match_kind, file_path, line_number, line_text |
            Format-Table -AutoSize
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

    Write-Error "FAILED: PowerShell DB connection path inventory failed. $message run_id=$RunId"
    exit 1
}
