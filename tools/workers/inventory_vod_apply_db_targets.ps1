<#
.SYNOPSIS
  Inventory candidate VOD apply database targets and write paths.

.DESCRIPTION
  Read-only repository scanner.

  This worker searches PowerShell, SQL, PHP, config, and query files for VOD stream
  import/write target evidence. It helps identify whether the future real apply worker
  should use:
    - a CVI query file
    - a dog_opens wrapper
    - a PHP/server-side endpoint
    - a direct SQL/import wrapper
    - a legacy import script reference

  It does not call providers.
  It does not connect to the database.
  It does not write to the database.
  It does not mutate provider snapshots.

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

$WorkerName = "inventory_vod_apply_db_targets"
$Component = "vod_apply_db_target_inventory"
$DatabaseTarget = "xpdgxfsp_content"
$SourceName = "repo_source_scan"
$KillSwitchName = "ENABLE_VOD_APPLY_DB_TARGET_INVENTORY"

$CompletedSignal = "vod_apply_db_target_inventory_completed"
$CandidateCountSignal = "vod_apply_db_target_inventory_candidate_count"
$HighConfidenceSignal = "vod_apply_db_target_inventory_high_confidence_count"
$ReviewCountSignal = "vod_apply_db_target_inventory_review_count"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\vod_apply_db_target_inventory"
$LogRoot = Join-Path $RepoRoot "runtime\logs\vod_apply_db_target_inventory"

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
    $include = @("*.ps1", "*.psm1", "*.sql", "*.php", "*.json", "*.csv", "*.txt", "*.md", "*.bat", "*.cmd")
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

    if ($text -match "insert\s+into|replace\s+into|update\s+.*set|merge\s+into|upsert") { $kinds += "sql_write_statement" }
    if ($text -match "vod_streams|vod streams|vodstream") { $kinds += "vod_streams_reference" }
    if ($text -match "provider_stream_id|stream_id") { $kinds += "provider_stream_id_reference" }
    if ($text -match "category_id|provider_category_id") { $kinds += "category_reference" }
    if ($text -match "container_extension|movie_image|stream_icon") { $kinds += "vod_field_reference" }
    if ($text -match "dog_opens|dog opens|cvi|query_content|query file|query_file") { $kinds += "query_or_dog_opens_path" }
    if ($text -match "import_vod_streams|vod_streams_delta|provider_snapshot") { $kinds += "import_worker_reference" }
    if ($text -match "\.php|server:|endpoint|curl") { $kinds += "server_or_endpoint_reference" }
    if ($text -match "xpdgxfsp_content|content\.|database") { $kinds += "database_reference" }

    if (@($kinds).Count -eq 0) { return "generic_vod_reference" }
    return ($kinds -join "|")
}

function Get-Confidence {
    param([string]$Kind, [string]$Line, [string]$Path)

    $score = 0
    if ($Kind -match "sql_write_statement") { $score += 40 }
    if ($Kind -match "vod_streams_reference") { $score += 20 }
    if ($Kind -match "provider_stream_id_reference") { $score += 15 }
    if ($Kind -match "query_or_dog_opens_path") { $score += 15 }
    if ($Kind -match "server_or_endpoint_reference") { $score += 10 }
    if ($Kind -match "database_reference") { $score += 10 }
    if ($Path -match "import|query|sql|worker|dog|cvi") { $score += 10 }
    if ($Line -match "INSERT|UPDATE|REPLACE|CALL") { $score += 10 }

    if ($score -ge 60) { return "high" }
    if ($score -ge 35) { return "medium" }
    return "low"
}

function Get-RouteGuess {
    param([string]$Kind, [string]$Path)

    $text = ($Kind + " " + $Path).ToLowerInvariant()

    if ($text -match "dog_opens") { return "dog_opens_wrapper_candidate" }
    if ($text -match "cvi|query_content|query") { return "cvi_query_file_candidate" }
    if ($text -match "\.php|endpoint|server") { return "server_endpoint_candidate" }
    if ($text -match "insert|update|sql") { return "direct_sql_candidate" }
    if ($text -match "import_vod_streams") { return "legacy_import_worker_candidate" }

    return "manual_review"
}

try {
    if ($MaxMatches -lt 1) { $MaxMatches = 500 }
    if ($MaxMatches -gt 5000) { $MaxMatches = 5000 }

    Write-LocalJsonLog -EventName "job_started" -Status "running" -Data ([ordered]@{
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
        "vod_streams",
        "import_vod_streams",
        "provider_stream_id",
        "stream_id",
        "container_extension",
        "movie_image",
        "stream_icon",
        "category_id",
        "dog_opens",
        "query_content",
        "cvi",
        "INSERT INTO",
        "REPLACE INTO",
        "UPDATE ",
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
            $routeGuess = Get-RouteGuess -Kind $kind -Path $match.Path

            $rows += [pscustomobject][ordered]@{
                match_order = @($rows).Count + 1
                confidence = $confidence
                route_guess = $routeGuess
                match_kind = $kind
                file_path = $match.Path
                line_number = $match.LineNumber
                line_text = $match.Line.Trim()
                db_writes = $false
                provider_calls = $false
            }
        }
    }

    $candidateCount = @($rows).Count
    $highConfidenceCount = @($rows | Where-Object { $_.confidence -eq "high" }).Count
    $reviewCount = @($rows | Where-Object { $_.route_guess -eq "manual_review" -or $_.confidence -eq "low" }).Count

    $disposition = "inventory_completed"
    $status = "pass"
    if ($candidateCount -eq 0) {
        $disposition = "no_candidates_found"
        $status = "warning"
    }
    elseif ($highConfidenceCount -eq 0) {
        $disposition = "inventory_completed_no_high_confidence"
        $status = "warning"
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $reportCsv = Join-Path $OutputRoot "vod_apply_db_target_inventory_$timestamp.csv"
    $reportJson = Join-Path $OutputRoot "vod_apply_db_target_inventory_$timestamp.json"
    $summaryJson = Join-Path $OutputRoot "vod_apply_db_target_inventory_summary_$timestamp.json"

    $rows | Export-Csv -Path $reportCsv -NoTypeInformation
    $rows | ConvertTo-Json -Depth 20 | Set-Content -Path $reportJson -Encoding UTF8

    $summary = [ordered]@{
        status = $status
        disposition = $disposition
        db_writes = $false
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        candidate_count = $candidateCount
        high_confidence_count = $highConfidenceCount
        review_count = $reviewCount
        max_matches = $MaxMatches
        include_runtime = [bool]$IncludeRuntime
        report_csv = $reportCsv
        report_json = $reportJson
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $status -Payload $summary
    Emit-LocalSignal -SignalName $CandidateCountSignal -SignalValue $candidateCount -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $HighConfidenceSignal -SignalValue $highConfidenceCount -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $ReviewCountSignal -SignalValue $reviewCount -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: VOD apply DB target inventory completed. status=$status disposition=$disposition candidates=$candidateCount high_confidence=$highConfidenceCount review=$reviewCount db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: report_csv=$reportCsv report_json=$reportJson summary_json=$summaryJson"
        $rows |
            Sort-Object @{Expression = { if ($_.confidence -eq "high") { 0 } elseif ($_.confidence -eq "medium") { 1 } else { 2 } }}, file_path, line_number |
            Select-Object -First 40 confidence, route_guess, match_kind, file_path, line_number, line_text |
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

    Write-Error "FAILED: VOD apply DB target inventory failed. $message run_id=$RunId"
    exit 1
}
