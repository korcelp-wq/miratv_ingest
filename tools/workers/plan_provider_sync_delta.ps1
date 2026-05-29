<#
.SYNOPSIS
    Dry-run provider sync delta planner for Live, VOD, Series, and EPG.

.DESCRIPTION
    Reads:
      - tools\config\provider_sync_delta_model.json
      - tools\config\master_control_ingest_manifest.json

    Emits a governed dry-run plan for:
      - conceptual media-type delta model
      - provider_pull_spine acquisition groups
      - import/call groups
      - state marker groups

    This worker does not query providers, does not mutate DB state, does not upload
    files, and does not call remote endpoints. It exists to establish the clean
    governed planning surface that will replace bulk/grinder-first thinking.

    Intended clean-repo location:
        tools\workers\plan_provider_sync_delta.ps1
#>

[CmdletBinding()]
param(
    [string]$WorkerName = "plan_provider_sync_delta",
    [string]$Component = "provider_sync_delta",
    [string]$Environment = "dev",
    [string]$KillSwitchName = "ENABLE_PROVIDER_SYNC_DELTA_PLANNER",

    [string]$ModelPath = "",
    [string]$ManifestPath = "",
    [string]$OutputRoot = "runtime/reports/provider_sync_delta",

    [switch]$IncludeManifestSummary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-RepoRootLocal {
    [CmdletBinding()]
    param()

    $scriptDir = Split-Path -Parent $PSCommandPath
    $rootCandidate = Join-Path $scriptDir "..\.."
    $resolved = Resolve-Path -Path $rootCandidate -ErrorAction SilentlyContinue
    if ($null -ne $resolved) {
        return $resolved.Path
    }

    return (Get-Location).Path
}

function New-RunIdLocal {
    [CmdletBinding()]
    param([string]$Prefix = "provider-sync-delta-plan")

    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
    $guid = [guid]::NewGuid().ToString("N")
    return "$Prefix-$stamp-$guid"
}

function New-DirectoryLocal {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Convert-ToArrayLocal {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return @() }
    if ($Value -is [array]) { return @($Value) }
    return @($Value)
}

function Test-KillSwitchCompatible {
    [CmdletBinding()]
    param(
        [string]$Name,
        [bool]$DefaultEnabled = $true
    )

    $cmd = Get-Command Test-KillSwitch -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        return $DefaultEnabled
    }

    $result = Test-KillSwitch -Name $Name -DefaultEnabled $DefaultEnabled

    if ($result -is [bool]) {
        return [bool]$result
    }

    if ($null -ne $result -and ($result.PSObject.Properties.Name -contains "enabled")) {
        return [bool]$result.enabled
    }

    if ($null -ne $result -and ($result.PSObject.Properties.Name -contains "is_enabled")) {
        return [bool]$result.is_enabled
    }

    return $DefaultEnabled
}

function Get-MediaTypeFromSpineName {
    [CmdletBinding()]
    param([string]$Text = "")

    $value = ([string]$Text).ToLowerInvariant()

    if ($value -match "epg|xmltv") { return "epg" }
    if ($value -match "live") { return "live" }
    if ($value -match "vod|movie") { return "vod" }
    if ($value -match "series") { return "series" }

    return "general"
}

function Get-AcquisitionGroupFromEntry {
    [CmdletBinding()]
    param([object]$Entry)

    $step = ""
    $role = ""
    $uploaded = ""
    $path = ""

    if ($Entry.PSObject.Properties.Name -contains "step_order") { $step = [string]$Entry.step_order }
    if ($Entry.PSObject.Properties.Name -contains "role") { $role = [string]$Entry.role }
    if ($Entry.PSObject.Properties.Name -contains "parent_file_uploaded") { $uploaded = [string]$Entry.parent_file_uploaded }
    if ([string]::IsNullOrWhiteSpace($uploaded) -and ($Entry.PSObject.Properties.Name -contains "uploaded_file")) { $uploaded = [string]$Entry.uploaded_file }
    if ($Entry.PSObject.Properties.Name -contains "current_relative_path") { $path = [string]$Entry.current_relative_path }

    $basis = "$step $role $uploaded $path".ToLowerInvariant()

    if ($basis -match "state|\.last") { return "state_marker" }
    if ($basis -match "import|call") { return "import_call" }
    if ($basis -match "trigger") { return "pull_trigger" }
    if ($basis -match "worker") { return "pull_worker" }
    if ($basis -match "orchestrator|master") { return "pull_orchestrator" }

    return "manifest_entry"
}

function Test-ManifestLocalEntryExists {
    [CmdletBinding()]
    param([object]$Entry)

    $path = ""
    if ($Entry.PSObject.Properties.Name -contains "current_absolute_path") {
        $path = [string]$Entry.current_absolute_path
    }

    if ([string]::IsNullOrWhiteSpace($path)) {
        return $false
    }

    if ($path.StartsWith("server:", [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    if ($path.StartsWith("http", [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    return (Test-Path -LiteralPath $path)
}

function Get-MediaTypePlanRows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Model
    )

    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($mediaType in @("live", "vod", "series", "epg")) {
        if (-not ($Model.media_types.PSObject.Properties.Name -contains $mediaType)) {
            continue
        }

        $spec = $Model.media_types.$mediaType
        $identityKeys = @(Convert-ToArrayLocal -Value $spec.identity_keys)
        $changeFields = @(Convert-ToArrayLocal -Value $spec.change_fields)
        $deltaQuestions = @(Convert-ToArrayLocal -Value $spec.delta_questions)

        $bucket = switch ($mediaType) {
            "live" { "refresh_identity_delta" }
            "vod" { "metadata_repair" }
            "series" { "metadata_repair" }
            "epg" { "epg_import_needed" }
            default { "manual_review" }
        }

        $rows.Add([pscustomobject]@{
            row_type = "media_delta_model"
            media_type = $mediaType
            acquisition_group = ""
            plan_bucket = $bucket
            lane = ""
            step_order = ""
            sub_order = ""
            role = ""
            file_name = ""
            current_relative_path = ""
            local_exists = ""
            identity_key_count = $identityKeys.Count
            change_field_count = $changeFields.Count
            delta_question_count = $deltaQuestions.Count
            normal_action = [string]$spec.normal_action
            fallback_action = [string]$spec.fallback_action
            planned_action = "define_delta_questions"
            write_allowed = $false
            dry_run_only = $true
        }) | Out-Null
    }

    return @($rows.ToArray())
}

function Get-SpineManifestPlanRows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest
    )

    $rows = New-Object System.Collections.Generic.List[object]

    if (-not ($Manifest.PSObject.Properties.Name -contains "provider_pull_spine")) {
        return @($rows.ToArray())
    }

    foreach ($step in Convert-ToArrayLocal -Value $Manifest.provider_pull_spine) {
        $stepOrder = if ($step.PSObject.Properties.Name -contains "step_order") { [string]$step.step_order } else { "" }
        $role = if ($step.PSObject.Properties.Name -contains "role") { [string]$step.role } else { "" }
        $fileName = if ($step.PSObject.Properties.Name -contains "parent_file_uploaded") { [string]$step.parent_file_uploaded } else { "" }
        $relPath = if ($step.PSObject.Properties.Name -contains "current_relative_path") { [string]$step.current_relative_path } else { "" }
        $mediaType = Get-MediaTypeFromSpineName -Text "$stepOrder $role $fileName $relPath"
        $group = Get-AcquisitionGroupFromEntry -Entry $step
        $exists = Test-ManifestLocalEntryExists -Entry $step

        $plannedAction = switch ($group) {
            "pull_orchestrator" { "inspect_current_orchestrator_and_rebuild_as_manifest_driven_dry_run_first" }
            "pull_worker" { "classify_provider_pull_worker_for_future_delta_snapshot" }
            "pull_trigger" { "classify_trigger_for_replacement_by_governed_worker_invocation" }
            "import_call" { "classify_import_call_for_future_delta_import_or_enqueue" }
            "state_marker" { "classify_state_marker_for_replacement_by_structured_snapshot_state" }
            default { "classify_manifest_entry" }
        }

        $rows.Add([pscustomobject]@{
            row_type = "provider_pull_spine_parent"
            media_type = $mediaType
            acquisition_group = $group
            plan_bucket = "refresh_identity_delta"
            lane = "provider_pull_spine"
            step_order = $stepOrder
            sub_order = ""
            role = $role
            file_name = $fileName
            current_relative_path = $relPath
            local_exists = if ($null -eq $exists) { "not_checkable" } else { [string][bool]$exists }
            identity_key_count = ""
            change_field_count = ""
            delta_question_count = ""
            normal_action = ""
            fallback_action = ""
            planned_action = $plannedAction
            write_allowed = $false
            dry_run_only = $true
        }) | Out-Null

        foreach ($sub in Convert-ToArrayLocal -Value $step.subfiles) {
            $subOrder = if ($sub.PSObject.Properties.Name -contains "sub_order") { [string]$sub.sub_order } else { "" }
            $subRole = if ($sub.PSObject.Properties.Name -contains "role") { [string]$sub.role } else { "" }
            $subFile = if ($sub.PSObject.Properties.Name -contains "uploaded_file") { [string]$sub.uploaded_file } else { "" }
            $subPath = if ($sub.PSObject.Properties.Name -contains "current_relative_path") { [string]$sub.current_relative_path } else { "" }
            $subMedia = Get-MediaTypeFromSpineName -Text "$stepOrder $subOrder $subRole $subFile $subPath"
            $subGroup = Get-AcquisitionGroupFromEntry -Entry $sub
            $subExists = Test-ManifestLocalEntryExists -Entry $sub

            $subPlannedAction = switch ($subGroup) {
                "pull_worker" { "future_delta_snapshot_pull_candidate" }
                "pull_trigger" { "future_governed_trigger_replacement_candidate" }
                "import_call" { "future_delta_import_or_enqueue_candidate" }
                "state_marker" { "future_snapshot_state_replacement_candidate" }
                default { "classify_manifest_subentry" }
            }

            $bucket = switch ($subMedia) {
                "epg" { "epg_import_needed" }
                "live" { "refresh_identity_delta" }
                "vod" { "refresh_identity_delta" }
                "series" { "refresh_identity_delta" }
                default { "manual_review" }
            }

            $rows.Add([pscustomobject]@{
                row_type = "provider_pull_spine_subfile"
                media_type = $subMedia
                acquisition_group = $subGroup
                plan_bucket = $bucket
                lane = "provider_pull_spine"
                step_order = $stepOrder
                sub_order = $subOrder
                role = $subRole
                file_name = $subFile
                current_relative_path = $subPath
                local_exists = if ($null -eq $subExists) { "not_checkable" } else { [string][bool]$subExists }
                identity_key_count = ""
                change_field_count = ""
                delta_question_count = ""
                normal_action = ""
                fallback_action = ""
                planned_action = $subPlannedAction
                write_allowed = $false
                dry_run_only = $true
            }) | Out-Null
        }
    }

    return @($rows.ToArray())
}

$script:RunId = New-RunIdLocal
$repoRoot = Get-RepoRootLocal

if ([string]::IsNullOrWhiteSpace($ModelPath)) {
    $ModelPath = Join-Path $repoRoot "tools\config\provider_sync_delta_model.json"
}
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $repoRoot "tools\config\master_control_ingest_manifest.json"
}

$outputRootFull = if ([System.IO.Path]::IsPathRooted($OutputRoot)) { $OutputRoot } else { Join-Path $repoRoot $OutputRoot }
New-DirectoryLocal -Path $outputRootFull

$loggingModule = Join-Path $repoRoot "tools\common\Logging.psm1"
$loggingAvailable = $false
if (Test-Path -LiteralPath $loggingModule) {
    Import-Module $loggingModule -Force -ErrorAction SilentlyContinue
    $loggingAvailable = [bool](Get-Command Write-JobLog -ErrorAction SilentlyContinue)
}

$startedAt = Get-Date
$signalName = "provider_sync_delta_plan_completed"

try {
    $killEnabled = $true
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
                    event_message = "Provider sync delta planner blocked by kill switch."
                    kill_switch_name = $KillSwitchName
                    model_path = $ModelPath
                } | Out-Null

            Write-Output "BLOCKED: provider sync delta planner blocked. run_id=$script:RunId kill_switch=$KillSwitchName"
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
                event_message = "Provider sync delta planner started."
                model_path = $ModelPath
                manifest_path = $ManifestPath
                dry_run_only = $true
            } | Out-Null
    }

    if (-not (Test-Path -LiteralPath $ModelPath)) {
        throw "Delta model not found: $ModelPath"
    }

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw "Master Control ingest manifest not found: $ManifestPath"
    }

    $model = Get-Content -LiteralPath $ModelPath -Raw | ConvertFrom-Json
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json

    $mediaRows = @(Get-MediaTypePlanRows -Model $model)
    $spineRows = @(Get-SpineManifestPlanRows -Manifest $manifest)
    $rows = @($mediaRows + $spineRows)

    $manifestSummary = [pscustomobject]@{
        manifest_present = $true
        series_lane_steps = if ($manifest.PSObject.Properties.Name -contains "series_lane") { @(Convert-ToArrayLocal -Value $manifest.series_lane).Count } else { 0 }
        epg_lane_steps = if ($manifest.PSObject.Properties.Name -contains "epg_lane") { @(Convert-ToArrayLocal -Value $manifest.epg_lane).Count } else { 0 }
        provider_pull_spine_steps = if ($manifest.PSObject.Properties.Name -contains "provider_pull_spine") { @(Convert-ToArrayLocal -Value $manifest.provider_pull_spine).Count } else { 0 }
    }

    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $planCsv = Join-Path $outputRootFull "provider_sync_delta_plan_$stamp.csv"
    $summaryJson = Join-Path $outputRootFull "provider_sync_delta_plan_summary_$stamp.json"

    $rows | Export-Csv -LiteralPath $planCsv -NoTypeInformation -Encoding UTF8

    $planBuckets = @(Convert-ToArrayLocal -Value $model.plan_buckets)
    $mediaTypes = @($rows | Where-Object { $_.row_type -eq "media_delta_model" } | Select-Object -ExpandProperty media_type)

    $spineMediaCounts = @(
        $spineRows |
            Group-Object media_type |
            Sort-Object Name |
            ForEach-Object { [pscustomobject]@{ media_type = $_.Name; count = $_.Count } }
    )

    $spineGroupCounts = @(
        $spineRows |
            Group-Object acquisition_group |
            Sort-Object Name |
            ForEach-Object { [pscustomobject]@{ acquisition_group = $_.Name; count = $_.Count } }
    )

    $summary = [pscustomobject]@{
        run_id = $script:RunId
        worker_name = $WorkerName
        component = $Component
        environment = $Environment
        model_name = [string]$model.model_name
        model_version = [string]$model.version
        dry_run_only = $true
        media_type_count = $mediaTypes.Count
        media_types = $mediaTypes
        plan_bucket_count = $planBuckets.Count
        plan_buckets = $planBuckets
        provider_pull_spine_rows = $spineRows.Count
        provider_pull_spine_media_counts = $spineMediaCounts
        provider_pull_spine_group_counts = $spineGroupCounts
        manifest_summary = $manifestSummary
        plan_csv = $planCsv
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    }

    $summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $summaryJson -Encoding UTF8

    $durationMs = [int]((Get-Date) - $startedAt).TotalMilliseconds

    if ($loggingAvailable) {
        Write-JobLog `
            -RunId $script:RunId `
            -JobName $WorkerName `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -EventType "worker_completed" `
            -Status "pass" `
            -Data @{
                event_message = "Provider sync delta planner completed."
                dry_run_only = $true
                media_type_count = $summary.media_type_count
                plan_bucket_count = $summary.plan_bucket_count
                provider_pull_spine_rows = $summary.provider_pull_spine_rows
                output_root = $outputRootFull
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
            -SignalValue "pass" `
            -Status "pass" `
            -AllowedValues "pass|warning|fail|disabled" `
            -SourceTableOrEndpoint "tools/workers/plan_provider_sync_delta.ps1" `
            -Data @{
                dashboard_panel = "Provider Sync"
                widget_key = "provider.sync.delta.plan"
                owner = "Content Ops"
                kill_switch_name = $KillSwitchName
                dry_run_only = $true
                media_type_count = $summary.media_type_count
                plan_bucket_count = $summary.plan_bucket_count
                provider_pull_spine_rows = $summary.provider_pull_spine_rows
                plan_csv = $planCsv
                summary_json = $summaryJson
            } | Out-Null
    }

    Write-Output ("OK: provider sync delta plan completed. status=pass dry_run_only=True media_type_count={0} plan_bucket_count={1} provider_pull_spine_rows={2} output_root=""{3}"" run_id={4}" -f `
        $summary.media_type_count, `
        $summary.plan_bucket_count, `
        $summary.provider_pull_spine_rows, `
        $outputRootFull, `
        $script:RunId)

    Write-Output ("FILES: plan_csv=""{0}"" summary_json=""{1}""" -f $planCsv, $summaryJson)
}
catch {
    $errorMessage = $_.Exception.Message

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
                event_message = "Provider sync delta planner failed."
                error = $errorMessage
                model_path = $ModelPath
                manifest_path = $ManifestPath
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
            -SourceTableOrEndpoint "tools/workers/plan_provider_sync_delta.ps1" `
            -Data @{
                dashboard_panel = "Provider Sync"
                widget_key = "provider.sync.delta.plan"
                owner = "Content Ops"
                kill_switch_name = $KillSwitchName
                error = $errorMessage
            } | Out-Null
    }

    Write-Error "FAILED: provider sync delta planner failed. run_id=$script:RunId error=$errorMessage"
    exit 1
}
