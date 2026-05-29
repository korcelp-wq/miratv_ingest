<#
.SYNOPSIS
  Normalize the master control ingest manifest into a unified import route registry.

.DESCRIPTION
  Read-only worker that consumes tools/config/master_control_ingest_manifest.json and
  flattens lane entries/subfiles into a route registry.

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
    [string]$ManifestPath = "",
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "normalize_master_control_manifest_to_import_route_registry"
$Component = "master_control_import_route_registry"
$DatabaseTarget = "none"
$SourceName = "master_control_ingest_manifest"
$KillSwitchName = "ENABLE_MASTER_CONTROL_ROUTE_REGISTRY_NORMALIZER"

$CompletedSignal = "master_control_route_registry_normalized_completed"
$RouteCountSignal = "master_control_route_registry_route_count"
$ImportRouteCountSignal = "master_control_route_registry_import_route_count"
$ReviewRouteCountSignal = "master_control_route_registry_review_route_count"

$StartedAt = Get-Date
$RunId = "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 16))"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$OutputRoot = Join-Path $RepoRoot "runtime\reports\unified_import_route_registry"
$LogRoot = Join-Path $RepoRoot "runtime\logs\unified_import_route_registry"

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

function Get-TextValue {
    param([object]$Object, [string]$Name, [string]$Default = "")

    if ($null -eq $Object) { return $Default }

    $property = $Object.PSObject.Properties |
        Where-Object { $_.Name -ieq $Name } |
        Select-Object -First 1

    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return [string]$property.Value
}

function Get-RouteType {
    param([string]$Path, [string]$Role, [string]$ExecutionType, [string]$Purpose)

    $text = ("$Path $Role $ExecutionType $Purpose").ToLowerInvariant()

    if ($text -match "server:/.*\.php|server_side|endpoint|remote_import|remote_trigger|remote_materialization") { return "php_endpoint_or_server_worker" }
    if ($text -match "ftp_upload|upload_trigger|upload ") { return "server_upload" }
    if ($text -match "query_content|query_helper") { return "query_helper" }
    if ($text -match "import_.*\.ps1|provider_payload_import|import-call|import_call") { return "powershell_import_wrapper" }
    if ($text -match "pull_.*worker|provider_pull_worker|snapshot") { return "provider_pull_worker" }
    if ($text -match "grinder") { return "local_grinder_worker" }
    if ($text -match "trigger|\.bat|runner") { return "trigger_or_orchestrator" }
    if ($text -match "\.ps1") { return "local_powershell_worker" }

    return "unknown"
}

function Get-MediaTypeGuess {
    param([string]$Lane, [string]$Path, [string]$Role, [string]$Purpose, [string]$SubOrder)

    $text = ("$Lane $Path $Role $Purpose $SubOrder").ToLowerInvariant()

    if ($text -match "vod|movie") { return "vod" }
    if ($text -match "live|channel") { return "live" }
    if ($text -match "series|episode|season") { return "series" }
    if ($text -match "epg|xmltv") { return "epg" }

    return "unknown"
}

function Get-OperationGuess {
    param([string]$Path, [string]$Role, [string]$ExecutionType, [string]$Purpose)

    $text = ("$Path $Role $ExecutionType $Purpose").ToLowerInvariant()

    if ($text -match "import") { return "import" }
    if ($text -match "upload") { return "upload" }
    if ($text -match "pull|download|provider api|snapshot") { return "pull" }
    if ($text -match "grind|extract|normalize|clean") { return "transform" }
    if ($text -match "materialize") { return "materialize" }
    if ($text -match "finalize") { return "finalize" }
    if ($text -match "route") { return "route" }
    if ($text -match "state") { return "state" }
    if ($text -match "trigger|orchestrator|runner") { return "orchestrate" }

    return "unknown"
}

function Get-RiskLevel {
    param([string]$RouteType, [string]$Operation, [string]$SecretRisk, [string]$ContractGap, [string]$Path)

    $text = ("$RouteType $Operation $SecretRisk $ContractGap $Path").ToLowerInvariant()

    if ($text -match "token|secret|credential|endpoint_or_import_token|provider_credential") { return "high" }
    if ($text -match "import|server_worker|php_endpoint|server_upload|db|write|bounded writes") { return "medium_high" }
    if ($text -match "grinder|transform|local_worker") { return "medium" }

    return "low_to_unknown"
}

function Get-RecommendedAction {
    param([string]$RouteType, [string]$Operation, [string]$MediaType, [string]$MigrationStatus, [string]$CleanRepoTarget)

    $text = ("$RouteType $Operation $MediaType $MigrationStatus $CleanRepoTarget").ToLowerInvariant()

    if ($text -match "provider_payload_import|delta_import|enqueue|import") { return "wrap_as_governed_delta_import_or_enqueue_worker" }
    if ($RouteType -eq "php_endpoint_or_server_worker") { return "add_php_logging_signal_killswitch_adapter_before_use" }
    if ($RouteType -eq "server_upload") { return "rewrite_with_secure_upload_bounded_retry" }
    if ($RouteType -eq "query_helper") { return "inspect_query_helper_and_register_as_adapter_dependency" }
    if ($RouteType -eq "provider_pull_worker") { return "already_replaced_by_provider_snapshot_spine_or_compare_for_gap" }
    if ($RouteType -eq "local_grinder_worker") { return "fold_into_row_resilient_disposition_grinder_contract" }

    return "manual_review"
}

function New-RegistryRow {
    param([string]$SourceLaneName, [object]$Parent, [object]$Child, [bool]$IsSubfile)

    $lane = Get-TextValue -Object $Parent -Name "lane" -Default $SourceLaneName
    $stepOrder = Get-TextValue -Object $Parent -Name "step_order"
    $subOrder = if ($IsSubfile) { Get-TextValue -Object $Child -Name "sub_order" } else { "" }

    $uploadedFile = if ($IsSubfile) { Get-TextValue -Object $Child -Name "uploaded_file" } else { Get-TextValue -Object $Parent -Name "parent_file_uploaded" }
    $actualFile = if ($IsSubfile) { Get-TextValue -Object $Child -Name "actual_file_hint" } else { Get-TextValue -Object $Parent -Name "actual_file_hint" }
    $relativePath = if ($IsSubfile) { Get-TextValue -Object $Child -Name "current_relative_path" } else { Get-TextValue -Object $Parent -Name "current_relative_path" }
    $absolutePath = if ($IsSubfile) { Get-TextValue -Object $Child -Name "current_absolute_path" } else { Get-TextValue -Object $Parent -Name "current_absolute_path" }
    $role = if ($IsSubfile) { Get-TextValue -Object $Child -Name "role" } else { Get-TextValue -Object $Parent -Name "role" }
    $purpose = if ($IsSubfile) { Get-TextValue -Object $Child -Name "purpose" } else { Get-TextValue -Object $Parent -Name "purpose" }

    $executionType = Get-TextValue -Object $Parent -Name "execution_type"
    $cleanRepoTarget = Get-TextValue -Object $Parent -Name "clean_repo_target"
    $migrationStatus = Get-TextValue -Object $Parent -Name "migration_status"
    $contractGap = Get-TextValue -Object $Parent -Name "contract_gap"
    $secretRisk = Get-TextValue -Object $Parent -Name "secret_risk"

    $routeType = Get-RouteType -Path $absolutePath -Role $role -ExecutionType $executionType -Purpose $purpose
    $mediaType = Get-MediaTypeGuess -Lane $lane -Path $absolutePath -Role $role -Purpose $purpose -SubOrder $subOrder
    $operation = Get-OperationGuess -Path $absolutePath -Role $role -ExecutionType $executionType -Purpose $purpose
    $risk = Get-RiskLevel -RouteType $routeType -Operation $operation -SecretRisk $secretRisk -ContractGap $contractGap -Path $absolutePath
    $recommended = Get-RecommendedAction -RouteType $routeType -Operation $operation -MediaType $mediaType -MigrationStatus $migrationStatus -CleanRepoTarget $cleanRepoTarget

    $applyCapable = ($operation -eq "import" -or $routeType -eq "powershell_import_wrapper")
    $dryRunCapable = ($recommended -match "delta_import|enqueue")

    $needsReview = $false
    if ($operation -eq "import" -or $routeType -in @("php_endpoint_or_server_worker", "server_upload", "query_helper", "powershell_import_wrapper", "unknown")) {
        $needsReview = $true
    }

    $routeKeyParts = @($lane, $operation, $mediaType, $stepOrder, $subOrder, $actualFile) |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }

    $routeKey = (($routeKeyParts -join "|").ToLowerInvariant() -replace "[^a-z0-9_\|\.-]+", "_")

    return [pscustomobject][ordered]@{
        route_key = $routeKey
        source_lane_name = $SourceLaneName
        lane = $lane
        step_order = $stepOrder
        sub_order = $subOrder
        is_subfile = $IsSubfile
        uploaded_file = $uploadedFile
        actual_file_hint = $actualFile
        current_relative_path = $relativePath
        current_absolute_path = $absolutePath
        role = $role
        execution_type = $executionType
        purpose = $purpose
        route_type = $routeType
        media_type_guess = $mediaType
        operation_guess = $operation
        apply_capable_guess = $applyCapable
        dry_run_capable_guess = $dryRunCapable
        risk_level = $risk
        needs_review = $needsReview
        clean_repo_target = $cleanRepoTarget
        migration_status = $migrationStatus
        contract_gap = $contractGap
        secret_risk = $secretRisk
        recommended_next_action = $recommended
    }
}

try {
    Write-LocalJsonLog -EventName "job_started" -Status "running" -Data ([ordered]@{
        preview_only = $true
        db_writes = $false
        provider_calls = $false
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

    if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        $ManifestPath = Join-Path $RepoRoot "tools\config\master_control_ingest_manifest.json"
    }

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw "Manifest file not found: $ManifestPath"
    }

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    $rows = @()

    foreach ($lanePropertyName in @("series_lane", "epg_lane", "provider_pull_spine")) {
        $laneProperty = $manifest.PSObject.Properties |
            Where-Object { $_.Name -ieq $lanePropertyName } |
            Select-Object -First 1

        if ($null -eq $laneProperty -or $null -eq $laneProperty.Value) {
            continue
        }

        foreach ($entry in @($laneProperty.Value)) {
            $rows += New-RegistryRow -SourceLaneName $lanePropertyName -Parent $entry -Child $null -IsSubfile $false

            $subfilesProperty = $entry.PSObject.Properties |
                Where-Object { $_.Name -ieq "subfiles" } |
                Select-Object -First 1

            if ($null -ne $subfilesProperty -and $null -ne $subfilesProperty.Value) {
                foreach ($subfile in @($subfilesProperty.Value)) {
                    $rows += New-RegistryRow -SourceLaneName $lanePropertyName -Parent $entry -Child $subfile -IsSubfile $true
                }
            }
        }
    }

    $routeCount = @($rows).Count
    $importRouteCount = @($rows | Where-Object { $_.operation_guess -eq "import" -or $_.route_type -eq "powershell_import_wrapper" }).Count
    $reviewRouteCount = @($rows | Where-Object { $_.needs_review -eq $true }).Count
    $serverRouteCount = @($rows | Where-Object { $_.route_type -eq "php_endpoint_or_server_worker" }).Count
    $uploadRouteCount = @($rows | Where-Object { $_.route_type -eq "server_upload" }).Count
    $queryHelperCount = @($rows | Where-Object { $_.route_type -eq "query_helper" }).Count
    $providerPullCount = @($rows | Where-Object { $_.route_type -eq "provider_pull_worker" }).Count

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
    $registryCsv = Join-Path $OutputRoot "unified_import_route_registry_$timestamp.csv"
    $registryJson = Join-Path $OutputRoot "unified_import_route_registry_$timestamp.json"
    $summaryJson = Join-Path $OutputRoot "unified_import_route_registry_summary_$timestamp.json"

    $rows | Export-Csv -Path $registryCsv -NoTypeInformation
    $rows | ConvertTo-Json -Depth 20 | Set-Content -Path $registryJson -Encoding UTF8

    $summary = [ordered]@{
        status = "pass"
        preview_only = $true
        db_writes = $false
        provider_calls = $false
        worker_name = $WorkerName
        run_id = $RunId
        manifest_path = (Resolve-Path -LiteralPath $ManifestPath).Path
        route_count = $routeCount
        import_route_count = $importRouteCount
        review_route_count = $reviewRouteCount
        server_route_count = $serverRouteCount
        upload_route_count = $uploadRouteCount
        query_helper_count = $queryHelperCount
        provider_pull_route_count = $providerPullCount
        registry_csv = $registryCsv
        registry_json = $registryJson
        summary_json = $summaryJson
        duration_ms = Get-DurationMs -Start $StartedAt
    }

    $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $summaryJson -Encoding UTF8

    Emit-LocalSignal -SignalName $CompletedSignal -SignalValue "pass" -Payload $summary
    Emit-LocalSignal -SignalName $RouteCountSignal -SignalValue $routeCount -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $ImportRouteCountSignal -SignalValue $importRouteCount -Payload ([ordered]@{ run_id = $RunId })
    Emit-LocalSignal -SignalName $ReviewRouteCountSignal -SignalValue $reviewRouteCount -Payload ([ordered]@{ run_id = $RunId })

    Emit-LocalHeartbeat -Status "ok"
    Write-LocalJsonLog -EventName "job_completed" -Status "pass" -Data $summary

    if (-not $Quiet) {
        Write-Output "OK: master control manifest normalized to route registry. status=pass routes=$routeCount import_routes=$importRouteCount review_routes=$reviewRouteCount db_writes=False provider_calls=False run_id=$RunId"
        Write-Output "FILES: registry_csv=$registryCsv registry_json=$registryJson summary_json=$summaryJson"
        $rows |
            Where-Object { $_.operation_guess -eq "import" -or $_.route_type -in @("powershell_import_wrapper", "php_endpoint_or_server_worker", "server_upload", "query_helper") } |
            Select-Object -First 25 route_key, lane, actual_file_hint, route_type, media_type_guess, operation_guess, risk_level, recommended_next_action |
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

    Write-Error "FAILED: master control manifest route registry normalization failed. $message run_id=$RunId"
    exit 1
}
