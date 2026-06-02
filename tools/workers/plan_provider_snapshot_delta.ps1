<#
.SYNOPSIS
    Plan provider snapshot deltas across governed snapshot workers.

.DESCRIPTION
    Read-only planner that inspects the latest provider snapshot summary JSON files
    for categories and top-level inventory.

    It does not call provider APIs.
    It does not import provider data to the content database.
    It reads runtime/reports/provider_*_snapshot summary files and emits a
    consolidated delta plan.

    Master Control path:
      - writes debug/fallback artifacts to runtime/reports/provider_snapshot_delta
      - writes direct DB logging rows to:
          xpdgxfsp_content.mc_provider_snapshot_delta_plan_summary
          xpdgxfsp_content.mc_provider_snapshot_delta_plan

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

function ConvertTo-TinyIntLocal {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [bool]) {
        if ($Value) { return 1 }
        return 0
    }

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    if ($text -match '^(1|true|yes|y)$') {
        return 1
    }

    if ($text -match '^(0|false|no|n)$') {
        return 0
    }

    return $null
}

function ConvertTo-HashtableLocal {
    param([Parameter(Mandatory = $true)][object]$Object)

    $hash = @{}
    foreach ($property in $Object.PSObject.Properties) {
        $hash[$property.Name] = $property.Value
    }
    return $hash
}

function Get-FileMetaLocal {
    param(
        [string]$Path,
        [string]$Pattern
    )

    $sha = ""
    $lastWriteUtc = ""

    if (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path)) {
        try {
            $sha = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        }
        catch {
            $sha = ""
        }

        try {
            $lastWriteUtc = (Get-Item -LiteralPath $Path).LastWriteTimeUtc.ToString("o")
        }
        catch {
            $lastWriteUtc = ""
        }
    }

    if (Get-Command New-McSourceMeta -ErrorAction SilentlyContinue) {
        return New-McSourceMeta `
            -SourceFilePath $Path `
            -SourceFilePattern $Pattern `
            -SourceFileSha256 $sha `
            -SourceFileLastWriteUtc $lastWriteUtc
    }

    $sourceFileName = ""
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        try { $sourceFileName = Split-Path -Path $Path -Leaf } catch { $sourceFileName = "" }
    }

    return [ordered]@{
        source_file_path = $Path
        source_file_name = $sourceFileName
        source_file_pattern = $Pattern
        source_file_sha256 = $sha
        source_file_last_write_utc = $lastWriteUtc
    }
}

function Initialize-MasterControlDbLocal {
    param([string]$RepoRoot)

    $result = [ordered]@{
        available = $false
        error = ""
    }

    try {
        $dbQueryModule = Join-Path $RepoRoot "tools\common\DbQuery.psm1"
        if (-not (Test-Path -LiteralPath $dbQueryModule)) {
            throw "DbQuery module not found: $dbQueryModule"
        }

        Import-Module $dbQueryModule -Force -ErrorAction Stop

        $mcDbModule = Join-Path $RepoRoot "tools\common\MasterControlDb.psm1"
        if (-not (Test-Path -LiteralPath $mcDbModule)) {
            throw "MasterControlDb module not found: $mcDbModule"
        }

        Import-Module $mcDbModule -Force -ErrorAction Stop

        $required = @(
            "Write-McProviderSnapshotDeltaPlanSummary",
            "Write-McProviderSnapshotDeltaPlanRow"
        )

        foreach ($commandName in $required) {
            if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
                throw "Required command missing: $commandName"
            }
        }

        $result.available = $true
    }
    catch {
        $result.available = $false
        $result.error = $_.Exception.Message
    }

    return [pscustomobject]$result
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
            changed = $null
            raw_changed = $null
            normalized_changed = $null
            change_status = ""
            provider_http_status = ""
            provider_calls = $null
            db_imported = $null
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
            changed = $null
            raw_changed = $null
            normalized_changed = $null
            change_status = ""
            provider_http_status = ""
            provider_calls = $null
            db_imported = $null
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
        changed = (ConvertTo-TinyIntLocal $changed)
        raw_changed = (ConvertTo-TinyIntLocal $rawChanged)
        normalized_changed = (ConvertTo-TinyIntLocal $normalizedChanged)
        change_status = $changeStatus
        provider_http_status = [string]$summary.provider_http_status
        provider_calls = (ConvertTo-TinyIntLocal $summary.provider_calls)
        db_imported = (ConvertTo-TinyIntLocal $summary.db_imported)
        snapshot_path = [string]$summary.snapshot_path
        snapshot_length = [string]$summary.snapshot_length
        snapshot_sha256 = [string]$summary.snapshot_sha256
        normalized_snapshot_sha256 = [string]$summary.normalized_snapshot_sha256
        prior_snapshot_path = [string]$summary.prior_snapshot_path
        prior_normalized_snapshot_sha256 = [string]$summary.prior_normalized_snapshot_sha256
    }
}

function Write-MasterControlDeltaPlanLocal {
    param(
        [bool]$McDbAvailable,
        [object]$Summary,
        [object[]]$Rows,
        [string]$PlanCsv,
        [string]$SummaryJson
    )

    $writeResult = [ordered]@{
        available = $McDbAvailable
        attempted = $false
        summary_written = $false
        detail_written_count = 0
        error = ""
    }

    if (-not $McDbAvailable) {
        return [pscustomobject]$writeResult
    }

    try {
        $writeResult.attempted = $true

        $summaryHash = ConvertTo-HashtableLocal -Object $Summary
        $summarySource = Get-FileMetaLocal `
            -Path $SummaryJson `
            -Pattern "provider_snapshot_delta_plan_summary_TIMESTAMP.json"

        Write-McProviderSnapshotDeltaPlanSummary `
            -Summary $summaryHash `
            -SourceMeta $summarySource | Out-Null

        $writeResult.summary_written = $true

        $detailSource = Get-FileMetaLocal `
            -Path $PlanCsv `
            -Pattern "provider_snapshot_delta_plan_TIMESTAMP.csv"

        foreach ($row in $Rows) {
            $rowHash = ConvertTo-HashtableLocal -Object $row

            Write-McProviderSnapshotDeltaPlanRow `
                -PlanRow $rowHash `
                -SourceMeta $detailSource | Out-Null

            $writeResult.detail_written_count++
        }
    }
    catch {
        $writeResult.error = $_.Exception.Message
    }

    return [pscustomobject]$writeResult
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

$mcDb = Initialize-MasterControlDbLocal -RepoRoot $repoRoot

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
                mc_db_available = [bool]$mcDb.available
                mc_db_error = [string]$mcDb.error
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

    $script:Stage = "write_master_control_db"

    $mcWrite = Write-MasterControlDeltaPlanLocal `
        -McDbAvailable ([bool]$mcDb.available) `
        -Summary $summary `
        -Rows @($rows) `
        -PlanCsv $planCsv `
        -SummaryJson $summaryJson

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
                mc_db_available = [bool]$mcDb.available
                mc_db_attempted = [bool]$mcWrite.attempted
                mc_db_summary_written = [bool]$mcWrite.summary_written
                mc_db_detail_written_count = [int]$mcWrite.detail_written_count
                mc_db_error = [string]$mcWrite.error
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
                mc_db_available = [bool]$mcDb.available
                mc_db_attempted = [bool]$mcWrite.attempted
                mc_db_summary_written = [bool]$mcWrite.summary_written
                mc_db_detail_written_count = [int]$mcWrite.detail_written_count
                mc_db_error = [string]$mcWrite.error
            } | Out-Null
    }

    $mcDbStatusText = "mc_db_available=$($mcDb.available) mc_db_attempted=$($mcWrite.attempted) mc_db_summary_written=$($mcWrite.summary_written) mc_db_detail_written_count=$($mcWrite.detail_written_count)"
    if (-not [string]::IsNullOrWhiteSpace([string]$mcWrite.error)) {
        $mcDbStatusText = "$mcDbStatusText mc_db_error=""$($mcWrite.error)"""
    }

    Write-Output ("OK: provider snapshot delta plan completed. status={0} read_only=True provider_calls=False db_imported=False snapshot_summary_count={1} {2} output_root=""{3}"" run_id={4}" -f `
        $statusValue, `
        @($rows).Count, `
        $mcDbStatusText, `
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
                mc_db_available = if ($null -ne $mcDb) { [bool]$mcDb.available } else { $false }
                mc_db_error = if ($null -ne $mcDb) { [string]$mcDb.error } else { "" }
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
                mc_db_available = if ($null -ne $mcDb) { [bool]$mcDb.available } else { $false }
                mc_db_error = if ($null -ne $mcDb) { [string]$mcDb.error } else { "" }
            } | Out-Null
    }

    Write-Error "FAILED: provider snapshot delta plan failed. run_id=$script:RunId $errorMessage"
    exit 1
}
