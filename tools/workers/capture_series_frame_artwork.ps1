# MiraTV Series Frame Capture Artwork Worker
# File: tools/workers/capture_series_frame_artwork.ps1
# Purpose:
#   P0.6 Materialization worker scaffold for resolving series_port_900_image_repair rows by
#   validating actual provider media and, in a later live phase, generating fallback artwork
#   from captured media frames.
#
# Current implementation:
#   - Supports DryRun, SnapshotInput, DbQuery, and ProbeOnly modes.
#   - DbQuery mode uses tools/common/DbQuery.psm1, which calls dog_open_proc.php.
#   - DbQuery mode reads candidate rows from xpdgxfsp_ip.content_materialization_queue.
#   - ResolveEpisodePreview optionally resolves provider_series_id to a first episode URL preview.
#   - ProbeResolvedEpisodePreview optionally probes resolved episode URLs in memory and logs only redacted summaries.
#   - MAT-7 classifies resolved probe failures into provider/network/container/tooling buckets.
#   - MAT-8 exposes safe ffprobe exit-code and stderr hint summaries for unknown probe failures.
#   - MAT-9 refines provider HTTP status/family extraction from ffprobe stderr.
#   - MAT-10 exposes a short redacted ffprobe stderr snippet for unparsed probe failures.
#   - ProbeOnly mode can test ffprobe availability and optionally probe one manually supplied URL.
#   - Does not mutate database tables.
#   - Heavy resolver/probe/support-preview helpers are imported from tools/common helper modules.
#   - Does not write generated artwork yet.
#
# Frame capture philosophy:
#   series_port_900_image_repair is not always solvable by TMDb. If provider media is playable,
#   generated artwork can be captured from the actual media. If provider media is not playable,
#   the row should eventually be classified as unplayable/manual rather than requeued forever.
#
# Signals:
#   - materialization_series_frame_capture_status
#   - materialization_series_frame_capture_candidate_count
#   - materialization_series_frame_capture_probe_success_count
#   - materialization_series_frame_capture_probe_failed_count
#   - materialization_series_frame_capture_generated_count
#   - materialization_series_frame_capture_unplayable_count
#   - materialization_series_frame_capture_manual_needed_count
#   - materialization_series_frame_capture_last_diagnostic
#   - worker_heartbeat_status
#
# Kill switch:
#   - ENABLE_FRAME_CAPTURE_ARTWORK
#
# Required for DbQuery mode:
#   $env:DOG_OPEN_PROC_ENDPOINT = "https://miratv.club/_workers/api/series/dog_open_proc.php"
#   $env:DOG_OPEN_PROC_TOKEN = "<token>"
#
# Usage:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/capture_series_frame_artwork.ps1" -Environment "dev"
#
# DbQuery candidate discovery:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/capture_series_frame_artwork.ps1" -Environment "dev" -Mode "DbQuery" -Limit 3
#
# DbQuery episode resolver preview; does not probe, capture, write artwork, or mutate queue rows:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/capture_series_frame_artwork.ps1" -Environment "dev" -Mode "DbQuery" -Limit 3 -ResolveEpisodePreview
#
# DbQuery resolved episode probe preview; probes resolved URLs but does not capture, write artwork, write support cases, or mutate queue rows:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/capture_series_frame_artwork.ps1" -Environment "dev" -Mode "DbQuery" -Limit 3 -ResolveEpisodePreview -ProbeResolvedEpisodePreview
#
# ProbeOnly manual URL test; do not log full URL:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File "tools/workers/capture_series_frame_artwork.ps1" -Environment "dev" -Mode "ProbeOnly" -PlaybackUrl "<provider_url>"

[CmdletBinding()]
param(
    [string]$WorkerName = "series_frame_capture_artwork_worker",
    [string]$Component = "materialization_queue_worker",
    [string]$Environment = "prod",
    [string]$KillSwitchName = "ENABLE_FRAME_CAPTURE_ARTWORK",

    [ValidateSet("DryRun", "SnapshotInput", "DbQuery", "ProbeOnly")]
    [string]$Mode = "DryRun",

    [string]$InputJsonPath = "",
    [string]$DatabaseKey = "ip",
    [string]$DbQueryEndpoint = "",
    [string]$DbQueryToken = "",
    [int]$QueryTimeoutSec = 30,

    [int]$Limit = 3,
    [string]$PlaybackUrl = "",
    [int]$ProbeTimeoutSec = 20,
    [switch]$ResolveEpisodePreview,
    [string]$ProviderApiBaseUrl = $env:XTREAM_PROVIDER_API_BASE_URL,
    [string]$ProviderUsername = $env:XTREAM_PROVIDER_USERNAME,
    [string]$ProviderPassword = $env:XTREAM_PROVIDER_PASSWORD,
    [int]$ResolverTimeoutSec = 20,
    [switch]$ProbeResolvedEpisodePreview,
    [int]$EpisodeProbeTimeoutSec = 20,
    [int]$HeartbeatIntervalSeconds = 1800,
    [int]$StaleAfterSeconds = 7200,
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

































function Read-FrameCaptureSnapshot {
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

function Get-SeriesPort900CandidateSql {
    [CmdletBinding()]
    param(
        [int]$Limit = 3
    )

    $safeLimit = [math]::Max(1, [math]::Min($Limit, 50))

    return @"
SELECT
    id AS queue_id,
    content_id AS local_series_id,
    provider,
    provider_content_id AS provider_series_id,
    mac_user_id,
    missing_fields,
    trigger_reason,
    status,
    priority,
    attempt_count,
    max_attempts,
    created_at,
    updated_at,
    last_error
FROM content_materialization_queue
WHERE content_type = 'series'
  AND materialization_kind = 'metadata'
  AND trigger_reason = 'series_port_900_image_repair'
  AND status IN ('queued', 'needs_manual_match')
ORDER BY
    CASE WHEN status = 'queued' THEN 0 ELSE 1 END,
    attempt_count ASC,
    priority ASC,
    created_at ASC,
    id ASC
LIMIT $safeLimit
"@
}

function Get-SeriesFrameCaptureCandidatesDb {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [string]$DatabaseKey = "ip",

        [string]$Endpoint = "",

        [string]$Token = "",

        [int]$TimeoutSec = 30,

        [int]$Limit = 3
    )

    $dbQueryModule = Join-Path $RepoRoot "tools\common\DbQuery.psm1"

    if (-not (Test-Path -LiteralPath $dbQueryModule)) {
        throw "DbQuery module not found at: $dbQueryModule"
    }

    Import-Module $dbQueryModule -Force

    $queryResult = Invoke-ReadOnlyDbQuery `
        -DatabaseKey $DatabaseKey `
        -Sql (Get-SeriesPort900CandidateSql -Limit $Limit) `
        -Endpoint $Endpoint `
        -Token $Token `
        -TimeoutSec $TimeoutSec

    if ($null -eq $queryResult) {
        throw "DbQuery returned null result."
    }

    if (-not ($queryResult.PSObject.Properties.Name -contains "rows")) {
        throw "DbQuery result did not include rows."
    }

    return Convert-ToArraySafe -Value $queryResult.rows
}

function Get-CandidateRowsFromSnapshot {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Snapshot
    )

    if ($null -eq $Snapshot) {
        return @()
    }

    foreach ($propertyName in @("rows", "candidates", "items", "result", "queue")) {
        if ($Snapshot.PSObject.Properties.Name -contains $propertyName) {
            return Convert-ToArraySafe -Value $Snapshot.$propertyName
        }
    }

    return @( $Snapshot )
}



function Get-FrameCaptureLocalMetrics {
    [CmdletBinding()]
    param(
        [object[]]$Candidates,
        [string]$Mode,
        [object]$Tooling,
        [string]$SourceName
    )

    $ProbeResult = $script:FrameCaptureProbeResultForMetrics

    $candidateCount = @($Candidates).Count
    $probeSuccessCount = 0
    $probeFailedCount = 0
    $generatedCount = 0
    $unplayableCount = 0
    $manualNeededCount = 0
    $status = "pass"
    $captureStatus = "candidate_discovery_only"
    $diagnostic = "candidate discovery completed; no DB mutation performed"

    if ($Mode -eq "DryRun") {
        $captureStatus = "dry_run"
        $diagnostic = "dry run completed; no DB query or capture performed"
    }
    elseif ($Mode -eq "SnapshotInput" -or $Mode -eq "DbQuery") {
        if ($candidateCount -gt 0) {
            $captureStatus = "candidates_found"
            $status = "warning"
            $diagnostic = "series_port_900_image_repair candidates found; frame capture not executed in this mode"
        }
        else {
            $captureStatus = "no_candidates"
            $diagnostic = "no series_port_900_image_repair candidates found"
        }
    }
    elseif ($Mode -eq "ProbeOnly") {
        if ($null -eq $ProbeResult) {
            $captureStatus = "probe_not_run"
            $status = "warning"
            $diagnostic = "ProbeOnly mode did not receive PlaybackUrl; URL resolution worker is still pending"
        }
        elseif ($ProbeResult.ok) {
            $captureStatus = "probe_playable"
            $probeSuccessCount = 1
            $diagnostic = "ffprobe classified supplied media URL as playable; full URL redacted"
        }
        else {
            $captureStatus = [string]$ProbeResult.status
            $probeFailedCount = 1
            $unplayableCount = 1
            $status = "warning"
            $diagnostic = "ffprobe did not classify supplied media URL as playable; full URL redacted"
        }
    }

    return [pscustomobject]@{
        status = $status
        materialization_series_frame_capture_status = $captureStatus
        materialization_series_frame_capture_candidate_count = $candidateCount
        materialization_series_frame_capture_probe_success_count = $probeSuccessCount
        materialization_series_frame_capture_probe_failed_count = $probeFailedCount
        materialization_series_frame_capture_generated_count = $generatedCount
        materialization_series_frame_capture_unplayable_count = $unplayableCount
        materialization_series_frame_capture_manual_needed_count = $manualNeededCount
        materialization_series_frame_capture_last_diagnostic = $diagnostic
        ffprobe_available = $Tooling.ffprobe_available
        ffmpeg_available = $Tooling.ffmpeg_available
        source_name = $SourceName
        mode = $Mode
    }
}

function Get-CandidateSummaryRows {
    [CmdletBinding()]
    param(
        [object[]]$Candidates
    )

    $summary = @()

    foreach ($row in @($Candidates)) {
        $queueId = Convert-ToIntSafe -Value (Get-PropertyValue -Object $row -Names @("queue_id", "id"))
        $localSeriesId = Convert-ToIntSafe -Value (Get-PropertyValue -Object $row -Names @("local_series_id", "content_id"))
        $providerSeriesId = [string](Get-PropertyValue -Object $row -Names @("provider_series_id", "provider_content_id"))
        $status = [string](Get-PropertyValue -Object $row -Names @("status"))
        $attemptCount = Convert-ToIntSafe -Value (Get-PropertyValue -Object $row -Names @("attempt_count", "attempts"))
        $missingFields = [string](Get-PropertyValue -Object $row -Names @("missing_fields"))
        $lastError = [string](Get-PropertyValue -Object $row -Names @("last_error"))

        $summary += [pscustomobject]@{
            queue_id = $queueId
            local_series_id = $localSeriesId
            provider_series_id = $providerSeriesId
            status = $status
            attempt_count = $attemptCount
            missing_fields = $missingFields
            last_error_present = -not [string]::IsNullOrWhiteSpace($lastError)
        }
    }

    return $summary
}

$repoRoot = Get-ScriptRepoRoot
$loggingModule = Join-Path $repoRoot "tools\common\Logging.psm1"

if (-not (Test-Path -LiteralPath $loggingModule)) {
    throw "Logging module not found at: $loggingModule"
}

Import-Module $loggingModule -Force
$frameCaptureHelperModules = @(
    "tools\common\FrameCapturePreviewCommon.psm1",
    "tools\common\SeriesEpisodeResolver.psm1",
    "tools\common\MediaProbePreview.psm1",
    "tools\common\SupportCasePreview.psm1"
)

foreach ($helperModule in $frameCaptureHelperModules) {
    $helperModulePath = Join-Path $repoRoot $helperModule
    if (-not (Test-Path -LiteralPath $helperModulePath)) {
        throw "Frame capture helper module not found at: $helperModulePath"
    }
    Import-Module $helperModulePath -Force -Global
}


$script:RunId = New-RunId -Prefix "series-frame-capture"
$script:FrameCaptureProbeResultForMetrics = $null

$moduleLogContext = @{
    job_name = "capture_series_frame_artwork"
    run_id = $script:RunId
    worker_name = $WorkerName
    component = $Component
    environment = $Environment
    mode = $Mode
}

try {
    $enabled = Test-KillSwitch -Name $KillSwitchName -DefaultEnabled $true

    if (-not $enabled) {
        Write-JobLog `
            -RunId $script:RunId `
            -JobName "capture_series_frame_artwork" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -Status "job_skipped" `
            -EventType "job_skipped" `
            -SourceName "series_frame_capture_artwork" `
            -DurationMs (Get-DurationMs -Start $script:StartedAt) `
            -Data @{
                kill_switch_name = $KillSwitchName
                kill_switch_enabled = $false
                reason = "frame capture artwork disabled by kill switch"
                mode = $Mode
            } `
            -LogRoot $LogRoot | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName "capture_series_frame_artwork" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName "materialization_series_frame_capture_status" `
            -P0Item "P0.6" `
            -SignalValue "disabled" `
            -Status "disabled" `
            -AllowedValues "dry_run|candidates_found|no_candidates|probe_playable|probe_failed|probe_timeout|ffprobe_missing|disabled|failed" `
            -SourceTableOrEndpoint "tools/workers/capture_series_frame_artwork.ps1" `
            -Data @{
                dashboard_panel = "Materialization"
                widget_key = "materialization.series_frame_capture.status"
                owner = "Content Ops"
                kill_switch_name = $KillSwitchName
            } `
            -LogRoot $LogRoot | Out-Null

        Write-Output "SKIPPED: $KillSwitchName is disabled. run_id=$script:RunId"
        exit 0
    }

    Write-JobLog `
        -RunId $script:RunId `
        -JobName "capture_series_frame_artwork" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -Status "job_started" `
        -EventType "job_started" `
        -SourceName "series_frame_capture_artwork" `
        -Data @{
            kill_switch_name = $KillSwitchName
            mode = $Mode
            database_key = $DatabaseKey
            limit = $Limit
            probe_url_supplied = -not [string]::IsNullOrWhiteSpace($PlaybackUrl)
            resolve_episode_preview = [bool]$ResolveEpisodePreview
            probe_resolved_episode_preview = [bool]$ProbeResolvedEpisodePreview
            resolver_timeout_sec = $ResolverTimeoutSec
            episode_probe_timeout_sec = $EpisodeProbeTimeoutSec
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Heartbeat `
        -RunId $script:RunId `
        -JobName "capture_series_frame_artwork" `
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
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "capture_series_frame_artwork" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "worker_heartbeat_status" `
        -P0Item "P0.2" `
        -SignalValue "ok" `
        -Status "ok" `
        -AllowedValues "ok|missed|failed|disabled" `
        -SourceTableOrEndpoint "tools/workers/capture_series_frame_artwork.ps1" `
        -Data @{
            dashboard_panel = "Worker Health"
            widget_key = "worker.heartbeat.status"
            owner = "SRE"
            kill_switch_name = $KillSwitchName
        } `
        -LogRoot $LogRoot | Out-Null

    $tooling = Test-FfmpegTooling
    $candidates = @()
    $probeResult = $null
    $resolverPreviewRows = @()
    $resolverPreviewSummary = Get-EpisodeResolverPreviewSummary -ResolverPreviewRows $resolverPreviewRows
    $episodeProbePreviewRows = @()
    $episodeProbePreviewSummary = Get-EpisodeProbePreviewSummary -EpisodeProbePreviewRows $episodeProbePreviewRows
    $supportCasePreviewRows = @()
    $supportCasePreviewSummary = Get-SupportCasePreviewSummary -SupportCasePreviewRows $supportCasePreviewRows
    $sourceName = "dry_run_no_db_query"

    if ($Mode -eq "SnapshotInput") {
        if ([string]::IsNullOrWhiteSpace($InputJsonPath)) {
            throw "InputJsonPath is required when Mode=SnapshotInput."
        }

        $resolvedInput = Resolve-RepoRelativePath -RepoRoot $repoRoot -Path $InputJsonPath
        $snapshot = Read-FrameCaptureSnapshot -Path $resolvedInput
        $candidates = Get-CandidateRowsFromSnapshot -Snapshot $snapshot
        $sourceName = "snapshot_input"
    }
    elseif ($Mode -eq "DbQuery") {
        $candidates = Get-SeriesFrameCaptureCandidatesDb `
            -RepoRoot $repoRoot `
            -DatabaseKey $DatabaseKey `
            -Endpoint $DbQueryEndpoint `
            -Token $DbQueryToken `
            -TimeoutSec $QueryTimeoutSec `
            -Limit $Limit

        $sourceName = "dog_open_proc:ip.content_materialization_queue"
    }
    elseif ($Mode -eq "ProbeOnly") {
        $sourceName = "manual_probe_only"
        if (-not [string]::IsNullOrWhiteSpace($PlaybackUrl)) {
            $probeResult = Invoke-FfprobeUrl -Url $PlaybackUrl -TimeoutSec $ProbeTimeoutSec
        }
    }

    if (($ResolveEpisodePreview -or $ProbeResolvedEpisodePreview) -and ($Mode -eq "DbQuery" -or $Mode -eq "SnapshotInput") -and @($candidates).Count -gt 0) {
        $resolverPreviewRows = Get-EpisodeResolverPreviewRows `
            -Candidates $candidates `
            -ProviderApiBaseUrl $ProviderApiBaseUrl `
            -ProviderUsername $ProviderUsername `
            -ProviderPassword $ProviderPassword `
            -TimeoutSec $ResolverTimeoutSec `
            -LogContext $moduleLogContext `
            -LogRoot $LogRoot

        $resolverPreviewSummary = Get-EpisodeResolverPreviewSummary -ResolverPreviewRows $resolverPreviewRows
    }

    if ($ProbeResolvedEpisodePreview -and @($resolverPreviewRows).Count -gt 0) {
        $episodeProbePreviewRows = Get-EpisodeProbePreviewRows `
            -ResolverPreviewRows $resolverPreviewRows `
            -ProviderApiBaseUrl $ProviderApiBaseUrl `
            -ProviderUsername $ProviderUsername `
            -ProviderPassword $ProviderPassword `
            -TimeoutSec $EpisodeProbeTimeoutSec `
            -LogContext $moduleLogContext `
            -LogRoot $LogRoot

        $episodeProbePreviewSummary = Get-EpisodeProbePreviewSummary -EpisodeProbePreviewRows $episodeProbePreviewRows
    }

    if (@($resolverPreviewRows).Count -gt 0) {
        $supportCasePreviewRows = Get-SupportCasePreviewRows `
            -ResolverPreviewRows $resolverPreviewRows `
            -EpisodeProbePreviewRows $episodeProbePreviewRows `
            -LogContext $moduleLogContext `
            -LogRoot $LogRoot

        $supportCasePreviewSummary = Get-SupportCasePreviewSummary -SupportCasePreviewRows $supportCasePreviewRows
    }

    $script:FrameCaptureProbeResultForMetrics = $probeResult

    $metrics = Get-FrameCaptureLocalMetrics `
        -Candidates $candidates `
        -Mode $Mode `
        -Tooling $tooling `
        -SourceName $sourceName

    $candidateSummary = Get-CandidateSummaryRows -Candidates $candidates

    $statusSignal = [string]$metrics.materialization_series_frame_capture_status
    $workerStatus = [string]$metrics.status

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "capture_series_frame_artwork" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "materialization_series_frame_capture_status" `
        -P0Item "P0.6" `
        -SignalValue $statusSignal `
        -Status $workerStatus `
        -AllowedValues "dry_run|candidates_found|no_candidates|probe_playable|probe_failed|probe_timeout|ffprobe_missing|disabled|failed" `
        -SourceTableOrEndpoint "tools/workers/capture_series_frame_artwork.ps1" `
        -Data @{
            dashboard_panel = "Materialization"
            widget_key = "materialization.series_frame_capture.status"
            owner = "Content Ops"
            kill_switch_name = $KillSwitchName
            mode = $Mode
            source_name = $metrics.source_name
            diagnostic = $metrics.materialization_series_frame_capture_last_diagnostic
            ffprobe_available = $metrics.ffprobe_available
            ffmpeg_available = $metrics.ffmpeg_available
            candidate_count = $metrics.materialization_series_frame_capture_candidate_count
            probe_url_summary = if ($null -ne $probeResult) { $probeResult.url_summary } else { $null }
            resolve_episode_preview = [bool]$ResolveEpisodePreview
            probe_resolved_episode_preview = [bool]$ProbeResolvedEpisodePreview
            episode_resolver_preview = $resolverPreviewSummary
            episode_probe_preview = $episodeProbePreviewSummary
            support_case_preview = $supportCasePreviewSummary
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "capture_series_frame_artwork" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "materialization_series_frame_capture_candidate_count" `
        -P0Item "P0.6" `
        -SignalValue ([string]$metrics.materialization_series_frame_capture_candidate_count) `
        -ValueNum ([decimal]$metrics.materialization_series_frame_capture_candidate_count) `
        -Status $workerStatus `
        -AllowedValues "0+" `
        -SourceTableOrEndpoint "tools/workers/capture_series_frame_artwork.ps1" `
        -Data @{
            dashboard_panel = "Materialization"
            widget_key = "materialization.series_frame_capture.candidate_count"
            owner = "Content Ops"
            kill_switch_name = $KillSwitchName
            mode = $Mode
            source_name = $metrics.source_name
            candidates = $candidateSummary
            episode_resolver_preview_rows = $resolverPreviewRows
            episode_resolver_preview_summary = $resolverPreviewSummary
            episode_probe_preview_rows = $episodeProbePreviewRows
            episode_probe_preview_summary = $episodeProbePreviewSummary
            support_case_preview_rows = $supportCasePreviewRows
            support_case_preview_summary = $supportCasePreviewSummary
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "capture_series_frame_artwork" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "materialization_series_frame_capture_probe_success_count" `
        -P0Item "P0.6" `
        -SignalValue ([string]$metrics.materialization_series_frame_capture_probe_success_count) `
        -ValueNum ([decimal]$metrics.materialization_series_frame_capture_probe_success_count) `
        -Status $workerStatus `
        -AllowedValues "0+" `
        -SourceTableOrEndpoint "tools/workers/capture_series_frame_artwork.ps1" `
        -Data @{
            dashboard_panel = "Materialization"
            widget_key = "materialization.series_frame_capture.probe_success_count"
            owner = "Content Ops"
            kill_switch_name = $KillSwitchName
            mode = $Mode
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "capture_series_frame_artwork" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "materialization_series_frame_capture_probe_failed_count" `
        -P0Item "P0.6" `
        -SignalValue ([string]$metrics.materialization_series_frame_capture_probe_failed_count) `
        -ValueNum ([decimal]$metrics.materialization_series_frame_capture_probe_failed_count) `
        -Status $workerStatus `
        -AllowedValues "0+" `
        -SourceTableOrEndpoint "tools/workers/capture_series_frame_artwork.ps1" `
        -Data @{
            dashboard_panel = "Materialization"
            widget_key = "materialization.series_frame_capture.probe_failed_count"
            owner = "Content Ops"
            kill_switch_name = $KillSwitchName
            mode = $Mode
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "capture_series_frame_artwork" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "materialization_series_frame_capture_generated_count" `
        -P0Item "P0.6" `
        -SignalValue ([string]$metrics.materialization_series_frame_capture_generated_count) `
        -ValueNum ([decimal]$metrics.materialization_series_frame_capture_generated_count) `
        -Status $workerStatus `
        -AllowedValues "0+" `
        -SourceTableOrEndpoint "tools/workers/capture_series_frame_artwork.ps1" `
        -Data @{
            dashboard_panel = "Materialization"
            widget_key = "materialization.series_frame_capture.generated_count"
            owner = "Content Ops"
            kill_switch_name = $KillSwitchName
            mode = $Mode
            note = "generated_count remains 0 until Capture mode is implemented"
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "capture_series_frame_artwork" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "materialization_series_frame_capture_unplayable_count" `
        -P0Item "P0.6" `
        -SignalValue ([string]$metrics.materialization_series_frame_capture_unplayable_count) `
        -ValueNum ([decimal]$metrics.materialization_series_frame_capture_unplayable_count) `
        -Status $workerStatus `
        -AllowedValues "0+" `
        -SourceTableOrEndpoint "tools/workers/capture_series_frame_artwork.ps1" `
        -Data @{
            dashboard_panel = "Materialization"
            widget_key = "materialization.series_frame_capture.unplayable_count"
            owner = "Content Ops"
            kill_switch_name = $KillSwitchName
            mode = $Mode
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "capture_series_frame_artwork" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "materialization_series_frame_capture_manual_needed_count" `
        -P0Item "P0.6" `
        -SignalValue ([string]$metrics.materialization_series_frame_capture_manual_needed_count) `
        -ValueNum ([decimal]$metrics.materialization_series_frame_capture_manual_needed_count) `
        -Status $workerStatus `
        -AllowedValues "0+" `
        -SourceTableOrEndpoint "tools/workers/capture_series_frame_artwork.ps1" `
        -Data @{
            dashboard_panel = "Materialization"
            widget_key = "materialization.series_frame_capture.manual_needed_count"
            owner = "Content Ops"
            kill_switch_name = $KillSwitchName
            mode = $Mode
        } `
        -LogRoot $LogRoot | Out-Null

    Emit-Signal `
        -RunId $script:RunId `
        -JobName "capture_series_frame_artwork" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -SignalName "materialization_series_frame_capture_last_diagnostic" `
        -P0Item "P0.6" `
        -SignalValue ([string]$metrics.materialization_series_frame_capture_last_diagnostic) `
        -Status $workerStatus `
        -AllowedValues "text" `
        -SourceTableOrEndpoint "tools/workers/capture_series_frame_artwork.ps1" `
        -Data @{
            dashboard_panel = "Materialization"
            widget_key = "materialization.series_frame_capture.last_diagnostic"
            owner = "Content Ops"
            kill_switch_name = $KillSwitchName
            mode = $Mode
            source_name = $metrics.source_name
        } `
        -LogRoot $LogRoot | Out-Null

    Write-JobLog `
        -RunId $script:RunId `
        -JobName "capture_series_frame_artwork" `
        -WorkerName $WorkerName `
        -Component $Component `
        -Environment $Environment `
        -Status "job_completed" `
        -EventType "job_completed" `
        -SourceName ([string]$metrics.source_name) `
        -SourceRowCount ([int]$metrics.materialization_series_frame_capture_candidate_count) `
        -RowsInserted 0 `
        -RowsUpdated 0 `
        -RowsSkipped ([int]$metrics.materialization_series_frame_capture_candidate_count) `
        -RowsFailed ([int]$metrics.materialization_series_frame_capture_probe_failed_count) `
        -DurationMs (Get-DurationMs -Start $script:StartedAt) `
        -Data @{
            mode = $Mode
            materialization_series_frame_capture_status = $metrics.materialization_series_frame_capture_status
            candidate_count = $metrics.materialization_series_frame_capture_candidate_count
            probe_success_count = $metrics.materialization_series_frame_capture_probe_success_count
            probe_failed_count = $metrics.materialization_series_frame_capture_probe_failed_count
            generated_count = $metrics.materialization_series_frame_capture_generated_count
            unplayable_count = $metrics.materialization_series_frame_capture_unplayable_count
            manual_needed_count = $metrics.materialization_series_frame_capture_manual_needed_count
            diagnostic = $metrics.materialization_series_frame_capture_last_diagnostic
            ffprobe_available = $metrics.ffprobe_available
            ffmpeg_available = $metrics.ffmpeg_available
            candidate_summary = $candidateSummary
            resolve_episode_preview = [bool]$ResolveEpisodePreview
            probe_resolved_episode_preview = [bool]$ProbeResolvedEpisodePreview
            episode_resolver_preview_summary = $resolverPreviewSummary
            episode_resolver_preview_rows = $resolverPreviewRows
            episode_probe_preview_summary = $episodeProbePreviewSummary
            episode_probe_preview_rows = $episodeProbePreviewRows
            support_case_preview_summary = $supportCasePreviewSummary
            support_case_preview_rows = $supportCasePreviewRows
            note = "read-only frame capture artwork scaffold; support-case payloads are preview-only; no DB writes, no queue mutation, no support-case writes, and no artwork writes performed"
        } `
        -LogRoot $LogRoot | Out-Null

    if ($ProbeResolvedEpisodePreview) {
        Write-Output "OK: series frame capture artwork worker completed. status=$($metrics.materialization_series_frame_capture_status) candidate_count=$($metrics.materialization_series_frame_capture_candidate_count) probe_success=$($metrics.materialization_series_frame_capture_probe_success_count) probe_failed=$($metrics.materialization_series_frame_capture_probe_failed_count) generated_count=$($metrics.materialization_series_frame_capture_generated_count) unplayable_count=$($metrics.materialization_series_frame_capture_unplayable_count) mode=$Mode episode_resolver_attempted=$($resolverPreviewSummary.attempted_count) episode_resolver_ready=$($resolverPreviewSummary.ready_count) episode_resolver_pending=$($resolverPreviewSummary.pending_count) episode_resolver_failed=$($resolverPreviewSummary.failed_count) episode_probe_attempted=$($episodeProbePreviewSummary.attempted_count) episode_probe_ready=$($episodeProbePreviewSummary.ready_count) episode_probe_failed=$($episodeProbePreviewSummary.failed_count) episode_probe_timeout=$($episodeProbePreviewSummary.timeout_count) episode_probe_provider_406=$($episodeProbePreviewSummary.provider_unavailable_or_406_count) episode_probe_provider_http_error=$($episodeProbePreviewSummary.provider_http_error_count) episode_probe_http_401=$($episodeProbePreviewSummary.http_401_count) episode_probe_http_403=$($episodeProbePreviewSummary.http_403_count) episode_probe_http_404=$($episodeProbePreviewSummary.http_404_count) episode_probe_http_406=$($episodeProbePreviewSummary.http_406_count) episode_probe_http_429=$($episodeProbePreviewSummary.http_429_count) episode_probe_http_5xx=$($episodeProbePreviewSummary.http_5xx_count) episode_probe_http_4xx_unparsed=$($episodeProbePreviewSummary.http_4xx_unparsed_count) episode_probe_http_5xx_unparsed=$($episodeProbePreviewSummary.http_5xx_unparsed_count) episode_probe_http_unparsed=$($episodeProbePreviewSummary.http_unparsed_count) episode_probe_network_error=$($episodeProbePreviewSummary.network_error_count) episode_probe_container_failed=$($episodeProbePreviewSummary.container_probe_failed_count) episode_probe_unknown_failed=$($episodeProbePreviewSummary.unknown_probe_failure_count) episode_probe_nonzero_no_stderr=$($episodeProbePreviewSummary.ffprobe_exit_nonzero_no_stderr_count) episode_probe_eof=$($episodeProbePreviewSummary.stream_empty_or_eof_count) episode_probe_invalid_data=$($episodeProbePreviewSummary.invalid_media_data_count) episode_probe_error_hints=$($episodeProbePreviewSummary.error_hints) episode_probe_stderr_snippets=$($episodeProbePreviewSummary.stderr_snippet_count) support_case_preview_rows=$($supportCasePreviewSummary.preview_row_count) support_case_preview_needs_review=$($supportCasePreviewSummary.needs_review_count) support_case_preview_probe_ready=$($supportCasePreviewSummary.probe_ready_count) support_case_preview_no_write=$($supportCasePreviewSummary.no_write_count) run_id=$script:RunId"
    }
    elseif ($ResolveEpisodePreview) {
        Write-Output "OK: series frame capture artwork worker completed. status=$($metrics.materialization_series_frame_capture_status) candidate_count=$($metrics.materialization_series_frame_capture_candidate_count) probe_success=$($metrics.materialization_series_frame_capture_probe_success_count) probe_failed=$($metrics.materialization_series_frame_capture_probe_failed_count) generated_count=$($metrics.materialization_series_frame_capture_generated_count) unplayable_count=$($metrics.materialization_series_frame_capture_unplayable_count) mode=$Mode episode_resolver_attempted=$($resolverPreviewSummary.attempted_count) episode_resolver_ready=$($resolverPreviewSummary.ready_count) episode_resolver_pending=$($resolverPreviewSummary.pending_count) episode_resolver_failed=$($resolverPreviewSummary.failed_count) run_id=$script:RunId"
    }
    else {
        Write-Output "OK: series frame capture artwork worker completed. status=$($metrics.materialization_series_frame_capture_status) candidate_count=$($metrics.materialization_series_frame_capture_candidate_count) probe_success=$($metrics.materialization_series_frame_capture_probe_success_count) probe_failed=$($metrics.materialization_series_frame_capture_probe_failed_count) generated_count=$($metrics.materialization_series_frame_capture_generated_count) unplayable_count=$($metrics.materialization_series_frame_capture_unplayable_count) mode=$Mode run_id=$script:RunId"
    }
    exit 0
}
catch {
    $message = $_.Exception.Message
    $duration = Get-DurationMs -Start $script:StartedAt

    if ([string]::IsNullOrWhiteSpace($script:RunId)) {
        $script:RunId = "series-frame-capture-failed-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
    }

    try {
        Write-JobLog `
            -RunId $script:RunId `
            -JobName "capture_series_frame_artwork" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -Status "job_failed" `
            -EventType "job_failed" `
            -SourceName "series_frame_capture_artwork" `
            -DurationMs $duration `
            -ErrorCode "SERIES_FRAME_CAPTURE_FAILED" `
            -ErrorMessage $message `
            -Data @{
                kill_switch_name = $KillSwitchName
                mode = $Mode
                database_key = $DatabaseKey
                resolve_episode_preview = [bool]$ResolveEpisodePreview
                probe_resolved_episode_preview = [bool]$ProbeResolvedEpisodePreview
            } `
            -LogRoot $LogRoot | Out-Null

        Emit-Signal `
            -RunId $script:RunId `
            -JobName "capture_series_frame_artwork" `
            -WorkerName $WorkerName `
            -Component $Component `
            -Environment $Environment `
            -SignalName "materialization_series_frame_capture_status" `
            -P0Item "P0.6" `
            -SignalValue "failed" `
            -Status "failed" `
            -AllowedValues "dry_run|candidates_found|no_candidates|probe_playable|probe_failed|probe_timeout|ffprobe_missing|disabled|failed" `
            -SourceTableOrEndpoint "tools/workers/capture_series_frame_artwork.ps1" `
            -ErrorCode "SERIES_FRAME_CAPTURE_FAILED" `
            -ErrorMessage $message `
            -Data @{
                dashboard_panel = "Materialization"
                widget_key = "materialization.series_frame_capture.status"
                owner = "Content Ops"
                kill_switch_name = $KillSwitchName
                mode = $Mode
            } `
            -LogRoot $LogRoot | Out-Null
    }
    catch {
        # Avoid masking original failure.
    }

    Write-Error "FAILED: series frame capture artwork worker failed. run_id=$script:RunId error=$message"
    exit 1
}
