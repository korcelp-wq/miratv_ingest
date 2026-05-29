<#
.SYNOPSIS
    Check current grinder/import workers for row-resilient disposition handling.

.DESCRIPTION
    Read-only contract/audit worker for the MiraTV golden grinder rule:

      System-level failures may stop a worker.
      Row-level failures must become dispositions.

    This FIX1 version avoids treating old manifest-only missing paths as active
    grinder failures. Missing legacy manifest paths are reported separately as
    legacy_missing_reference. Current existing worker files are audited.

    Snapshot pullers, delta planners, and spine runners are intentionally out of
    scope. They may fail at the system level. This contract is for grinder/import/
    materialize/normalize style row processors.

    Intended clean-repo location:
      tools\workers\check_grinder_disposition_contract.ps1
#>

[CmdletBinding()]
param(
    [string]$WorkerName = "check_grinder_disposition_contract",
    [string]$Component = "grinder_disposition_contract",
    [string]$Environment = "dev",
    [string]$KillSwitchName = "ENABLE_GRINDER_DISPOSITION_CONTRACT_CHECK",

    [string]$ManifestPath = "tools/config/master_control_ingest_manifest.json",
    [string]$OutputRoot = "runtime/reports/grinder_disposition_contract",

    [switch]$IncludeAllWorkers,
    [switch]$IncludeLegacyMissingReferences
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Stage = "init"

function Get-RepoRootLocal {
    $scriptDir = Split-Path -Parent $PSCommandPath
    $rootCandidate = Join-Path $scriptDir "..\.."
    $resolved = Resolve-Path -Path $rootCandidate -ErrorAction SilentlyContinue
    if ($null -ne $resolved) { return $resolved.Path }
    return (Get-Location).Path
}

function New-RunIdLocal {
    param([string]$Prefix = "grinder-disposition-contract")
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
    $guid = [guid]::NewGuid().ToString("N")
    return "$Prefix-$stamp-$guid"
}

function New-DirectoryLocal {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Test-KillSwitchCompatible {
    param([string]$Name, [bool]$DefaultEnabled = $true)

    $cmd = Get-Command Test-KillSwitch -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { return $DefaultEnabled }

    $result = Test-KillSwitch -Name $Name -DefaultEnabled $DefaultEnabled
    if ($result -is [bool]) { return [bool]$result }

    if ($null -ne $result -and ($result.PSObject.Properties.Name -contains "enabled")) {
        return [bool]$result.enabled
    }

    if ($null -ne $result -and ($result.PSObject.Properties.Name -contains "is_enabled")) {
        return [bool]$result.is_enabled
    }

    return $DefaultEnabled
}

function Test-TextRegexLocal {
    param([string]$Text, [string]$Pattern)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return [regex]::IsMatch($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Add-UniquePathLocal {
    param(
        [System.Collections.Generic.List[string]]$Paths,
        [string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) { return }

    $clean = $RelativePath -replace '/', '\'
    $clean = $clean.TrimStart('\')

    if (-not $Paths.Contains($clean)) {
        $Paths.Add($clean) | Out-Null
    }
}

function Get-CurrentWorkerPathsLocal {
    param(
        [string]$RepoRoot,
        [bool]$IncludeAllWorkers
    )

    $paths = New-Object System.Collections.Generic.List[string]

    $searchRoots = @(
        "tools\workers",
        "tools\utilities",
        "tools\common"
    )

    foreach ($root in $searchRoots) {
        $fullRoot = Join-Path $RepoRoot $root
        if (-not (Test-Path -LiteralPath $fullRoot)) { continue }

        Get-ChildItem -LiteralPath $fullRoot -Recurse -File -Include "*.ps1","*.psm1","*.bat","*.cmd" -ErrorAction SilentlyContinue |
            Where-Object {
                $IncludeAllWorkers -or $_.Name -match '(?i)grinder|import|cleaner|materialize|normalize|epg'
            } |
            ForEach-Object {
                $relative = $_.FullName.Substring($RepoRoot.Length).TrimStart('\','/')
                Add-UniquePathLocal -Paths $paths -RelativePath $relative
            }
    }

    return @($paths)
}

function Get-ManifestReferencePathsLocal {
    param(
        [string]$RepoRoot,
        [string]$ManifestPath
    )

    $paths = New-Object System.Collections.Generic.List[string]
    $fullManifestPath = if ([System.IO.Path]::IsPathRooted($ManifestPath)) { $ManifestPath } else { Join-Path $RepoRoot $ManifestPath }

    if (-not (Test-Path -LiteralPath $fullManifestPath)) {
        return @($paths)
    }

    try {
        $manifest = Get-Content -LiteralPath $fullManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $json = $manifest | ConvertTo-Json -Depth 80
        $regexMatches = [regex]::Matches($json, '"current_relative_path"\s*:\s*"([^"]+)"')

        foreach ($match in $regexMatches) {
            $relative = [string]$match.Groups[1].Value
            $relative = $relative -replace '\\\\', '\'
            if ($relative -match '(?i)grinder|import|cleaner|materialize|normalize|epg') {
                Add-UniquePathLocal -Paths $paths -RelativePath $relative
            }
        }
    }
    catch {
        return @($paths)
    }

    return @($paths)
}

function New-FileAuditRowLocal {
    param(
        [string]$RepoRoot,
        [string]$RelativePath,
        [string]$Source
    )

    $fullPath = Join-Path $RepoRoot $RelativePath
    $exists = Test-Path -LiteralPath $fullPath
    $text = ""

    if ($exists) {
        try {
            $text = Get-Content -LiteralPath $fullPath -Raw -ErrorAction Stop
        }
        catch {
            $text = ""
        }
    }

    if (-not $exists) {
        return [pscustomobject]@{
            relative_path = $RelativePath
            source = $Source
            exists = $false
            candidate = $false
            has_row_loop = $false
            has_try_catch = $false
            has_json_parsing = $false
            has_disposition_word = $false
            has_disposition_assignment = $false
            has_row_error_capture = $false
            has_report_or_log_output = $false
            has_fail_fast_signals = $false
            dispositions_found = ""
            block_reasons = "missing_file"
            contract_status = "legacy_missing_reference"
        }
    }

    $isCandidate = $RelativePath -match '(?i)grinder|import|cleaner|materialize|normalize|epg'

    $hasRowLoop = Test-TextRegexLocal -Text $text -Pattern '(foreach\s*\(|ForEach-Object|while\s*\(|for\s*\()'
    $hasTryCatch = Test-TextRegexLocal -Text $text -Pattern '(?s)try\s*\{.*?catch\s*\{'
    $hasDispositionWord = Test-TextRegexLocal -Text $text -Pattern '(?i)disposition|row_status|status_reason|manual_review|unprocessable|incomplete|deferred|enrichment_needed|import_failed|processed|skipped|provider_noise|normalized_no_change|baseline_only'
    $hasDispositionAssignment = Test-TextRegexLocal -Text $text -Pattern '(?i)(disposition|row_status|status_reason|plan_bucket|change_status)\s*='
    $hasRowErrorCapture = Test-TextRegexLocal -Text $text -Pattern '(?i)row.*error|error.*row|exception.*row|row_error|error_message|failure_reason|block_reasons'
    $hasReportOrLog = Test-TextRegexLocal -Text $text -Pattern '(?i)Export-Csv|ConvertTo-Json|Set-Content|Add-Content|INSERT\s+INTO|Write-.*Log|Emit-Signal'
    $hasJsonParsing = Test-TextRegexLocal -Text $text -Pattern '(?i)ConvertFrom-Json|Invoke-RestMethod|json'
    $hasFailFastSignals = Test-TextRegexLocal -Text $text -Pattern '(?i)throw\s+|exit\s+1|ErrorActionPreference\s*='

    $allowedDispositions = @(
        "processed",
        "skipped",
        "incomplete_data",
        "unprocessable",
        "malformed_json",
        "missing_required_field",
        "missing_category",
        "missing_provider_id",
        "metadata_missing",
        "enrichment_needed",
        "deferred",
        "manual_review",
        "import_failed",
        "duplicate_detected",
        "provider_noise",
        "normalized_no_change",
        "baseline_only",
        "raw_changed_normalized_unchanged",
        "skip_import_provider_noise"
    )

    $dispositionsFound = @()
    foreach ($d in $allowedDispositions) {
        if ($text -match [regex]::Escape($d)) {
            $dispositionsFound += $d
        }
    }

    $blockReasons = @()

    if ($isCandidate) {
        if (-not $hasRowLoop) { $blockReasons += "row_loop_not_detected" }
        if (-not $hasTryCatch) { $blockReasons += "try_catch_not_detected" }
        if (-not $hasDispositionWord) { $blockReasons += "disposition_vocabulary_not_detected" }
        if (-not $hasReportOrLog) { $blockReasons += "row_report_or_log_not_detected" }

        if ($hasFailFastSignals -and -not $hasDispositionWord) {
            $blockReasons += "fail_fast_without_disposition_evidence"
        }
    }

    $contractStatus = "not_applicable"
    if ($isCandidate) {
        $contractStatus = if ($blockReasons.Count -eq 0) { "compliant" } else { "needs_review" }
    }

    [pscustomobject]@{
        relative_path = $RelativePath
        source = $Source
        exists = $exists
        candidate = $isCandidate
        has_row_loop = $hasRowLoop
        has_try_catch = $hasTryCatch
        has_json_parsing = $hasJsonParsing
        has_disposition_word = $hasDispositionWord
        has_disposition_assignment = $hasDispositionAssignment
        has_row_error_capture = $hasRowErrorCapture
        has_report_or_log_output = $hasReportOrLog
        has_fail_fast_signals = $hasFailFastSignals
        dispositions_found = (($dispositionsFound | Select-Object -Unique) -join "|")
        block_reasons = ($blockReasons -join ",")
        contract_status = $contractStatus
    }
}

$script:RunId = New-RunIdLocal
$repoRoot = Get-RepoRootLocal
$outputRootFull = if ([System.IO.Path]::IsPathRooted($OutputRoot)) { $OutputRoot } else { Join-Path $repoRoot $OutputRoot }
New-DirectoryLocal -Path $outputRootFull

$loggingModule = Join-Path $repoRoot "tools\common\Logging.psm1"
$loggingAvailable = $false
if (Test-Path -LiteralPath $loggingModule) {
    Import-Module $loggingModule -Force -ErrorAction SilentlyContinue
    $loggingAvailable = [bool](Get-Command Write-JobLog -ErrorAction SilentlyContinue)
}

$startedAt = Get-Date
$signalName = "grinder_disposition_contract_completed"

try {
    $script:Stage = "kill_switch"

    if ($loggingAvailable) {
        $killEnabled = Test-KillSwitchCompatible -Name $KillSwitchName -DefaultEnabled $true

        if (-not $killEnabled) {
            Write-JobLog `
                -RunId $script:RunId `
                -JobName $WorkerName `
                -WorkerName $WorkerName `
                -Component $Component `
                -Environment $Environment `
                -EventType "worker_blocked" `
                -Status "blocked" `
                -Data @{
                    event_message = "Grinder disposition contract check blocked by kill switch."
                    kill_switch_name = $KillSwitchName
                } | Out-Null

            Write-Output "BLOCKED: grinder disposition contract check blocked. run_id=$script:RunId kill_switch=$KillSwitchName"
            exit 0
        }

        Write-JobLog `
            -RunId $script:RunId `
            -JobName $WorkerName `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -EventType "worker_started" `
            -Status "started" `
            -Data @{
                event_message = "Grinder disposition contract check started."
                manifest_path = $ManifestPath
                include_all_workers = [bool]$IncludeAllWorkers
                include_legacy_missing_references = [bool]$IncludeLegacyMissingReferences
            } | Out-Null
    }

    $script:Stage = "discover_files"

    $currentPaths = Get-CurrentWorkerPathsLocal -RepoRoot $repoRoot -IncludeAllWorkers ([bool]$IncludeAllWorkers)
    $manifestPaths = Get-ManifestReferencePathsLocal -RepoRoot $repoRoot -ManifestPath $ManifestPath

    $allRows = @()

    foreach ($relativePath in $currentPaths) {
        $allRows += New-FileAuditRowLocal -RepoRoot $repoRoot -RelativePath $relativePath -Source "current_repo"
    }

    if ($IncludeLegacyMissingReferences) {
        foreach ($relativePath in $manifestPaths) {
            if ($currentPaths -contains $relativePath) { continue }

            $fullPath = Join-Path $repoRoot $relativePath
            if (-not (Test-Path -LiteralPath $fullPath)) {
                $allRows += New-FileAuditRowLocal -RepoRoot $repoRoot -RelativePath $relativePath -Source "manifest_legacy"
            }
        }
    }

    $rows = @($allRows | Sort-Object source, relative_path)

    $candidateRows = @($rows | Where-Object { $_.candidate -eq $true -and $_.exists -eq $true })
    $compliantRows = @($candidateRows | Where-Object { $_.contract_status -eq "compliant" })
    $reviewRows = @($candidateRows | Where-Object { $_.contract_status -eq "needs_review" })
    $legacyMissingRows = @($rows | Where-Object { $_.contract_status -eq "legacy_missing_reference" })

    $statusValue = "pass"
    if ($reviewRows.Count -gt 0) {
        $statusValue = "warning"
    }

    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $auditCsv = Join-Path $outputRootFull "grinder_disposition_contract_audit_$stamp.csv"
    $summaryJson = Join-Path $outputRootFull "grinder_disposition_contract_summary_$stamp.json"

    $rows | Export-Csv -LiteralPath $auditCsv -NoTypeInformation -Encoding UTF8

    $durationMs = [int]((Get-Date) - $startedAt).TotalMilliseconds

    $summary = [pscustomobject]@{
        run_id = $script:RunId
        worker_name = $WorkerName
        component = $Component
        environment = $Environment
        read_only = $true
        provider_calls = $false
        db_imported = $false
        db_writes = $false
        files_seen = @($rows).Count
        current_candidate_files = $candidateRows.Count
        compliant_files = $compliantRows.Count
        needs_review_files = $reviewRows.Count
        legacy_missing_references = $legacyMissingRows.Count
        status = $statusValue
        audit_csv = $auditCsv
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    }

    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryJson -Encoding UTF8

    if ($loggingAvailable) {
        $script:Stage = "emit_success"

        Write-JobLog `
            -RunId $script:RunId `
            -JobName $WorkerName `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -EventType "worker_completed" `
            -Status $statusValue `
            -Data @{
                event_message = "Grinder disposition contract check completed."
                read_only = $true
                current_candidate_files = $candidateRows.Count
                compliant_files = $compliantRows.Count
                needs_review_files = $reviewRows.Count
                legacy_missing_references = $legacyMissingRows.Count
                duration_ms = $durationMs
            } | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName $WorkerName `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName $signalName `
            -P0Item "P0.5" `
            -SignalValue $statusValue `
            -Status $statusValue `
            -AllowedValues "pass|warning|fail|disabled" `
            -SourceTableOrEndpoint "tools/workers/check_grinder_disposition_contract.ps1" `
            -Data @{
                dashboard_panel = "Provider Sync"
                widget_key = "grinder.disposition.contract"
                owner = "Content Ops"
                kill_switch_name = $KillSwitchName
                read_only = $true
                audit_csv = $auditCsv
                summary_json = $summaryJson
            } | Out-Null
    }

    Write-Output ("OK: grinder disposition contract check completed. status={0} read_only=True current_candidate_files={1} compliant={2} needs_review={3} legacy_missing_references={4} output_root={5} run_id={6}" -f `
        $statusValue, `
        $candidateRows.Count, `
        $compliantRows.Count, `
        $reviewRows.Count, `
        $legacyMissingRows.Count, `
        $outputRootFull, `
        $script:RunId)

    Write-Output ("FILES: audit_csv={0} summary_json={1}" -f $auditCsv, $summaryJson)

    $rows |
        Where-Object { $_.candidate -eq $true -and $_.exists -eq $true } |
        Select-Object relative_path, contract_status, block_reasons |
        Format-Table -AutoSize
}
catch {
    $errorMessage = "stage=$script:Stage; error=$($_.Exception.Message)"

    if ($loggingAvailable) {
        Write-JobLog `
            -RunId $script:RunId `
            -JobName $WorkerName `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -EventType "worker_failed" `
            -Status "failed" `
            -Data @{
                event_message = "Grinder disposition contract check failed."
                error = $errorMessage
            } | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName $WorkerName `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName $signalName `
            -P0Item "P0.5" `
            -SignalValue "fail" `
            -Status "fail" `
            -AllowedValues "pass|warning|fail|disabled" `
            -SourceTableOrEndpoint "tools/workers/check_grinder_disposition_contract.ps1" `
            -Data @{
                dashboard_panel = "Provider Sync"
                widget_key = "grinder.disposition.contract"
                owner = "Content Ops"
                kill_switch_name = $KillSwitchName
                error = $errorMessage
            } | Out-Null
    }

    Write-Error "FAILED: grinder disposition contract check failed. run_id=$script:RunId $errorMessage"
    exit 1
}
