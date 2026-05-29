<#
.SYNOPSIS
  Plan a deferred partial/failed artifact salvage queue.

.DESCRIPTION
  Read-only planner for deferred salvage.

  The main ingest path continues processing whatever it can. Failed/partial/malformed
  artifacts are inventoried into a deferred queue for later repair/salvage work.

  No provider calls. No DB reads. No DB writes. No imports.

.CONTRACT-MARKERS
  Write-JobLog
  Emit-Signal
  Emit-Heartbeat
  Test-KillSwitch
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [string]$SourceRoot = "",
    [int]$Limit = 500,
    [switch]$IncludeOldRepo,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "plan_deferred_partial_salvage_queue"
$Component = "deferred_partial_salvage_queue"
$DatabaseTarget = "none"
$SourceName = "local_failed_partial_artifacts"
$KillSwitchName = "ENABLE_DEFERRED_PARTIAL_SALVAGE_QUEUE_PLANNER"

$CompletedSignal = "deferred_partial_salvage_queue_planned_completed"
$CandidateCountSignal = "deferred_partial_salvage_queue_candidate_count"
$PartialCountSignal = "deferred_partial_salvage_queue_partial_count"
$ReviewCountSignal = "deferred_partial_salvage_queue_review_count"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\deferred_partial_salvage_queue"
$LogRoot = Join-Path $RepoRoot "runtime\logs\deferred_partial_salvage_queue"

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

function Get-CandidateRoots {
    $roots = @()

    if (-not [string]::IsNullOrWhiteSpace($SourceRoot)) {
        if (Test-Path -LiteralPath $SourceRoot) {
            $roots += (Resolve-Path -LiteralPath $SourceRoot).Path
        }
    }

    foreach ($candidate in @(
        (Join-Path $RepoRoot "runtime"),
        (Join-Path $RepoRoot "runtime\reports"),
        (Join-Path $RepoRoot "runtime\provider_snapshots"),
        (Join-Path $RepoRoot "runtime\quarantine"),
        (Join-Path $RepoRoot "runtime\failed"),
        (Join-Path $RepoRoot "runtime\partial")
    )) {
        if (Test-Path -LiteralPath $candidate) {
            $roots += (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    if ($IncludeOldRepo) {
        foreach ($candidate in @(
            "C:\miratv_ingest\quarantine",
            "C:\miratv_ingest\failed",
            "C:\miratv_ingest\partial",
            "C:\miratv_ingest\pickup",
            "C:\miratv_ingest\series_sep",
            "C:\miratv_ingest\export",
            "C:\miratv_ingest\raw",
            "C:\miratv_ingest\raw_store",
            "C:\miratv_ingest\workers"
        )) {
            if (Test-Path -LiteralPath $candidate) {
                $roots += (Resolve-Path -LiteralPath $candidate).Path
            }
        }
    }

    return @($roots | Select-Object -Unique)
}

function Get-CandidateReason {
    param([System.IO.FileInfo]$File)

    $path = $File.FullName.ToLowerInvariant()
    $name = $File.Name.ToLowerInvariant()
    $reasons = @()

    if ($path -match "quarantine|failed|error|reject|bad|partial|manual") { $reasons += "path_indicates_failed_or_partial" }
    if ($name -match "fail|failed|error|reject|bad|partial|malformed|manual|unknown") { $reasons += "filename_indicates_failed_or_partial" }
    if ($path -match "grinder|arrays|normaliz|router|pickup|series_sep") { $reasons += "path_indicates_grinder_or_shape_processing" }
    if ($File.Extension -match "\.json|\.txt|\.log|\.ndjson|\.jsonl") { $reasons += "file_type_candidate_for_salvage" }
    if ($File.Length -eq 0) { $reasons += "empty_file" }
    elseif ($File.Length -lt 32) { $reasons += "very_small_file" }

    if (@($reasons).Count -eq 0) { return "candidate_by_scan_scope" }
    return ($reasons -join "|")
}

function Get-LightweightJsonStatus {
    param([System.IO.FileInfo]$File)

    if ($File.Length -eq 0) { return "empty_file" }
    if ($File.Length -gt 1048576) { return "not_checked_large_file" }

    try {
        $raw = Get-Content -LiteralPath $File.FullName -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return "empty_or_whitespace" }

        $trimmed = $raw.Trim()
        if (-not ($trimmed.StartsWith("{") -or $trimmed.StartsWith("["))) { return "non_json_text_or_fragment" }

        try {
            $null = $trimmed | ConvertFrom-Json -ErrorAction Stop
            return "valid_json"
        }
        catch {
            if ($trimmed -match "\{.*\}" -or $trimmed -match "\[.*\]") { return "fragment_json_or_malformed_json" }
            return "invalid_json"
        }
    }
    catch {
        return "read_failed"
    }
}

function Get-SalvageStatusGuess {
    param([System.IO.FileInfo]$File, [string]$JsonStatus, [string]$CandidateReason)

    $text = ($File.FullName + " " + $File.Name + " " + $JsonStatus + " " + $CandidateReason).ToLowerInvariant()

    if ($JsonStatus -eq "valid_json") {
        if ($text -match "failed|quarantine|partial|manual") { return "valid_json_but_queued_for_review" }
        return "not_salvage_needed_valid_json"
    }

    if ($JsonStatus -eq "empty_file" -or $JsonStatus -eq "empty_or_whitespace") { return "unrecoverable_empty" }
    if ($JsonStatus -eq "fragment_json_or_malformed_json") { return "partial_fragment_salvage_candidate" }
    if ($JsonStatus -eq "non_json_text_or_fragment") { return "metadata_or_text_fragment_candidate" }
    if ($JsonStatus -eq "not_checked_large_file") { return "large_file_deferred_shape_check" }

    return "manual_review"
}

function Get-MinimumTrustGateGuess {
    param([string]$SalvageStatus)

    switch ($SalvageStatus) {
        "not_salvage_needed_valid_json" { return "no_salvage_needed" }
        "valid_json_but_queued_for_review" { return "review_before_reprocess" }
        "partial_fragment_salvage_candidate" { return "requires_identity_fields_before_apply" }
        "metadata_or_text_fragment_candidate" { return "metadata_only_no_direct_apply" }
        "large_file_deferred_shape_check" { return "defer_to_bounded_shape_scanner" }
        "unrecoverable_empty" { return "no_apply" }
        default { return "manual_review_required" }
    }
}

try {
    if ($Limit -lt 1) { $Limit = 500 }

    Write-LocalJsonLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        preview_only = $true
        db_writes = $false
        provider_calls = $false
        limit = $Limit
        include_old_repo = [bool]$IncludeOldRepo
    })

    Emit-LocalHeartbeat -Status "running"

    if (-not (Test-WorkerKillSwitch)) {
        $summary = [ordered]@{
            status = "disabled"
            preview_only = $true
            db_writes = $false
            provider_calls = $false
            run_id = $RunId
        }

        Emit-LocalSignal -SignalName $CompletedSignal -SignalValue "disabled" -Payload $summary
        Write-LocalJsonLog -EventName "job_completed" -Status "disabled" -Data $summary
        Write-Output "SKIPPED: $KillSwitchName is disabled. run_id=$RunId"
        exit 0
    }

    $roots = @(Get-CandidateRoots)
    $rows = @()
    $seen = @{}

    foreach ($root in $roots) {
        if (@($rows).Count -ge $Limit) { break }

        $files = Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -notmatch "\\.git\\" -and
                $_.FullName -notmatch "\\node_modules\\" -and
                $_.FullName -notmatch "\\build\\" -and
                $_.FullName -notmatch "\\runtime\\logs\\" -and
                (
                    $_.Extension -in @(".json", ".jsonl", ".ndjson", ".txt", ".log") -or
                    $_.Name -match "fail|failed|error|reject|bad|partial|malformed|manual|unknown"
                )
            } |
            Sort-Object LastWriteTimeUtc -Descending

        foreach ($file in $files) {
            if (@($rows).Count -ge $Limit) { break }
            if ($seen.ContainsKey($file.FullName)) { continue }

            $seen[$file.FullName] = $true
            $candidateReason = Get-CandidateReason -File $file

            if ($candidateReason -eq "candidate_by_scan_scope" -and $file.FullName -notmatch "quarantine|failed|partial|pickup|series_sep|grinder|arrays|normaliz|router") {
                continue
            }

            $jsonStatus = Get-LightweightJsonStatus -File $file
            $salvageStatus = Get-SalvageStatusGuess -File $file -JsonStatus $jsonStatus -CandidateReason $candidateReason
            $trustGate = Get-MinimumTrustGateGuess -SalvageStatus $salvageStatus
            $needsReview = ($salvageStatus -ne "not_salvage_needed_valid_json")

            $rows += [pscustomobject][ordered]@{
                queue_order = @($rows).Count + 1
                source_file = $file.FullName
                source_root = $root
                file_name = $file.Name
                extension = $file.Extension
                length_bytes = $file.Length
                last_write_utc = $file.LastWriteTimeUtc.ToString("o")
                candidate_reason = $candidateReason
                json_status = $jsonStatus
                salvage_status = $salvageStatus
                minimum_trust_gate = $trustGate
                proposed_deferred_worker = "preview_failed_json_information_salvage.ps1"
                ollama_candidate = ($salvageStatus -in @("partial_fragment_salvage_candidate", "metadata_or_text_fragment_candidate"))
                safe_auto_apply = $false
                needs_review = $needsReview
                db_writes = $false
                provider_calls = $false
            }
        }
    }

    $candidateCount = @($rows).Count
    $partialCount = @($rows | Where-Object { $_.salvage_status -match "partial|fragment|metadata" }).Count
    $reviewCount = @($rows | Where-Object { $_.needs_review -eq $true }).Count
    $ollamaCandidateCount = @($rows | Where-Object { $_.ollama_candidate -eq $true }).Count
    $validJsonCount = @($rows | Where-Object { $_.json_status -eq "valid_json" }).Count
    $malformedCount = @($rows | Where-Object { $_.json_status -match "malformed|invalid|fragment" }).Count
    $largeDeferredCount = @($rows | Where-Object { $_.json_status -eq "not_checked_large_file" }).Count

    $status = "pass"
    if ($reviewCount -gt 0) { $status = "warning" }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $queueCsv = Join-Path $OutputRoot "deferred_partial_salvage_queue_$timestamp.csv"
    $queueJson = Join-Path $OutputRoot "deferred_partial_salvage_queue_$timestamp.json"
    $summaryJson = Join-Path $OutputRoot "deferred_partial_salvage_queue_summary_$timestamp.json"

    $rows | Export-Csv -Path $queueCsv -NoTypeInformation
    $rows | ConvertTo-Json -Depth 20 | Set-Content -Path $queueJson -Encoding UTF8

    $summary = [ordered]@{
        status = $status
        preview_only = $true
        db_writes = $false
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        limit = $Limit
        include_old_repo = [bool]$IncludeOldRepo
        scanned_roots = $roots
        candidate_count = $candidateCount
        partial_count = $partialCount
        review_count = $reviewCount
        ollama_candidate_count = $ollamaCandidateCount
        valid_json_count = $validJsonCount
        malformed_or_fragment_count = $malformedCount
        large_deferred_count = $largeDeferredCount
        queue_csv = $queueCsv
        queue_json = $queueJson
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue $status -Payload $summary
    Emit-LocalSignal -SignalName $CandidateCountSignal -SignalValue $candidateCount -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $PartialCountSignal -SignalValue $partialCount -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $ReviewCountSignal -SignalValue $reviewCount -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status $status -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: deferred partial salvage queue planned. status=$status candidates=$candidateCount partial=$partialCount review=$reviewCount ollama_candidates=$ollamaCandidateCount db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: queue_csv=$queueCsv queue_json=$queueJson summary_json=$summaryJson"
        $rows |
            Select-Object -First 30 queue_order, file_name, json_status, salvage_status, minimum_trust_gate, ollama_candidate |
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

    Write-Error "FAILED: deferred partial salvage queue planning failed. $message run_id=$RunId"
    exit 1
}
