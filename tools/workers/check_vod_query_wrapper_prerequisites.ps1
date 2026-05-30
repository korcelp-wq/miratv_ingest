<#
.SYNOPSIS
  Check VOD query-wrapper DB-read prerequisites.

.DESCRIPTION
  Repository/local prerequisite checker for the existing DB access path.

  This worker intentionally does NOT use mysql.exe.

  It checks for:
    - query.ps1 candidates
    - dog_opens / dog opens references
    - CVI/query file references
    - likely DB query wrapper patterns
    - safe next-step guidance for schema validation through the existing wrapper path

  It does not connect to DB.
  It does not read DB.
  It does not write DB.
  It does not call providers.
  It does not print secrets.

.CONTRACT-MARKERS
  Write-JobLog
  Emit-Signal
  Emit-Heartbeat
  Test-KillSwitch
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [int]$MaxMatches = 250,
    [switch]$IncludeRuntime,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "check_vod_query_wrapper_prerequisites"
$Component = "vod_query_wrapper_prerequisites"
$DatabaseTarget = "xpdgxfsp_content"
$SourceName = "repo_query_wrapper_scan"
$KillSwitchName = "ENABLE_VOD_QUERY_WRAPPER_PREREQUISITES_CHECK"

$CompletedSignal = "vod_query_wrapper_prerequisites_check_completed"
$DispositionSignal = "vod_query_wrapper_prerequisites_check_disposition"
$QueryWrapperFoundSignal = "vod_query_wrapper_prerequisites_query_wrapper_found"
$DogOpensFoundSignal = "vod_query_wrapper_prerequisites_dog_opens_found"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\vod_query_wrapper_prerequisites"
$LogRoot = Join-Path $RepoRoot "runtime\logs\vod_query_wrapper_prerequisites"

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
    $include = @("*.ps1", "*.psm1", "*.psd1", "*.sql", "*.json", "*.csv", "*.txt", "*.md", "*.bat", "*.cmd")
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

    if ($text -match "query\.ps1") { $kinds += "query_ps1_reference" }
    if ($text -match "dog_opens|dog opens|dogopen") { $kinds += "dog_opens_reference" }
    if ($text -match "cvi|query_content|query_file|query file") { $kinds += "cvi_or_query_file_reference" }
    if ($text -match "show columns|show index|information_schema") { $kinds += "schema_query_reference" }
    if ($text -match "xpdgxfsp_content|xpdgxfsp") { $kinds += "database_target_reference" }
    if ($text -match "insert into|update .* set|replace into|on duplicate key") { $kinds += "write_sql_reference" }
    if ($text -match "select .* from|show .* from") { $kinds += "read_sql_reference" }
    if ($text -match "vod|vod_streams|provider_stream_id") { $kinds += "vod_reference" }

    if (@($kinds).Count -eq 0) { return "generic_wrapper_reference" }
    return ($kinds -join "|")
}

function Get-Confidence {
    param([string]$Kind, [string]$Line, [string]$Path)

    $score = 0
    $text = ($Line + " " + $Path).ToLowerInvariant()

    if ($Kind -match "query_ps1_reference") { $score += 40 }
    if ($Kind -match "dog_opens_reference") { $score += 40 }
    if ($Kind -match "cvi_or_query_file_reference") { $score += 25 }
    if ($Kind -match "schema_query_reference") { $score += 25 }
    if ($Kind -match "database_target_reference") { $score += 15 }
    if ($Kind -match "vod_reference") { $score += 10 }
    if ($Path -match "query\.ps1$") { $score += 60 }
    if ($Path -match "dog|query|cvi|database|db") { $score += 15 }
    if ($text -match "runtime\\reports|check_vod_query_wrapper_prerequisites") { $score -= 80 }

    if ($score -ge 70) { return "high" }
    if ($score -ge 40) { return "medium" }
    return "low"
}

function Get-RouteHint {
    param([string]$Kind, [string]$Line, [string]$Path)

    $text = ($Line + " " + $Path).ToLowerInvariant()

    if ($Path.ToLowerInvariant() -match "query\.ps1$") { return "query_ps1_file" }
    if ($Kind -match "query_ps1_reference") { return "query_ps1_reference" }
    if ($Kind -match "dog_opens_reference") { return "dog_opens_reference" }
    if ($Kind -match "cvi_or_query_file_reference") { return "cvi_or_query_file_reference" }
    if ($Kind -match "schema_query_reference") { return "schema_query_reference" }

    return "manual_review"
}

try {
    if ($MaxMatches -lt 1) { $MaxMatches = 250 }
    if ($MaxMatches -gt 5000) { $MaxMatches = 5000 }

    Write-LocalJsonLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        max_matches = $MaxMatches
        include_runtime = [bool]$IncludeRuntime
        db_reads = $false
        db_writes = $false
        provider_calls = $false
        secrets_printed = $false
        mysql_required = $false
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

    $patterns = @(
        "query.ps1",
        "dog_opens",
        "dog opens",
        "dogopen",
        "query_content",
        "query_file",
        "query file",
        "CVI",
        "SHOW COLUMNS",
        "SHOW INDEX",
        "INFORMATION_SCHEMA",
        "xpdgxfsp_content",
        "provider_stream_id",
        "vod_streams"
    )

    $rows = @()
    $files = Get-SearchFiles

    foreach ($file in $files) {
        if (@($rows).Count -ge $MaxMatches) { break }

        if ($file.Name -ieq "query.ps1") {
            $rows += [pscustomobject][ordered]@{
                match_order = @($rows).Count + 1
                confidence = "high"
                route_hint = "query_ps1_file"
                match_kind = "query_ps1_file"
                file_path = $file.FullName
                line_number = 0
                line_text = "query.ps1 file found"
                db_reads = $false
                db_writes = $false
                provider_calls = $false
                secrets_printed = $false
            }
        }

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
            $routeHint = Get-RouteHint -Kind $kind -Line $match.Line -Path $match.Path

            $safeLine = $match.Line.Trim()
            if ($safeLine.Length -gt 240) {
                $safeLine = $safeLine.Substring(0, 240)
            }

            $rows += [pscustomobject][ordered]@{
                match_order = @($rows).Count + 1
                confidence = $confidence
                route_hint = $routeHint
                match_kind = $kind
                file_path = $match.Path
                line_number = $match.LineNumber
                line_text = $safeLine
                db_reads = $false
                db_writes = $false
                provider_calls = $false
                secrets_printed = $false
            }
        }
    }

    $queryWrapperFound = @($rows | Where-Object { $_.route_hint -match "query_ps1" }).Count -gt 0
    $dogOpensFound = @($rows | Where-Object { $_.route_hint -eq "dog_opens_reference" }).Count -gt 0
    $cviFound = @($rows | Where-Object { $_.route_hint -eq "cvi_or_query_file_reference" }).Count -gt 0
    $schemaQueryFound = @($rows | Where-Object { $_.route_hint -eq "schema_query_reference" }).Count -gt 0
    $highConfidenceCount = @($rows | Where-Object { $_.confidence -eq "high" }).Count

    $canonicalRoute = "manual_review"
    if ($queryWrapperFound -and $dogOpensFound) {
        $canonicalRoute = "query_ps1_plus_dog_opens"
    }
    elseif ($queryWrapperFound) {
        $canonicalRoute = "query_ps1"
    }
    elseif ($dogOpensFound) {
        $canonicalRoute = "dog_opens"
    }
    elseif ($cviFound) {
        $canonicalRoute = "cvi_or_query_file"
    }

    $status = "pass"
    $disposition = "query_wrapper_prerequisites_ready"

    if ($canonicalRoute -eq "manual_review") {
        $status = "warning"
        $disposition = "query_wrapper_prerequisites_need_manual_review"
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $reportCsv = Join-Path $OutputRoot "vod_query_wrapper_prerequisites_$timestamp.csv"
    $reportJson = Join-Path $OutputRoot "vod_query_wrapper_prerequisites_$timestamp.json"
    $summaryJson = Join-Path $OutputRoot "vod_query_wrapper_prerequisites_summary_$timestamp.json"
    $nextPlanTxt = Join-Path $OutputRoot "vod_query_wrapper_prerequisites_next_plan_$timestamp.txt"

    $rows | Export-Csv -Path $reportCsv -NoTypeInformation
    $rows | ConvertTo-Json -Depth 20 | Set-Content -Path $reportJson -Encoding UTF8

    @"
Next step should NOT use mysql.exe.

Next worker to build:
  plan_vod_schema_validation_query_wrapper_gate.ps1

Purpose:
  Use the existing query.ps1 / dog_opens / CVI query route to plan a DB-read-only schema validation command.

Required constraints:
  - DB reads only after explicit allow flag
  - DB writes forbidden
  - Provider calls forbidden
  - No secrets printed
  - Validate xpdgxfsp_content.vod columns
  - Validate key/identity strategy: mac_user_id|provider_label|provider_stream_id

Detected canonical route:
  $canonicalRoute
"@ | Set-Content -Path $nextPlanTxt -Encoding UTF8

    $summary = [ordered]@{
        status = $status
        disposition = $disposition
        canonical_route = $canonicalRoute
        query_wrapper_found = $queryWrapperFound
        dog_opens_found = $dogOpensFound
        cvi_found = $cviFound
        schema_query_found = $schemaQueryFound
        candidate_count = @($rows).Count
        high_confidence_count = $highConfidenceCount
        mysql_required = $false
        db_reads = $false
        db_writes = $false
        provider_calls = $false
        secrets_printed = $false
        worker_name = $WorkerName
        run_id = $RunId
        report_csv = $reportCsv
        report_json = $reportJson
        next_plan_txt = $nextPlanTxt
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $status -Payload $summary
    Emit-LocalSignal -SignalName $DispositionSignal -SignalValue $disposition -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $QueryWrapperFoundSignal -SignalValue $queryWrapperFound -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $DogOpensFoundSignal -SignalValue $dogOpensFound -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: VOD query-wrapper prerequisites checked. status=$status disposition=$disposition canonical_route=$canonicalRoute query_wrapper_found=$queryWrapperFound dog_opens_found=$dogOpensFound db_reads=False db_writes=False provider_calls=False mysql_required=False run_id=$RunId"
        Write-Output "FILES: report_csv=$reportCsv report_json=$reportJson next_plan_txt=$nextPlanTxt summary_json=$summaryJson"
        $rows |
            Sort-Object @{Expression = { if ($_.confidence -eq "high") { 0 } elseif ($_.confidence -eq "medium") { 1 } else { 2 } }}, route_hint, file_path, line_number |
            Select-Object -First 50 confidence, route_hint, match_kind, file_path, line_number, line_text |
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

    Write-Error "FAILED: VOD query-wrapper prerequisites check failed. $message run_id=$RunId"
    exit 1
}
