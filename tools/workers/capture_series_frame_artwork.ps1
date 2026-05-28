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
#   - ProbeOnly mode can test ffprobe availability and optionally probe one manually supplied URL.
#   - Does not mutate database tables.
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

function Convert-ToArraySafe {
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

function Convert-ToIntSafe {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value,

        [int]$DefaultValue = 0
    )

    if ($null -eq $Value) {
        return $DefaultValue
    }

    $parsed = 0

    if ([int]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed
    }

    return $DefaultValue
}

function Convert-ToJsonSafe {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value,

        [int]$Depth = 8
    )

    if ($null -eq $Value) {
        return "null"
    }

    try {
        return ($Value | ConvertTo-Json -Depth $Depth -Compress -ErrorAction Stop)
    }
    catch {
        return "{`"json_error`":`"$($_.Exception.Message)`"}"
    }
}

function Get-StringSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-RedactedUrlSummary {
    [CmdletBinding()]
    param(
        [string]$Url
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return [pscustomobject]@{
            url_present = $false
            host = ""
            scheme = ""
            path_hint = ""
            url_sha256 = ""
        }
    }

    try {
        $uri = [System.Uri]$Url
        $segments = @($uri.Segments | ForEach-Object { $_.Trim('/') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $tail = @($segments | Select-Object -Last 2) -join "/"

        return [pscustomobject]@{
            url_present = $true
            host = $uri.Host
            scheme = $uri.Scheme
            path_hint = $tail
            url_sha256 = Get-StringSha256 -Text $Url
        }
    }
    catch {
        return [pscustomobject]@{
            url_present = $true
            host = "parse_failed"
            scheme = "parse_failed"
            path_hint = "parse_failed"
            url_sha256 = Get-StringSha256 -Text $Url
        }
    }
}


function Get-SecretRedactedText {
    [CmdletBinding()]
    param(
        [string]$Text,
        [string[]]$Secrets
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $redacted = $Text

    foreach ($secret in @($Secrets)) {
        if (-not [string]::IsNullOrWhiteSpace($secret)) {
            $redacted = $redacted.Replace($secret, "REDACTED")
        }
    }

    return $redacted
}

function Get-ProviderApiUrl {
    [CmdletBinding()]
    param(
        [string]$ProviderApiBaseUrl
    )

    if ([string]::IsNullOrWhiteSpace($ProviderApiBaseUrl)) {
        return ""
    }

    $value = $ProviderApiBaseUrl.Trim()

    if ($value.EndsWith("/player_api.php", [System.StringComparison]::OrdinalIgnoreCase)) {
        return $value
    }

    return ($value.TrimEnd("/") + "/player_api.php")
}

function Get-ProviderStreamingBaseUrl {
    [CmdletBinding()]
    param(
        [string]$ProviderApiBaseUrl
    )

    if ([string]::IsNullOrWhiteSpace($ProviderApiBaseUrl)) {
        return ""
    }

    $value = $ProviderApiBaseUrl.Trim().TrimEnd("/")

    if ($value.EndsWith("/player_api.php", [System.StringComparison]::OrdinalIgnoreCase)) {
        return $value.Substring(0, $value.Length - "/player_api.php".Length).TrimEnd("/")
    }

    return $value
}

function Get-SeriesInfoUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProviderApiBaseUrl,

        [Parameter(Mandatory = $true)]
        [string]$ProviderUsername,

        [Parameter(Mandatory = $true)]
        [string]$ProviderPassword,

        [Parameter(Mandatory = $true)]
        [string]$ProviderSeriesId
    )

    $apiUrl = Get-ProviderApiUrl -ProviderApiBaseUrl $ProviderApiBaseUrl

    if ([string]::IsNullOrWhiteSpace($apiUrl)) {
        throw "Provider API base URL is required for get_series_info preview."
    }

    $queryParts = @(
        "username=$([System.Uri]::EscapeDataString($ProviderUsername))",
        "password=$([System.Uri]::EscapeDataString($ProviderPassword))",
        "action=get_series_info",
        "series_id=$([System.Uri]::EscapeDataString($ProviderSeriesId))"
    )

    return ($apiUrl + "?" + ($queryParts -join "&"))
}

function Get-FirstEpisodeCandidateFromSeriesInfo {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$SeriesInfo
    )

    if ($null -eq $SeriesInfo) {
        return $null
    }

    $episodeContainer = Get-PropertyValue -Object $SeriesInfo -Names @("episodes", "episode", "items")

    if ($null -eq $episodeContainer) {
        return $null
    }

    $buckets = @()

    if ($episodeContainer -is [System.Collections.IDictionary]) {
        foreach ($key in $episodeContainer.Keys) {
            $buckets += Convert-ToArraySafe -Value $episodeContainer[$key]
        }
    }
    elseif (-not ($episodeContainer -is [System.Array]) -and @($episodeContainer.PSObject.Properties).Count -gt 0) {
        foreach ($property in @($episodeContainer.PSObject.Properties)) {
            $buckets += Convert-ToArraySafe -Value $property.Value
        }
    }
    else {
        $buckets += Convert-ToArraySafe -Value $episodeContainer
    }

    foreach ($episode in @($buckets)) {
        if ($null -eq $episode) {
            continue
        }

        $episodeId = [string](Get-PropertyValue -Object $episode -Names @("id", "episode_id", "stream_id", "provider_episode_id"))

        if ([string]::IsNullOrWhiteSpace($episodeId)) {
            continue
        }

        $containerExtension = [string](Get-PropertyValue -Object $episode -Names @("container_extension", "container", "extension", "ext"))
        if ([string]::IsNullOrWhiteSpace($containerExtension)) {
            $containerExtension = "mp4"
        }
        $containerExtension = $containerExtension.Trim().TrimStart(".")

        $seasonNumber = [string](Get-PropertyValue -Object $episode -Names @("season", "season_number", "season_num"))
        $episodeNumber = [string](Get-PropertyValue -Object $episode -Names @("episode_num", "episode_number", "episode"))
        $episodeTitle = [string](Get-PropertyValue -Object $episode -Names @("title", "name"))

        return [pscustomobject]@{
            episode_id = $episodeId
            container_extension = $containerExtension
            season_number = $seasonNumber
            episode_number = $episodeNumber
            episode_title = $episodeTitle
        }
    }

    return $null
}

function New-EpisodeResolverPreviewResult {
    [CmdletBinding()]
    param(
        [object]$Candidate,
        [string]$ResolverStatus,
        [string]$DiagnosticClass = "episode_resolution_pending",
        [string]$PlayabilityStatus = "inconclusive",
        [int]$NeedsReview = 0,
        [int]$SuppressedFromPlayback = 0,
        [string]$SupportSummary = "",
        [string]$ResolverError = "",
        [string]$EpisodeId = "",
        [string]$ContainerExtension = "",
        [string]$SeasonNumber = "",
        [string]$EpisodeNumber = "",
        [string]$EpisodeTitle = "",
        [object]$PlaybackUrlSummary = $null
    )

    $queueId = Convert-ToIntSafe -Value (Get-PropertyValue -Object $Candidate -Names @("queue_id", "id"))
    $localSeriesId = Convert-ToIntSafe -Value (Get-PropertyValue -Object $Candidate -Names @("local_series_id", "content_id", "series_id"))
    $providerSeriesId = [string](Get-PropertyValue -Object $Candidate -Names @("provider_series_id", "provider_content_id", "xtream_series_id"))
    $macUserId = Convert-ToIntSafe -Value (Get-PropertyValue -Object $Candidate -Names @("mac_user_id"))
    $provider = [string](Get-PropertyValue -Object $Candidate -Names @("provider"))
    $triggerReason = [string](Get-PropertyValue -Object $Candidate -Names @("trigger_reason"))
    $missingFields = [string](Get-PropertyValue -Object $Candidate -Names @("missing_fields"))

    if ($null -eq $PlaybackUrlSummary) {
        $PlaybackUrlSummary = Get-RedactedUrlSummary -Url ""
    }

    return [pscustomobject]@{
        queue_id = $queueId
        local_series_id = $localSeriesId
        provider_series_id = $providerSeriesId
        mac_user_id = $macUserId
        provider = $provider
        trigger_reason = $triggerReason
        missing_fields = $missingFields
        resolver_status = $ResolverStatus
        diagnostic_class = $DiagnosticClass
        playability_status = $PlayabilityStatus
        needs_review = $NeedsReview
        suppressed_from_playback = $SuppressedFromPlayback
        episode_id = $EpisodeId
        container_extension = $ContainerExtension
        season_number = $SeasonNumber
        episode_number = $EpisodeNumber
        episode_title = $EpisodeTitle
        playback_url_summary = $PlaybackUrlSummary
        support_case_preview = [pscustomobject]@{
            media_type = "series"
            diagnostic_class = $DiagnosticClass
            playability_status = $PlayabilityStatus
            needs_review = $NeedsReview
            suppressed_from_playback = $SuppressedFromPlayback
            support_summary = $SupportSummary
        }
        resolver_error = $ResolverError
    }
}

function Resolve-SeriesEpisodePreview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Candidate,

        [string]$ProviderApiBaseUrl = "",
        [string]$ProviderUsername = "",
        [string]$ProviderPassword = "",
        [int]$TimeoutSec = 20
    )

    $providerSeriesId = [string](Get-PropertyValue -Object $Candidate -Names @("provider_series_id", "provider_content_id", "xtream_series_id"))

    if ([string]::IsNullOrWhiteSpace($providerSeriesId)) {
        return New-EpisodeResolverPreviewResult `
            -Candidate $Candidate `
            -ResolverStatus "episode_resolution_missing_provider_series_id" `
            -SupportSummary "Provider series id is missing; no episode URL can be previewed yet."
    }

    if ([string]::IsNullOrWhiteSpace($ProviderApiBaseUrl) -or
        [string]::IsNullOrWhiteSpace($ProviderUsername) -or
        [string]::IsNullOrWhiteSpace($ProviderPassword)) {
        return New-EpisodeResolverPreviewResult `
            -Candidate $Candidate `
            -ResolverStatus "episode_resolution_missing_provider_api_config" `
            -SupportSummary "Provider API URL, username, or password is missing from the local environment; resolver preview skipped safely."
    }

    try {
        $seriesInfoUrl = Get-SeriesInfoUrl `
            -ProviderApiBaseUrl $ProviderApiBaseUrl `
            -ProviderUsername $ProviderUsername `
            -ProviderPassword $ProviderPassword `
            -ProviderSeriesId $providerSeriesId

        $seriesInfo = Invoke-RestMethod `
            -Uri $seriesInfoUrl `
            -Method Get `
            -TimeoutSec $TimeoutSec `
            -ErrorAction Stop

        $episode = Get-FirstEpisodeCandidateFromSeriesInfo -SeriesInfo $seriesInfo

        if ($null -eq $episode) {
            return New-EpisodeResolverPreviewResult `
                -Candidate $Candidate `
                -ResolverStatus "episode_resolution_no_episode_candidate" `
                -SupportSummary "Provider get_series_info returned no usable first episode candidate."
        }

        $streamBaseUrl = Get-ProviderStreamingBaseUrl -ProviderApiBaseUrl $ProviderApiBaseUrl
        $playbackUrl = "{0}/series/{1}/{2}/{3}.{4}" -f `
            $streamBaseUrl,
            $ProviderUsername,
            $ProviderPassword,
            $episode.episode_id,
            $episode.container_extension

        $safePlaybackUrl = $playbackUrl
        if (-not [string]::IsNullOrWhiteSpace($ProviderUsername)) {
            $safePlaybackUrl = $safePlaybackUrl.Replace($ProviderUsername, "USER")
        }
        if (-not [string]::IsNullOrWhiteSpace($ProviderPassword)) {
            $safePlaybackUrl = $safePlaybackUrl.Replace($ProviderPassword, "PASS")
        }

        $summary = Get-RedactedUrlSummary -Url $safePlaybackUrl
        $summary | Add-Member -MemberType NoteProperty -Name full_url_sha256 -Value (Get-StringSha256 -Text $playbackUrl) -Force

        return New-EpisodeResolverPreviewResult `
            -Candidate $Candidate `
            -ResolverStatus "episode_resolution_preview_ready" `
            -DiagnosticClass "episode_resolution_preview_ready" `
            -PlayabilityStatus "inconclusive" `
            -NeedsReview 0 `
            -SuppressedFromPlayback 0 `
            -SupportSummary "Episode playback URL preview was resolved. No probe, capture, queue update, artwork update, or support-case write was performed." `
            -EpisodeId $episode.episode_id `
            -ContainerExtension $episode.container_extension `
            -SeasonNumber $episode.season_number `
            -EpisodeNumber $episode.episode_number `
            -EpisodeTitle $episode.episode_title `
            -PlaybackUrlSummary $summary
    }
    catch {
        $safeError = Get-SecretRedactedText `
            -Text $_.Exception.Message `
            -Secrets @($ProviderUsername, $ProviderPassword)

        return New-EpisodeResolverPreviewResult `
            -Candidate $Candidate `
            -ResolverStatus "episode_resolution_failed" `
            -DiagnosticClass "episode_resolution_failed" `
            -PlayabilityStatus "inconclusive" `
            -NeedsReview 1 `
            -SuppressedFromPlayback 0 `
            -SupportSummary "Episode resolver preview failed before probing or capture." `
            -ResolverError $safeError
    }
}

function Get-EpisodeResolverPreviewRows {
    [CmdletBinding()]
    param(
        [object[]]$Candidates,
        [string]$ProviderApiBaseUrl = "",
        [string]$ProviderUsername = "",
        [string]$ProviderPassword = "",
        [int]$TimeoutSec = 20
    )

    $results = @()

    foreach ($candidate in @($Candidates)) {
        $results += Resolve-SeriesEpisodePreview `
            -Candidate $candidate `
            -ProviderApiBaseUrl $ProviderApiBaseUrl `
            -ProviderUsername $ProviderUsername `
            -ProviderPassword $ProviderPassword `
            -TimeoutSec $TimeoutSec
    }

    return $results
}

function Get-EpisodeResolverPreviewSummary {
    [CmdletBinding()]
    param(
        [object[]]$ResolverPreviewRows
    )

    $rows = @($ResolverPreviewRows)
    $readyCount = @($rows | Where-Object { $_.resolver_status -eq "episode_resolution_preview_ready" }).Count
    $failedCount = @($rows | Where-Object { $_.resolver_status -eq "episode_resolution_failed" }).Count
    $pendingCount = @($rows | Where-Object { $_.resolver_status -ne "episode_resolution_preview_ready" -and $_.resolver_status -ne "episode_resolution_failed" }).Count
    $manualNeededCount = @($rows | Where-Object { $_.needs_review -gt 0 }).Count

    return [pscustomobject]@{
        attempted_count = $rows.Count
        ready_count = $readyCount
        pending_count = $pendingCount
        failed_count = $failedCount
        manual_needed_count = $manualNeededCount
    }
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

function Test-FfmpegTooling {
    [CmdletBinding()]
    param()

    $ffprobe = Get-Command "ffprobe" -ErrorAction SilentlyContinue
    $ffmpeg = Get-Command "ffmpeg" -ErrorAction SilentlyContinue

    return [pscustomobject]@{
        ffprobe_available = ($null -ne $ffprobe)
        ffprobe_path = if ($null -ne $ffprobe) { $ffprobe.Source } else { "" }
        ffmpeg_available = ($null -ne $ffmpeg)
        ffmpeg_path = if ($null -ne $ffmpeg) { $ffmpeg.Source } else { "" }
    }
}

function Invoke-FfprobeUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [int]$TimeoutSec = 20
    )

    $tooling = Test-FfmpegTooling

    if (-not $tooling.ffprobe_available) {
        return [pscustomobject]@{
            status = "ffprobe_missing"
            ok = $false
            duration_seconds = 0
            exit_code = $null
            stderr = "ffprobe was not found in PATH"
            url_summary = Get-RedactedUrlSummary -Url $Url
        }
    }

    $tempOut = [System.IO.Path]::GetTempFileName()
    $tempErr = [System.IO.Path]::GetTempFileName()
    $durationText = ""
    $exitCode = $null

    try {
        $process = Start-Process `
            -FilePath $tooling.ffprobe_path `
            -ArgumentList @(
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                $Url
            ) `
            -NoNewWindow `
            -RedirectStandardOutput $tempOut `
            -RedirectStandardError $tempErr `
            -PassThru

        $completed = $process.WaitForExit($TimeoutSec * 1000)

        if (-not $completed) {
            try { $process.Kill() } catch { }
            return [pscustomobject]@{
                status = "probe_timeout"
                ok = $false
                duration_seconds = 0
                exit_code = $null
                stderr = "ffprobe timed out after $TimeoutSec seconds"
                url_summary = Get-RedactedUrlSummary -Url $Url
            }
        }

        $exitCode = $process.ExitCode
        if (Test-Path -LiteralPath $tempOut) {
            $durationText = Get-Content -LiteralPath $tempOut -Raw -ErrorAction SilentlyContinue
        }

        $stderrText = ""
        if (Test-Path -LiteralPath $tempErr) {
            $stderrText = Get-Content -LiteralPath $tempErr -Raw -ErrorAction SilentlyContinue
        }

        $duration = [decimal]0
        $durationOk = [decimal]::TryParse(($durationText -as [string]).Trim(), [ref]$duration)
        $isOk = ($exitCode -eq 0 -and $durationOk -and $duration -gt 0)

        return [pscustomobject]@{
            status = if ($isOk) { "probe_playable" } else { "probe_failed" }
            ok = $isOk
            duration_seconds = if ($durationOk) { [double]$duration } else { 0 }
            exit_code = $exitCode
            stderr = ($stderrText -as [string]).Trim()
            url_summary = Get-RedactedUrlSummary -Url $Url
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempOut) {
            Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $tempErr) {
            Remove-Item -LiteralPath $tempErr -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-FrameCaptureMetrics {
    [CmdletBinding()]
    param(
        [object[]]$Candidates,
        [string]$Mode,
        [object]$Tooling,
        [object]$ProbeResult,
        [string]$SourceName
    )

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

$script:RunId = New-RunId -Prefix "series-frame-capture"

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
            resolver_timeout_sec = $ResolverTimeoutSec
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

    if ($ResolveEpisodePreview -and ($Mode -eq "DbQuery" -or $Mode -eq "SnapshotInput") -and @($candidates).Count -gt 0) {
        $resolverPreviewRows = Get-EpisodeResolverPreviewRows `
            -Candidates $candidates `
            -ProviderApiBaseUrl $ProviderApiBaseUrl `
            -ProviderUsername $ProviderUsername `
            -ProviderPassword $ProviderPassword `
            -TimeoutSec $ResolverTimeoutSec

        $resolverPreviewSummary = Get-EpisodeResolverPreviewSummary -ResolverPreviewRows $resolverPreviewRows
    }

    $metrics = Get-FrameCaptureMetrics `
        -Candidates $candidates `
        -Mode $Mode `
        -Tooling $tooling `
        -ProbeResult $probeResult `
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
            episode_resolver_preview = $resolverPreviewSummary
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
            episode_resolver_preview_summary = $resolverPreviewSummary
            episode_resolver_preview_rows = $resolverPreviewRows
            note = "read-only frame capture artwork scaffold; no DB writes, no queue mutation, no support-case writes, and no artwork writes performed"
        } `
        -LogRoot $LogRoot | Out-Null

    if ($ResolveEpisodePreview) {
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
