<#
.SYNOPSIS
  Resolve canonical query wrapper source for VOD schema validation.

.DESCRIPTION
  Read-only resolver.

  The clean repo has query.ps1 / dog_opens references but may not contain the
  actual query.ps1 wrapper file. This worker searches candidate roots for the
  actual wrapper source and records enough evidence to choose the canonical path.

  Default roots:
    - current repo root
    - parent directory of current repo
    - common sibling/old MiraTV directories if present

  Optional:
    - pass -ExtraRoot "C:\some\old\directory" one or more times

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
    [string[]]$ExtraRoot = @(),
    [int]$MaxResults = 500,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "resolve_query_wrapper_canonical_source"
$Component = "query_wrapper_canonical_source"
$DatabaseTarget = "none"
$SourceName = "local_repo_and_candidate_roots"
$KillSwitchName = "ENABLE_QUERY_WRAPPER_CANONICAL_SOURCE_RESOLVER"

$CompletedSignal = "query_wrapper_canonical_source_resolved_completed"
$DispositionSignal = "query_wrapper_canonical_source_resolved_disposition"
$QueryPs1FoundSignal = "query_wrapper_canonical_source_query_ps1_found"
$CanonicalSourceSignal = "query_wrapper_canonical_source_selected_hint"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$RepoParent = Split-Path -Parent $RepoRoot
$OutputRoot = Join-Path $RepoRoot "runtime\reports\query_wrapper_canonical_source"
$LogRoot = Join-Path $RepoRoot "runtime\logs\query_wrapper_canonical_source"

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

function Get-SafeLine {
    param([string]$Line)

    if ($null -eq $Line) { return "" }

    $safe = $Line.Trim()
    $safe = $safe -replace '(?i)(password|passwd|pwd|token|secret|key)\s*=\s*["''][^"'']+["'']', '$1=<redacted>'
    $safe = $safe -replace '(?i)(password|passwd|pwd|token|secret|key)\s*:\s*["''][^"'']+["'']', '$1:<redacted>'
    $safe = $safe -replace '(?i)(--password=)[^\s]+', '$1<redacted>'
    $safe = $safe -replace '(?i)(-p)[^\s]+', '$1<redacted>'

    if ($safe.Length -gt 320) { return $safe.Substring(0, 320) }
    return $safe
}

function Get-CandidateRoots {
    $roots = New-Object System.Collections.ArrayList

    [void]$roots.Add($RepoRoot)
    [void]$roots.Add($RepoParent)

    $commonNames = @(
        "miraTV_ingest",
        "miraTV_ingest_old",
        "miraTV_ingest_clean_old",
        "MiraTV_project_PHASES_1_8",
        "MiraTV",
        "miratv",
        "old",
        "_old"
    )

    foreach ($name in $commonNames) {
        $candidate = Join-Path $RepoParent $name
        if (Test-Path -LiteralPath $candidate) {
            [void]$roots.Add((Resolve-Path -LiteralPath $candidate).Path)
        }
    }

    foreach ($root in $ExtraRoot) {
        if (-not [string]::IsNullOrWhiteSpace($root) -and (Test-Path -LiteralPath $root)) {
            [void]$roots.Add((Resolve-Path -LiteralPath $root).Path)
        }
    }

    return @($roots | Sort-Object -Unique)
}

function New-ResultRow {
    param(
        [string]$EvidenceType,
        [string]$Confidence,
        [string]$Root,
        [string]$FilePath,
        [int]$LineNumber,
        [string]$LineText,
        [string]$Hint
    )

    return [pscustomobject][ordered]@{
        evidence_type = $EvidenceType
        confidence = $Confidence
        root = $Root
        file_path = $FilePath
        line_number = $LineNumber
        line_text = Get-SafeLine -Line $LineText
        selected_hint = $Hint
        db_reads = $false
        db_writes = $false
        provider_calls = $false
        secrets_printed = $false
    }
}

try {
    if ($MaxResults -lt 1) { $MaxResults = 500 }
    if ($MaxResults -gt 5000) { $MaxResults = 5000 }

    Write-LocalJsonLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        max_results = $MaxResults
        extra_roots = $ExtraRoot
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

    $roots = Get-CandidateRoots
    $rows = @()

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
        "xpdgxfsp_content.vod",
        "xpdgxfsp_content"
    )

    foreach ($root in $roots) {
        if (@($rows).Count -ge $MaxResults) { break }

        $queryFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter "query.ps1" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -notmatch "\\.git\\" -and
                $_.FullName -notmatch "\\node_modules\\" -and
                $_.FullName -notmatch "\\runtime\\logs\\"
            })

        foreach ($file in $queryFiles) {
            if (@($rows).Count -ge $MaxResults) { break }

            $rows += New-ResultRow `
                -EvidenceType "query_ps1_file" `
                -Confidence "high" `
                -Root $root `
                -FilePath $file.FullName `
                -LineNumber 0 `
                -LineText "query.ps1 file found" `
                -Hint "candidate_query_ps1"

            try {
                $header = Get-Content -LiteralPath $file.FullName -TotalCount 180 -ErrorAction Stop
                for ($i = 0; $i -lt $header.Count; $i++) {
                    $line = [string]$header[$i]
                    if ($line -match 'param\(|^\s*\[.*\]\$|dog_opens|query_content|query_file|Sql|Query|Database|Connection') {
                        $rows += New-ResultRow `
                            -EvidenceType "query_ps1_header_or_param" `
                            -Confidence "high" `
                            -Root $root `
                            -FilePath $file.FullName `
                            -LineNumber ($i + 1) `
                            -LineText $line `
                            -Hint "query_ps1_parameter_shape"
                    }
                }
            }
            catch {}
        }

        $searchFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -Include "*.ps1","*.psm1","*.bat","*.cmd","*.md","*.txt","*.json","*.csv" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -notmatch "\\.git\\" -and
                $_.FullName -notmatch "\\node_modules\\" -and
                $_.FullName -notmatch "\\runtime\\logs\\"
            } |
            Select-Object -First 1500)

        foreach ($file in $searchFiles) {
            if (@($rows).Count -ge $MaxResults) { break }

            try {
                $matches = Select-String -LiteralPath $file.FullName -Pattern $patterns -SimpleMatch -ErrorAction SilentlyContinue
            }
            catch {
                continue
            }

            foreach ($match in @($matches)) {
                if (@($rows).Count -ge $MaxResults) { break }

                $line = [string]$match.Line
                $lower = ($line + " " + $match.Path).ToLowerInvariant()

                $evidenceType = "reference"
                $confidence = "low"
                $hint = "manual_review"

                if ($lower -match "query\.ps1" -and $lower -match "dog_opens") {
                    $evidenceType = "query_ps1_dog_opens_reference"
                    $confidence = "high"
                    $hint = "query_ps1_plus_dog_opens_reference"
                }
                elseif ($lower -match "query\.ps1") {
                    $evidenceType = "query_ps1_reference"
                    $confidence = "medium"
                    $hint = "query_ps1_reference"
                }
                elseif ($lower -match "dog_opens") {
                    $evidenceType = "dog_opens_reference"
                    $confidence = "medium"
                    $hint = "dog_opens_reference"
                }
                elseif ($lower -match "query_content|query_file") {
                    $evidenceType = "query_content_or_file_reference"
                    $confidence = "medium"
                    $hint = "query_content_or_file_reference"
                }
                elseif ($lower -match "show columns|show index|information_schema") {
                    $evidenceType = "schema_query_reference"
                    $confidence = "medium"
                    $hint = "schema_query_reference"
                }

                $rows += New-ResultRow `
                    -EvidenceType $evidenceType `
                    -Confidence $confidence `
                    -Root $root `
                    -FilePath $match.Path `
                    -LineNumber $match.LineNumber `
                    -LineText $line `
                    -Hint $hint
            }
        }
    }

    $queryPs1Found = @($rows | Where-Object { $_.evidence_type -eq "query_ps1_file" }).Count -gt 0
    $queryPs1Count = @($rows | Where-Object { $_.evidence_type -eq "query_ps1_file" }).Count
    $dogOpensReferenceCount = @($rows | Where-Object { $_.evidence_type -match "dog_opens" }).Count
    $highConfidenceCount = @($rows | Where-Object { $_.confidence -eq "high" }).Count

    $selectedHint = "manual_review"
    $selectedSource = ""

    $preferred = $rows |
        Where-Object { $_.evidence_type -eq "query_ps1_file" } |
        Sort-Object @{Expression = { if ($_.file_path -like "$RepoRoot*") { 0 } else { 1 } }}, file_path |
        Select-Object -First 1

    if ($preferred) {
        $selectedHint = "query_ps1_file"
        $selectedSource = [string]$preferred.file_path
    }
    elseif ($dogOpensReferenceCount -gt 0) {
        $selectedHint = "dog_opens_reference_only"
    }

    $status = "pass"
    $disposition = "query_wrapper_canonical_source_resolved"

    if (-not $queryPs1Found) {
        $status = "warning"
        $disposition = "query_wrapper_canonical_source_missing_query_ps1"
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $reportCsv = Join-Path $OutputRoot "query_wrapper_canonical_source_$timestamp.csv"
    $reportJson = Join-Path $OutputRoot "query_wrapper_canonical_source_$timestamp.json"
    $summaryJson = Join-Path $OutputRoot "query_wrapper_canonical_source_summary_$timestamp.json"
    $nextPlanTxt = Join-Path $OutputRoot "query_wrapper_canonical_source_next_plan_$timestamp.txt"

    $rows | Export-Csv -Path $reportCsv -NoTypeInformation
    $rows | ConvertTo-Json -Depth 20 | Set-Content -Path $reportJson -Encoding UTF8

    @"
Canonical source resolution result:
  disposition=$disposition
  selected_hint=$selectedHint
  selected_source=$selectedSource
  query_ps1_count=$queryPs1Count
  dog_opens_reference_count=$dogOpensReferenceCount

Next step:
  If selected_source is blank, locate/copy the real query.ps1 from the old directory
  or pass -ExtraRoot with the old directory path and rerun this worker.

Example:
  pwsh -NoProfile -ExecutionPolicy Bypass `
    -File ".\tools\workers\resolve_query_wrapper_canonical_source.ps1" `
    -Environment "dev" `
    -ExtraRoot "C:\path\to\old\directory"

No DB reads/writes were performed.
"@ | Set-Content -Path $nextPlanTxt -Encoding UTF8

    $summary = [ordered]@{
        status = $status
        disposition = $disposition
        selected_hint = $selectedHint
        selected_source = $selectedSource
        query_ps1_found = $queryPs1Found
        query_ps1_count = $queryPs1Count
        dog_opens_reference_count = $dogOpensReferenceCount
        high_confidence_count = $highConfidenceCount
        searched_roots = $roots
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
    Emit-LocalSignal -SignalName $QueryPs1FoundSignal -SignalValue $queryPs1Found -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $CanonicalSourceSignal -SignalValue $selectedHint -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: Query wrapper canonical source resolved. status=$status disposition=$disposition selected_hint=$selectedHint query_ps1_found=$queryPs1Found query_ps1_count=$queryPs1Count dog_opens_reference_count=$dogOpensReferenceCount db_reads=False db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: report_csv=$reportCsv report_json=$reportJson next_plan_txt=$nextPlanTxt summary_json=$summaryJson"
        $rows |
            Sort-Object @{Expression = { if ($_.confidence -eq "high") { 0 } elseif ($_.confidence -eq "medium") { 1 } else { 2 } }}, evidence_type, file_path, line_number |
            Select-Object -First 80 confidence, evidence_type, selected_hint, file_path, line_number, line_text |
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

    Write-Error "FAILED: Query wrapper canonical source resolver failed. $message run_id=$RunId"
    exit 1
}
