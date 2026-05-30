<#
.SYNOPSIS
  Inspect query.ps1 / dog_opens invocation shape for VOD schema validation.

.DESCRIPTION
  Read-only repository inspector.

  This worker inspects candidate query.ps1 and dog_opens usage patterns so the
  next schema validation worker can call the existing DB wrapper correctly.

  It does not execute query.ps1.
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
    [int]$MaxFiles = 100,
    [switch]$IncludeRuntime,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "inspect_query_wrapper_invocation_shape"
$Component = "query_wrapper_invocation_shape"
$DatabaseTarget = "xpdgxfsp_content"
$SourceName = "repo_query_wrapper_scan"
$KillSwitchName = "ENABLE_QUERY_WRAPPER_INVOCATION_SHAPE_INSPECTOR"

$CompletedSignal = "query_wrapper_invocation_shape_inspected_completed"
$DispositionSignal = "query_wrapper_invocation_shape_inspected_disposition"
$QueryPs1CountSignal = "query_wrapper_invocation_shape_query_ps1_count"
$InvocationPatternCountSignal = "query_wrapper_invocation_shape_pattern_count"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\query_wrapper_invocation_shape"
$LogRoot = Join-Path $RepoRoot "runtime\logs\query_wrapper_invocation_shape"

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
    $include = @("*.ps1", "*.psm1", "*.bat", "*.cmd", "*.md", "*.txt", "*.json", "*.csv")
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

    return @($files | Sort-Object FullName -Unique | Select-Object -First $MaxFiles)
}

function Get-SafeLine {
    param([string]$Line)

    if ($null -eq $Line) { return "" }

    $safe = $Line.Trim()

    # Avoid surfacing likely secret literals. Keep shape, not values.
    $safe = $safe -replace '(?i)(password|passwd|pwd|token|secret|key)\s*=\s*["''][^"'']+["'']', '$1=<redacted>'
    $safe = $safe -replace '(?i)(password|passwd|pwd|token|secret|key)\s*:\s*["''][^"'']+["'']', '$1:<redacted>'

    if ($safe.Length -gt 300) {
        return $safe.Substring(0, 300)
    }

    return $safe
}

try {
    if ($MaxFiles -lt 1) { $MaxFiles = 100 }
    if ($MaxFiles -gt 1000) { $MaxFiles = 1000 }

    Write-LocalJsonLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        max_files = $MaxFiles
        include_runtime = [bool]$IncludeRuntime
        db_reads = $false
        db_writes = $false
        provider_calls = $false
        secrets_printed = $false
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

    $queryPs1Files = @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Filter "query.ps1" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notmatch "\\.git\\" -and
            $_.FullName -notmatch "\\node_modules\\" -and
            $_.FullName -notmatch "\\runtime\\"
        } |
        Sort-Object FullName)

    $patterns = @(
        "query.ps1",
        "dog_opens",
        "dog opens",
        "dogopen",
        "query_content",
        "query_file",
        "SHOW COLUMNS",
        "SHOW INDEX",
        "INFORMATION_SCHEMA",
        "-Query",
        "-Sql",
        "-File",
        "-InputFile",
        "-Database",
        "-Connection",
        "xpdgxfsp_content.vod"
    )

    $rows = @()

    foreach ($file in $queryPs1Files) {
        $rows += [pscustomobject][ordered]@{
            match_order = @($rows).Count + 1
            evidence_type = "query_ps1_file"
            confidence = "high"
            file_path = $file.FullName
            line_number = 0
            line_text = "query.ps1 file found"
            inferred_invocation_hint = "inspect_param_block"
            db_reads = $false
            db_writes = $false
            provider_calls = $false
            secrets_printed = $false
        }

        try {
            $content = Get-Content -LiteralPath $file.FullName -ErrorAction Stop
            for ($i = 0; $i -lt [Math]::Min($content.Count, 160); $i++) {
                $line = [string]$content[$i]
                if ($line -match 'param\(|^\s*\[.*\]\$|^\s*\$[A-Za-z0-9_]+\s*=|dog_opens|query_content|query_file|Sql|Query|Database') {
                    $rows += [pscustomobject][ordered]@{
                        match_order = @($rows).Count + 1
                        evidence_type = "query_ps1_header_or_param"
                        confidence = "high"
                        file_path = $file.FullName
                        line_number = $i + 1
                        line_text = Get-SafeLine -Line $line
                        inferred_invocation_hint = "query_ps1_parameter_shape"
                        db_reads = $false
                        db_writes = $false
                        provider_calls = $false
                        secrets_printed = $false
                    }
                }
            }
        }
        catch {}
    }

    foreach ($file in (Get-SearchFiles)) {
        try {
            $matches = Select-String -LiteralPath $file.FullName -Pattern $patterns -SimpleMatch -ErrorAction SilentlyContinue
        }
        catch {
            continue
        }

        foreach ($match in @($matches)) {
            $line = [string]$match.Line
            $lower = ($line + " " + $match.Path).ToLowerInvariant()

            $evidenceType = "generic_reference"
            $confidence = "low"
            $hint = "manual_review"

            if ($lower -match "query\.ps1" -and $lower -match "dog_opens") {
                $evidenceType = "query_ps1_dog_opens_invocation"
                $confidence = "high"
                $hint = "query_ps1_plus_dog_opens_invocation"
            }
            elseif ($lower -match "query\.ps1") {
                $evidenceType = "query_ps1_invocation"
                $confidence = "medium"
                $hint = "query_ps1_invocation"
            }
            elseif ($lower -match "dog_opens") {
                $evidenceType = "dog_opens_reference"
                $confidence = "medium"
                $hint = "dog_opens_invocation"
            }
            elseif ($lower -match "show columns|show index|information_schema") {
                $evidenceType = "schema_query_reference"
                $confidence = "medium"
                $hint = "schema_query_shape"
            }
            elseif ($lower -match "query_content|query_file") {
                $evidenceType = "query_content_or_file_reference"
                $confidence = "medium"
                $hint = "query_content_file_shape"
            }

            $rows += [pscustomobject][ordered]@{
                match_order = @($rows).Count + 1
                evidence_type = $evidenceType
                confidence = $confidence
                file_path = $match.Path
                line_number = $match.LineNumber
                line_text = Get-SafeLine -Line $line
                inferred_invocation_hint = $hint
                db_reads = $false
                db_writes = $false
                provider_calls = $false
                secrets_printed = $false
            }
        }
    }

    $queryPs1Count = @($queryPs1Files).Count
    $patternCount = @($rows | Where-Object { $_.evidence_type -ne "query_ps1_file" }).Count
    $highConfidenceInvocationCount = @($rows | Where-Object { $_.confidence -eq "high" -and $_.evidence_type -match "invocation|param|header" }).Count

    $disposition = "query_wrapper_invocation_shape_inspected"
    $status = "pass"

    if ($queryPs1Count -eq 0) {
        $disposition = "query_wrapper_invocation_shape_missing_query_ps1"
        $status = "warning"
    }
    elseif ($highConfidenceInvocationCount -eq 0) {
        $disposition = "query_wrapper_invocation_shape_needs_manual_review"
        $status = "warning"
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $reportCsv = Join-Path $OutputRoot "query_wrapper_invocation_shape_$timestamp.csv"
    $reportJson = Join-Path $OutputRoot "query_wrapper_invocation_shape_$timestamp.json"
    $summaryJson = Join-Path $OutputRoot "query_wrapper_invocation_shape_summary_$timestamp.json"
    $nextPlanTxt = Join-Path $OutputRoot "query_wrapper_invocation_shape_next_plan_$timestamp.txt"

    $rows | Export-Csv -Path $reportCsv -NoTypeInformation
    $rows | ConvertTo-Json -Depth 20 | Set-Content -Path $reportJson -Encoding UTF8

    @"
Next step:
  Use this report to build test_vod_apply_db_schema_query_wrapper_read.ps1.

The next worker must:
  - Default block unless -AllowDbRead
  - Use the existing query.ps1 / dog_opens invocation shape from this report
  - Run only allowlisted read-only schema queries:
      SHOW COLUMNS FROM xpdgxfsp_content.vod
      SHOW INDEX FROM xpdgxfsp_content.vod
  - Reject any write SQL
  - Emit runtime reports only
  - Never print secrets

query.ps1 files found:
  $queryPs1Count

high-confidence invocation/header evidence rows:
  $highConfidenceInvocationCount
"@ | Set-Content -Path $nextPlanTxt -Encoding UTF8

    $summary = [ordered]@{
        status = $status
        disposition = $disposition
        query_ps1_count = $queryPs1Count
        pattern_count = $patternCount
        high_confidence_invocation_count = $highConfidenceInvocationCount
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
    Emit-LocalSignal -SignalName $QueryPs1CountSignal -SignalValue $queryPs1Count -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $InvocationPatternCountSignal -SignalValue $patternCount -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: Query wrapper invocation shape inspected. status=$status disposition=$disposition query_ps1_count=$queryPs1Count patterns=$patternCount high_confidence_invocation=$highConfidenceInvocationCount db_reads=False db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: report_csv=$reportCsv report_json=$reportJson next_plan_txt=$nextPlanTxt summary_json=$summaryJson"
        $rows |
            Sort-Object @{Expression = { if ($_.confidence -eq "high") { 0 } elseif ($_.confidence -eq "medium") { 1 } else { 2 } }}, evidence_type, file_path, line_number |
            Select-Object -First 80 confidence, evidence_type, inferred_invocation_hint, file_path, line_number, line_text |
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

    Write-Error "FAILED: Query wrapper invocation shape inspection failed. $message run_id=$RunId"
    exit 1
}
