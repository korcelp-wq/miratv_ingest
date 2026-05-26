# MiraTV User Item Availability Refresh Worker
# File: tools/workers/refresh_user_item_availability.ps1
# Purpose:
#   P0.1 availability refresh lane scaffold for user/provider item availability.
#   Establishes the automation contract for item-level entitlement/access refresh.
#
# Current implementation:
#   - Local-first, no DB writes yet.
#   - Supports DryRun and SnapshotInput modes.
#   - Emits availability signals and structured logs.
#   - Does not hard-delete anything.
#   - Designed to be extended with DB/query bridge and provider API calls later.
#
# Signals:
#   - availability_refresh_status
#   - availability_refresh_lag_minutes
#   - worker_heartbeat_status
#
# Kill switch:
#   - ENABLE_AVAILABILITY_REFRESH
#
# Usage:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/refresh_user_item_availability.ps1" -Environment "dev"
#
# Optional snapshot input:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/refresh_user_item_availability.ps1" `
#     -Environment "dev" `
#     -Mode "SnapshotInput" `
#     -InputJsonPath "runtime/samples/item_availability_snapshot.json"

[CmdletBinding()]
param(
    [string]$WorkerName = "availability_item_worker",
    [string]$Component = "availability_item_worker",
    [string]$Environment = "prod",
    [string]$KillSwitchName = "ENABLE_AVAILABILITY_REFRESH",

    [ValidateSet("DryRun", "SnapshotInput")]
    [string]$Mode = "DryRun",

    [string]$InputJsonPath = "",
    [string]$MacUserId = "",
    [string]$Provider = "",
    [string]$MediaType = "",
    [int]$MaxStalenessMinutes = 30,
    [int]$HeartbeatIntervalSeconds = 600,
    [int]$StaleAfterSeconds = 1800,
    [string]$LogRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:StartedAt = Get-Date
$script:RunId = $null

function Get-ScriptRepoRoot {
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

function Get-DurationMs {
    [CmdletBinding()]
    param(
        [datetime]$Start
    )

    $elapsed = (Get-Date) - $Start
    return [int][math]::Round($elapsed.TotalMilliseconds, 0)
}

function Resolve-RepoRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return Join-Path $RepoRoot $Path
}

function Read-AvailabilitySnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Input snapshot not found: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Input snapshot is empty: $Path"
    }

    return $raw | ConvertFrom-Json -ErrorAction Stop
}

function Convert-ToArray {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        return @($Value)
    }

    return @($Value)
}

function Get-SnapshotItems {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Snapshot
    )

    if ($null -eq $Snapshot) {
        return @()
    }

    if ($Snapshot.PSObject.Properties.Name -contains "items") {
        return Convert-ToArray -Value $Snapshot.items
    }

    if ($Snapshot.PSObject.Properties.Name -contains "availability_items") {
        return Convert-ToArray -Value $Snapshot.availability_items
    }

    if ($Snapshot.PSObject.Properties.Name -contains "entitlements") {
        return Convert-ToArray -Value $Snapshot.entitlements
    }

    return Convert-ToArray -Value $Snapshot
}

function Get-PropertyValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Object,

        [string[]]$Names
    )

    if ($null -eq $Object) {
        return $null
    }

    foreach ($name in $Names) {
        if ($Object.PSObject.Properties.Name -contains $name) {
            return $Object.$name
        }
    }

    return $null
}

function Get-AvailabilityMetrics {
    [CmdletBinding()]
    param(
        [object[]]$Items
    )

    $total = @($Items).Count
    $available = 0
    $unavailable = 0
    $stale = 0
    $unknown = 0
    $live = 0
    $vod = 0
    $series = 0

    foreach ($item in $Items) {
        $statusRaw = Get-PropertyValue -Object $item -Names @("status", "availability_status", "state", "is_available", "available")
        $status = ""

        if ($null -ne $statusRaw) {
            $status = ([string]$statusRaw).Trim().ToLowerInvariant()
        }

        if ($status -in @("1", "true", "available", "active", "ok", "allowed", "entitled")) {
            $available++
        }
        elseif ($status -in @("0", "false", "unavailable", "inactive", "disabled", "denied", "not_entitled")) {
            $unavailable++
        }
        elseif ($status -in @("stale", "expired")) {
            $stale++
        }
        else {
            $unknown++
        }

        $mediaRaw = Get-PropertyValue -Object $item -Names @("media_type", "content_type", "type", "bouquet_type")
        $media = ""

        if ($null -ne $mediaRaw) {
            $media = ([string]$mediaRaw).Trim().ToLowerInvariant()
        }

        if ($media -eq "live") {
            $live++
        }
        elseif ($media -eq "vod" -or $media -eq "movie" -or $media -eq "movies") {
            $vod++
        }
        elseif ($media -eq "series" -or $media -eq "show" -or $media -eq "tv") {
            $series++
        }
    }

    return [ordered]@{
        total = $total
        available = $available
        unavailable = $unavailable
        stale = $stale
        unknown = $unknown
        live = $live
        vod = $vod
        series = $series
    }
}

function Get-RefreshLagMinutes {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Snapshot
    )

    if ($null -eq $Snapshot) {
        return 0
    }

    $lastSuccessRaw = Get-PropertyValue -Object $Snapshot -Names @("last_success_at", "refreshed_at", "created_at", "snapshot_at")

    if ($null -eq $lastSuccessRaw) {
        return 0
    }

    $parsed = [datetime]::MinValue

    if ([datetime]::TryParse([string]$lastSuccessRaw, [ref]$parsed)) {
        $age = (Get-Date).ToUniversalTime() - $parsed.ToUniversalTime()
        return [int][math]::Max(0, [math]::Round($age.TotalMinutes, 0))
    }

    return 0
}

$repoRoot = Get-ScriptRepoRoot
$loggingModule = Join-Path $repoRoot "tools\common\Logging.psm1"

if (-not (Test-Path -LiteralPath $loggingModule)) {
    throw "Logging module not found at: $loggingModule"
}

Import-Module $loggingModule -Force

$script:RunId = New-RunId -Prefix "item-availability-refresh"

try {
    $enabled = Test-KillSwitch -Name $KillSwitchName -DefaultEnabled $true

    if (-not $enabled) {
        Write-JobLog `
            -RunId $script:RunId `
            -JobName "refresh_user_item_availability" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -Status "job_skipped" `
            -EventType "job_skipped" `
            -SourceName "provider_item_availability" `
            -DurationMs (Get-DurationMs -Start $script:StartedAt) `
            -Data @{
                kill_switch_name = $KillSwitchName
                kill_switch_enabled = $false
                reason = "item availability refresh disabled by kill switch"
                mode = $Mode
            } `
            -LogRoot $LogRoot | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName "refresh_user_item_availability" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName "availability_refresh_status" `
            -P0Item "P0.1" `
            -SignalValue "disabled" `
            -Status "disabled" `
            -AllowedValues "ok|stale|failed|disabled|dry_run" `
            -SourceTableOrEndpoint "tools/workers/refresh_user_item_availability.ps1" `
            -Data @{
                dashboard_panel = "Availability"
                widget_key = "availability.refresh.status"
                owner = "IP Ops"
                kill_switch_name = $KillSwitchName
                availability_scope = "item"
            } `
            -LogRoot $LogRoot | Out-Null

        Write-Output "SKIPPED: $KillSwitchName is disabled. run_id=$script:RunId"
        exit 0
    }

    Write-JobLog `
        -RunId $script:RunId `
        -JobName "refresh_user_item_availability" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -Status "job_started" `
        -EventType "job_started" `
        -SourceName "provider_item_availability" `
        -Data @{
            kill_switch_name = $KillSwitchName
            mode = $Mode
            mac_user_id = $MacUserId
            provider = $Provider
            media_type = $MediaType
            max_staleness_minutes = $MaxStalenessMinutes
            availability_scope = "item"
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Heartbeat `
        -RunId $script:RunId `
        -JobName "refresh_user_item_availability" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -HeartbeatStatus "ok" `
        -HeartbeatIntervalSeconds $HeartbeatIntervalSeconds `
        -StaleAfterSeconds $StaleAfterSeconds `
        -Data @{
            signal_name = "worker_heartbeat_status"
            p0_item = "P0.2"
            kill_switch_name = $KillSwitchName
            availability_scope = "item"
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "refresh_user_item_availability" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "worker_heartbeat_status" `
        -P0Item "P0.2" `
        -SignalValue "ok" `
        -Status "ok" `
        -AllowedValues "ok|missed|failed|disabled" `
        -SourceTableOrEndpoint "tools/workers/refresh_user_item_availability.ps1" `
        -Data @{
            dashboard_panel = "Worker Health"
            widget_key = "worker.heartbeat.status"
            owner = "SRE"
            kill_switch_name = $KillSwitchName
            availability_scope = "item"
        } `
        -LogRoot $LogRoot | Out-Null

    $snapshot = $null
    $items = @()
    $sourceName = "dry_run_no_provider_call"
    $status = "dry_run"
    $refreshLagMinutes = 0

    if ($Mode -eq "SnapshotInput") {
        if ([string]::IsNullOrWhiteSpace($InputJsonPath)) {
            throw "InputJsonPath is required when Mode=SnapshotInput."
        }

        $resolvedInput = Resolve-RepoRelativePath -RepoRoot $repoRoot -Path $InputJsonPath
        $snapshot = Read-AvailabilitySnapshot -Path $resolvedInput
        $items = Get-SnapshotItems -Snapshot $snapshot
        $sourceName = $resolvedInput
        $refreshLagMinutes = Get-RefreshLagMinutes -Snapshot $snapshot
        $status = "ok"

        if ($refreshLagMinutes -gt $MaxStalenessMinutes) {
            $status = "stale"
        }
    }

    $metrics = Get-AvailabilityMetrics -Items $items

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "refresh_user_item_availability" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "availability_refresh_status" `
        -P0Item "P0.1" `
        -SignalValue $status `
        -Status $status `
        -AllowedValues "ok|stale|failed|disabled|dry_run" `
        -SourceTableOrEndpoint "tools/workers/refresh_user_item_availability.ps1" `
        -MacUserId $MacUserId `
        -Data @{
            dashboard_panel = "Availability"
            widget_key = "availability.refresh.status"
            owner = "IP Ops"
            kill_switch_name = $KillSwitchName
            mode = $Mode
            provider = $Provider
            media_type = $MediaType
            source_name = $sourceName
            availability_scope = "item"
            total = $metrics.total
            available = $metrics.available
            unavailable = $metrics.unavailable
            stale = $metrics.stale
            unknown = $metrics.unknown
            live = $metrics.live
            vod = $metrics.vod
            series = $metrics.series
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "refresh_user_item_availability" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "availability_refresh_lag_minutes" `
        -P0Item "P0.1" `
        -SignalValue ([string]$refreshLagMinutes) `
        -ValueNum ([decimal]$refreshLagMinutes) `
        -Status $status `
        -AllowedValues "0+" `
        -SourceTableOrEndpoint "tools/workers/refresh_user_item_availability.ps1" `
        -MacUserId $MacUserId `
        -Data @{
            dashboard_panel = "Availability"
            widget_key = "availability.refresh.lag_minutes"
            owner = "IP Ops"
            kill_switch_name = $KillSwitchName
            max_staleness_minutes = $MaxStalenessMinutes
            mode = $Mode
            provider = $Provider
            media_type = $MediaType
            availability_scope = "item"
        } `
        -LogRoot $LogRoot | Out-Null

    Write-JobLog `
        -RunId $script:RunId `
        -JobName "refresh_user_item_availability" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -Status "job_completed" `
        -EventType "job_completed" `
        -SourceName $sourceName `
        -SourceRowCount $metrics.total `
        -RowsInserted 0 `
        -RowsUpdated 0 `
        -RowsSkipped $metrics.total `
        -RowsFailed 0 `
        -DurationMs (Get-DurationMs -Start $script:StartedAt) `
        -Data @{
            availability_refresh_status = $status
            availability_refresh_lag_minutes = $refreshLagMinutes
            availability_scope = "item"
            mode = $Mode
            mac_user_id = $MacUserId
            provider = $Provider
            media_type = $MediaType
            total = $metrics.total
            available = $metrics.available
            unavailable = $metrics.unavailable
            stale = $metrics.stale
            unknown = $metrics.unknown
            live = $metrics.live
            vod = $metrics.vod
            series = $metrics.series
            note = "local-first scaffold; no DB/provider write performed"
        } `
        -LogRoot $LogRoot | Out-Null

    Write-Output "OK: item availability refresh scaffold completed. status=$status mode=$Mode total=$($metrics.total) lag_minutes=$refreshLagMinutes run_id=$script:RunId"
    exit 0
}
catch {
    $message = $_.Exception.Message
    $duration = Get-DurationMs -Start $script:StartedAt

    if ([string]::IsNullOrWhiteSpace($script:RunId)) {
        $script:RunId = "item-availability-refresh-failed-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
    }

    try {
        Write-JobLog `
            -RunId $script:RunId `
            -JobName "refresh_user_item_availability" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -Status "job_failed" `
            -EventType "job_failed" `
            -SourceName "provider_item_availability" `
            -DurationMs $duration `
            -ErrorCode "ITEM_AVAILABILITY_REFRESH_FAILED" `
            -ErrorMessage $message `
            -Data @{
                kill_switch_name = $KillSwitchName
                mode = $Mode
                mac_user_id = $MacUserId
                provider = $Provider
                media_type = $MediaType
                availability_scope = "item"
            } `
            -LogRoot $LogRoot | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName "refresh_user_item_availability" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName "availability_refresh_status" `
            -P0Item "P0.1" `
            -SignalValue "failed" `
            -Status "failed" `
            -AllowedValues "ok|stale|failed|disabled|dry_run" `
            -SourceTableOrEndpoint "tools/workers/refresh_user_item_availability.ps1" `
            -MacUserId $MacUserId `
            -ErrorCode "ITEM_AVAILABILITY_REFRESH_FAILED" `
            -ErrorMessage $message `
            -Data @{
                dashboard_panel = "Availability"
                widget_key = "availability.refresh.status"
                owner = "IP Ops"
                kill_switch_name = $KillSwitchName
                mode = $Mode
                provider = $Provider
                media_type = $MediaType
                availability_scope = "item"
            } `
            -LogRoot $LogRoot | Out-Null
    }
    catch {
        Write-Error "Item availability worker failed and failed to log error: $($_.Exception.Message)"
    }

    Write-Error "FAILED: item availability refresh worker failed. run_id=$script:RunId error=$message"
    exit 1
}