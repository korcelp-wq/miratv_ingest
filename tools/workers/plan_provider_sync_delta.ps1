<#
.SYNOPSIS
    Dry-run provider sync delta planner for Live, VOD, Series, and EPG.

.DESCRIPTION
    Reads tools\config\provider_sync_delta_model.json and emits a governed dry-run
    plan signal describing the delta model and planned update buckets.

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

function ConvertTo-JsonSafeLocal {
    [CmdletBinding()]
    param([AllowNull()][object]$Value, [int]$Depth = 10)

    try { return ($Value | ConvertTo-Json -Depth $Depth -Compress) }
    catch { return "{}" }
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
            media_type = $mediaType
            plan_bucket = $bucket
            identity_key_count = $identityKeys.Count
            change_field_count = $changeFields.Count
            delta_question_count = $deltaQuestions.Count
            normal_action = [string]$spec.normal_action
            fallback_action = [string]$spec.fallback_action
            write_allowed = $false
            dry_run_only = $true
        }) | Out-Null
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

    $model = Get-Content -LiteralPath $ModelPath -Raw | ConvertFrom-Json
    $rows = @(Get-MediaTypePlanRows -Model $model)

    $manifestSummary = [pscustomobject]@{
        manifest_present = (Test-Path -LiteralPath $ManifestPath)
        series_lane_steps = 0
        epg_lane_steps = 0
    }

    if ($IncludeManifestSummary -and (Test-Path -LiteralPath $ManifestPath)) {
        $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
        $manifestSummary = [pscustomobject]@{
            manifest_present = $true
            series_lane_steps = @(Convert-ToArrayLocal -Value $manifest.series_lane).Count
            epg_lane_steps = @(Convert-ToArrayLocal -Value $manifest.epg_lane).Count
        }
    }

    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $planCsv = Join-Path $outputRootFull "provider_sync_delta_plan_$stamp.csv"
    $summaryJson = Join-Path $outputRootFull "provider_sync_delta_plan_summary_$stamp.json"

    $rows | Export-Csv -LiteralPath $planCsv -NoTypeInformation -Encoding UTF8

    $planBuckets = @(Convert-ToArrayLocal -Value $model.plan_buckets)
    $mediaTypes = @($rows | Select-Object -ExpandProperty media_type)

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
        live_update_planning_enabled = ($mediaTypes -contains "live")
        vod_update_planning_enabled = ($mediaTypes -contains "vod")
        series_update_planning_enabled = ($mediaTypes -contains "series")
        epg_update_planning_enabled = ($mediaTypes -contains "epg")
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
                plan_csv = $planCsv
                summary_json = $summaryJson
            } | Out-Null
    }

    Write-Output ("OK: provider sync delta plan completed. status=pass dry_run_only=True media_type_count={0} plan_bucket_count={1} output_root=""{2}"" run_id={3}" -f `
        $summary.media_type_count, `
        $summary.plan_bucket_count, `
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
