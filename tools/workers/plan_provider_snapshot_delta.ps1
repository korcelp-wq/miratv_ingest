<#
.SYNOPSIS
    Plan provider snapshot deltas across governed snapshot workers.

.DESCRIPTION
    Read-only planner that inspects the latest provider snapshot summary JSON files
    for categories and top-level inventory.

    It does not call provider APIs.
    It does not import to database.
    It does not write provider data.
    It only reads runtime/reports/provider_*_snapshot summary files and emits a
    consolidated delta plan.

    Intended clean-repo location:
      tools\workers\plan_provider_snapshot_delta.ps1
#>

[CmdletBinding()]
param(
    [string]$WorkerName = "plan_provider_snapshot_delta",
    [string]$Component = "provider_snapshot_delta",
    [string]$Environment = "dev",
    [string]$KillSwitchName = "ENABLE_PROVIDER_SNAPSHOT_DELTA_PLAN",

    [int]$MacUserId = 6,
    [string]$ProviderLabel = "",

    [string]$ReportsRoot = "runtime/reports",
    [string]$OutputRoot = "runtime/reports/provider_snapshot_delta"
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
    param([string]$Prefix = "provider-snapshot-delta-plan")
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
    param(
        [string]$Name,
        [bool]$DefaultEnabled = $true
    )

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

function Get-LatestSummaryLocal {
    param(
        [string]$ReportsRootFull,
        [string]$FolderName,
        [string]$Prefix
    )

    $folder = Join-Path $ReportsRootFull $FolderName
    if (-not (Test-Path -LiteralPath $folder)) {
        return $null
    }

    return Get-ChildItem -LiteralPath $folder -File -Filter "$Prefix*.json" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Read-JsonFileLocal {
    param([string]$Path)

    try {
        return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function New-SnapshotPlanRowLocal {
    param(
        [string]$MediaType,
        [string]$SnapshotKind,
        [string]$FolderName,
        [string]$Prefix,
        [string]$ReportsRootFull
    )

    $latestFile = Get-LatestSummaryLocal -ReportsRootFull $ReportsRootFull -FolderName $FolderName -Prefix $Prefix

    if ($null -eq $latestFile) {
        return [pscustomobject]@{
            media_type = $MediaType
            snapshot_kind = $SnapshotKind
            status = "missing_summary"
            plan_bucket = "snapshot_missing"
            action = "run_snapshot_worker"
            summary_path = ""
            generated_at_utc = ""
            item_count_estimate = ""
            changed = ""
            raw_changed = ""
            normalized_changed = ""
            change_status = ""
            provider_http_status = ""
            provider_calls = ""
            db_imported = ""
            snapshot_path = ""
            snapshot_length = ""
            snapshot_sha256 = ""
            normalized_snapshot_sha256 = ""
            prior_snapshot_path = ""
            prior_normalized_snapshot_sha256 = ""
        }
    }

    $summary = Read-JsonFileLocal -Path $latestFile.FullName

    if ($null -eq $summary) {
        return [pscustomobject]@{
            media_type = $MediaType
            snapshot_kind = $SnapshotKind
            status = "bad_summary_json"
            plan_bucket = "manual_review"
            action = "inspect_summary_json"
            summary_path = $latestFile.FullName
            generated_at_utc = ""
            item_count_estimate = ""
            changed = ""
            raw_changed = ""
            normalized_changed = ""
            change_status = ""
            provider_http_status = ""
            provider_calls = ""
            db_imported = ""
            snapshot_path = ""
            snapshot_length = ""
            snapshot_sha256 = ""
            normalized_snapshot_sha256 = ""
            prior_snapshot_path = ""
            prior_normalized_snapshot_sha256 = ""
        }
    }

    $changed = $false
    if ($summary.PSObject.Properties.Name -contains "changed") { $changed = [bool]$summary.changed }

    $rawChanged = $false
    if ($summary.PSObject.Properties.Name -contains "raw_changed") { $rawChanged = [bool]$summary.raw_changed }

    $normalizedChanged = $false
    if ($summary.PSObject.Properties.Name -contains "normalized_changed") { $normalizedChanged = [bool]$summary.normalized_changed }

    $changeStatus = ""
    if ($summary.PSObject.Properties.Name -contains "change_status") { $changeStatus = [string]$summary.change_status }

    $planBucket = "skip_no_change"
    $action = "no_import_needed"
    $status = "pass"

    if ($changeStatus -eq "first_snapshot") {
        $planBucket = "baseline_only"
        $action = "retain_baseline_no_import"
    }
    elseif ($normalizedChanged -or $changed) {
        $planBucket = "normalized_inventory_changed"
        $action = "prepare_delta_import_review"
    }
    elseif ($rawChanged -and -not $normalizedChanged) {
        $planBucket = "raw_changed_normalized_unchanged"
        $action = "skip_import_provider_noise"
    }
    elseif ($changeStatus -eq "unchanged") {
        $planBucket = "skip_no_change"
        $action = "no_import_needed"
    }

    [pscustomobject]@{
        media_type = $MediaType
        snapshot_kind = $SnapshotKind
        status = $status
        plan_bucket = $planBucket
        action = $action
        summary_path = $latestFile.FullName
        generated_at_utc = [string]$summary.generated_at_utc
        item_count_estimate = [string]$summary.item_count_estimate
        changed = [string]$changed
        raw_changed = [string]$rawChanged
        normalized_changed = [string]$normalizedChanged
        change_status = $changeStatus
        provider_http_status = [string]$summary.provider_http_status
        provider_calls = [string]$summary.provider_calls
        db_imported = [string]$summary.db_imported
        snapshot_path = [string]$summary.snapshot_path
        snapshot_length = [string]$summary.snapshot_length
        snapshot_sha256 = [string]$summary.snapshot_sha256
        normalized_snapshot_sha256 = [string]$summary.normalized_snapshot_sha256
        prior_snapshot_path = [string]$summary.prior_snapshot_path
        prior_normalized_snapshot_sha256 = [string]$summary.prior_normalized_snapshot_sha256
    }
}

$script:RunId = New-RunIdLocal
$repoRoot = Get-RepoRootLocal

$reportsRootFull = if ([System.IO.Path]::IsPathRooted($ReportsRoot)) { $ReportsRoot } else { Join-Path $repoRoot $ReportsRoot }
$outputRootFull = if ([System.IO.Path]::IsPathRooted($OutputRoot)) { $OutputRoot } else { Join-Path $repoRoot $OutputRoot }
New-DirectoryLocal -Path $outputRootFull

$loggingModule = Join-Path $repoRoot "tools\common\Logging.psm1"
$loggingAvailable = $false
if (Test-Path -LiteralPath $loggingModule) {
    Import-Module $loggingModule -Force -ErrorAction SilentlyContinue
    $loggingAvailable = [bool](Get-Command Write-JobLog -ErrorAction SilentlyContinue)
}

$startedAt = Get-Date
$signalName = "provider_snapshot_delta_plan_completed"

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
                    event_message = "Provider snapshot delta plan blocked by kill switch."
                    kill_switch_name = $KillSwitchName
                    mac_user_id = $MacUserId
                    provider_label = $ProviderLabel
                } | Out-Null

            Write-Output "BLOCKED: provider snapshot delta plan blocked. run_id=$script:RunId kill_switch=$KillSwitchName"
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
                event_message = "Provider snapshot delta plan started."
                mac_user_id = $MacUserId
                provider_label = $ProviderLabel
                reports_root = $reportsRootFull
            } | Out-Null
    }

    $script:Stage = "read_snapshot_summaries"

    $definitions = @(
        @{ media_type = "live";   snapshot_kind = "categories"; folder = "provider_live_categories_snapshot";   prefix = "provider_live_categories_snapshot_summary_" },
        @{ media_type = "vod";    snapshot_kind = "categories"; folder = "provider_vod_categories_snapshot";    prefix = "provider_vod_categories_snapshot_summary_" },
        @{ media_type = "series"; snapshot_kind = "categories"; folder = "provider_series_categories_snapshot"; prefix = "provider_series_categories_snapshot_summary_" },
        @{ media_type = "live";   snapshot_kind = "streams";    folder = "provider_live_streams_snapshot";      prefix = "provider_live_streams_snapshot_summary_" },
        @{ media_type = "vod";    snapshot_kind = "streams";    folder = "provider_vod_streams_snapshot";       prefix = "provider_vod_streams_snapshot_summary_" },
        @{ media_type = "series"; snapshot_kind = "streams";    folder = "provider_series_streams_snapshot";    prefix = "provider_series_streams_snapshot_summary_" }
    )

    $rows = @()
    foreach ($definition in $definitions) {
        $rows += New-SnapshotPlanRowLocal `
            -MediaType ([string]$definition.media_type) `
            -SnapshotKind ([string]$definition.snapshot_kind) `
            -FolderName ([string]$definition.folder) `
            -Prefix ([string]$definition.prefix) `
            -ReportsRootFull $reportsRootFull
    }

    $statusValue = "pass"
    if (@($rows | Where-Object { $_.status -ne "pass" }).Count -gt 0) {
        $statusValue = "warning"
    }

    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $planCsv = Join-Path $outputRootFull "provider_snapshot_delta_plan_$stamp.csv"
    $summaryJson = Join-Path $outputRootFull "provider_snapshot_delta_plan_summary_$stamp.json"

    $rows | Export-Csv -LiteralPath $planCsv -NoTypeInformation -Encoding UTF8

    $bucketCounts = @(
        $rows |
            Group-Object plan_bucket |
            Sort-Object Name |
            ForEach-Object {
                [pscustomobject]@{
                    plan_bucket = $_.Name
                    count = $_.Count
                }
            }
    )

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
        mac_user_id = $MacUserId
        provider_label = $ProviderLabel
        snapshot_summary_count = @($rows).Count
        status = $statusValue
        plan_bucket_counts = $bucketCounts
        plan_csv = $planCsv
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
                event_message = "Provider snapshot delta plan completed."
                read_only = $true
                provider_calls = $false
                db_imported = $false
                snapshot_summary_count = @($rows).Count
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
            -SourceTableOrEndpoint "tools/workers/plan_provider_snapshot_delta.ps1" `
            -Data @{
                dashboard_panel = "Provider Sync"
                widget_key = "provider.snapshot.delta.plan"
                owner = "Content Ops"
                kill_switch_name = $KillSwitchName
                read_only = $true
                provider_calls = $false
                db_imported = $false
                plan_csv = $planCsv
                summary_json = $summaryJson
            } | Out-Null
    }

    Write-Output ("OK: provider snapshot delta plan completed. status={0} read_only=True provider_calls=False db_imported=False snapshot_summary_count={1} output_root=""{2}"" run_id={3}" -f `
        $statusValue, `
        @($rows).Count, `
        $outputRootFull, `
        $script:RunId)

    Write-Output ("FILES: plan_csv=""{0}"" summary_json=""{1}""" -f $planCsv, $summaryJson)

    $rows |
        Select-Object media_type, snapshot_kind, plan_bucket, action, item_count_estimate, change_status |
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
                event_message = "Provider snapshot delta plan failed."
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
            -SourceTableOrEndpoint "tools/workers/plan_provider_snapshot_delta.ps1" `
            -Data @{
                dashboard_panel = "Provider Sync"
                widget_key = "provider.snapshot.delta.plan"
                owner = "Content Ops"
                kill_switch_name = $KillSwitchName
                error = $errorMessage
            } | Out-Null
    }

    Write-Error "FAILED: provider snapshot delta plan failed. run_id=$script:RunId $errorMessage"
    exit 1
}

