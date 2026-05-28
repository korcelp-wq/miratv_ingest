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


function Get-SafeProbeStderrSnippet {
    [CmdletBinding()]
    param(
        [string]$Text = "",
        [string[]]$Secrets = @(),
        [int]$MaxLength = 240
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $safe = Get-SecretRedactedText -Text $Text -Secrets $Secrets

    # ffprobe can echo a request URL in stderr. Never allow full playback URLs into logs.
    $safe = [regex]::Replace($safe, '(?i)https?://[^\s''"<>]+', 'REDACTED_URL')

    # Remove terminal/control noise and collapse multiline stderr into a compact one-line diagnostic.
    $safe = [regex]::Replace($safe, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', ' ')
    $safe = [regex]::Replace($safe, '\s+', ' ').Trim()

    if ($MaxLength -lt 40) {
        $MaxLength = 40
    }

    if ($safe.Length -gt $MaxLength) {
        return $safe.Substring(0, $MaxLength)
    }

    return $safe
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

function Get-ResolvedEpisodePlaybackUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$ResolverPreviewRow,

        [Parameter(Mandatory = $true)]
        [string]$ProviderApiBaseUrl,

        [Parameter(Mandatory = $true)]
        [string]$ProviderUsername,

        [Parameter(Mandatory = $true)]
        [string]$ProviderPassword
    )

    $episodeId = [string](Get-PropertyValue -Object $ResolverPreviewRow -Names @("episode_id"))
    $containerExtension = [string](Get-PropertyValue -Object $ResolverPreviewRow -Names @("container_extension"))

    if ([string]::IsNullOrWhiteSpace($episodeId)) {
        return ""
    }

    if ([string]::IsNullOrWhiteSpace($containerExtension)) {
        $containerExtension = "mp4"
    }

    $containerExtension = $containerExtension.Trim().TrimStart(".")
    $streamBaseUrl = Get-ProviderStreamingBaseUrl -ProviderApiBaseUrl $ProviderApiBaseUrl

    if ([string]::IsNullOrWhiteSpace($streamBaseUrl) -or
        [string]::IsNullOrWhiteSpace($ProviderUsername) -or
        [string]::IsNullOrWhiteSpace($ProviderPassword)) {
        return ""
    }

    return "{0}/series/{1}/{2}/{3}.{4}" -f `
        $streamBaseUrl,
        $ProviderUsername,
        $ProviderPassword,
        $episodeId,
        $containerExtension
}

function Get-SafePlaybackUrlForSummary {
    [CmdletBinding()]
    param(
        [string]$PlaybackUrl,
        [string]$ProviderUsername = "",
        [string]$ProviderPassword = ""
    )

    $safeUrl = $PlaybackUrl

    if (-not [string]::IsNullOrWhiteSpace($ProviderUsername)) {
        $safeUrl = $safeUrl.Replace($ProviderUsername, "USER")
    }

    if (-not [string]::IsNullOrWhiteSpace($ProviderPassword)) {
        $safeUrl = $safeUrl.Replace($ProviderPassword, "PASS")
    }

    return $safeUrl
}


function Get-HttpStatusProbeSignal {
    [CmdletBinding()]
    param(
        [string]$Text = ""
    )

    $raw = ([string]$Text).Trim()
    $lower = $raw.ToLowerInvariant()

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{
            status = ""
            family = ""
            hint = ""
        }
    }

    $patterns = @(
        "(?i)http[/ ]?\d(?:\.\d)?\s+(?<code>[1-5][0-9][0-9])\b",
        "(?i)(?:server returned|status|http error|response code|error code|returned code|returned)[^0-9]{0,60}(?<code>[1-5][0-9][0-9])\b",
        "(?i)\b(?<code>401|403|404|406|408|429|500|502|503|504)\b"
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match($raw, $pattern)
        if ($match.Success) {
            $code = $match.Groups["code"].Value
            return [pscustomobject]@{
                status = $code
                family = if ($code.StartsWith("4")) { "4xx" } elseif ($code.StartsWith("5")) { "5xx" } else { "" }
                hint = "http_$code"
            }
        }
    }

    if ($lower -like "*not acceptable*") {
        return [pscustomobject]@{
            status = "406"
            family = "4xx"
            hint = "http_406_not_acceptable"
        }
    }

    if ($lower -like "*unauthorized*") {
        return [pscustomobject]@{
            status = "401"
            family = "4xx"
            hint = "http_401_unauthorized"
        }
    }

    if ($lower -like "*forbidden*") {
        return [pscustomobject]@{
            status = "403"
            family = "4xx"
            hint = "http_403_forbidden"
        }
    }

    if ($lower -like "*not found*") {
        return [pscustomobject]@{
            status = "404"
            family = "4xx"
            hint = "http_404_not_found"
        }
    }

    if ($lower -like "*too many requests*") {
        return [pscustomobject]@{
            status = "429"
            family = "4xx"
            hint = "http_429_too_many_requests"
        }
    }

    if ($lower -like "*4xx*" -or $lower -like "*client error*") {
        return [pscustomobject]@{
            status = "4xx"
            family = "4xx"
            hint = "http_4xx_unparsed"
        }
    }

    if ($lower -like "*5xx*" -or $lower -like "*server error*") {
        return [pscustomobject]@{
            status = "5xx"
            family = "5xx"
            hint = "http_5xx_unparsed"
        }
    }

    if ($lower -like "*server returned*" -or $lower -like "*http error*" -or $lower -like "*http response*") {
        return [pscustomobject]@{
            status = "unparsed"
            family = ""
            hint = "provider_http_error_unparsed"
        }
    }

    return [pscustomobject]@{
        status = ""
        family = ""
        hint = ""
    }
}

function Get-EpisodeProbeFailureClassification {
    [CmdletBinding()]
    param(
        [string]$EpisodeProbeStatus = "",
        [bool]$ProbeOk = $false,
        [AllowNull()]
        [object]$ExitCode = $null,
        [string]$ProbeErrorSummary = ""
    )

    if ($ProbeOk -or $EpisodeProbeStatus -eq "episode_probe_ready") {
        return [pscustomobject]@{
            failure_class = "probe_ready"
            http_status = ""
            failure_diagnostic = "Resolved episode URL is probeable."
        }
    }

    $text = ([string]$ProbeErrorSummary).Trim()
    $lower = $text.ToLowerInvariant()
    $statusLower = ([string]$EpisodeProbeStatus).ToLowerInvariant()
    $httpStatus = ""

    $httpSignal = Get-HttpStatusProbeSignal -Text $text
    $httpStatus = [string]$httpSignal.status
    $httpFamily = [string]$httpSignal.family

    if ($statusLower -like "*timeout*" -or $lower -like "*timed out*") {
        return [pscustomobject]@{
            failure_class = "probe_timeout"
            http_status = $httpStatus
            failure_diagnostic = "ffprobe timed out while testing the resolved episode URL."
        }
    }

    if ($statusLower -like "*ffprobe_missing*" -or $lower -like "*ffprobe was not found*") {
        return [pscustomobject]@{
            failure_class = "ffprobe_missing"
            http_status = $httpStatus
            failure_diagnostic = "ffprobe is not available in PATH."
        }
    }

    if ($httpStatus -eq "406" -or $lower -like "*not acceptable*") {
        return [pscustomobject]@{
            failure_class = "provider_unavailable_or_406"
            http_status = if ([string]::IsNullOrWhiteSpace($httpStatus)) { "406" } else { $httpStatus }
            failure_diagnostic = "Provider rejected the resolved episode URL; likely unavailable, entitlement/bouquet-gated, or stale."
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($httpStatus)) {
        return [pscustomobject]@{
            failure_class = "provider_http_error"
            http_status = $httpStatus
            failure_diagnostic = if ($httpStatus -eq "unparsed") { "Provider returned an HTTP error while probing the resolved episode URL, but ffprobe did not expose a numeric status." } elseif ($httpStatus -eq "4xx" -or $httpStatus -eq "5xx") { "Provider returned an HTTP $httpStatus class error while probing the resolved episode URL." } else { "Provider returned HTTP $httpStatus while probing the resolved episode URL." }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($httpFamily)) {
        return [pscustomobject]@{
            failure_class = "provider_http_error"
            http_status = $httpFamily
            failure_diagnostic = "Provider returned an HTTP $httpFamily class error while probing the resolved episode URL."
        }
    }

    if ($lower -like "*could not resolve*" -or
        $lower -like "*name or service not known*" -or
        $lower -like "*connection refused*" -or
        $lower -like "*connection reset*" -or
        $lower -like "*network is unreachable*" -or
        $lower -like "*no route to host*" -or
        $lower -like "*tls*" -or
        $lower -like "*ssl*" -or
        $lower -like "*handshake*") {
        return [pscustomobject]@{
            failure_class = "network_error"
            http_status = $httpStatus
            failure_diagnostic = "Network/DNS/TLS connection failed while probing the resolved episode URL."
        }
    }

    if ($lower -like "*invalid data found*" -or
        $lower -like "*moov atom not found*" -or
        $lower -like "*could not find codec*" -or
        $lower -like "*codec*" -or
        $lower -like "*unsupported*" -or
        $lower -like "*error parsing*" -or
        $lower -like "*format*" -or
        $lower -like "*duration: n/a*") {
        return [pscustomobject]@{
            failure_class = "container_probe_failed"
            http_status = $httpStatus
            failure_diagnostic = "ffprobe reached the URL but could not classify usable media/container data."
        }
    }

    if ($statusLower -like "*missing_playback_url*") {
        return [pscustomobject]@{
            failure_class = "missing_playback_url"
            http_status = $httpStatus
            failure_diagnostic = "Resolver row did not provide a usable playback URL."
        }
    }

    if ($statusLower -like "*skipped_not_resolved*") {
        return [pscustomobject]@{
            failure_class = "not_attempted_unresolved"
            http_status = $httpStatus
            failure_diagnostic = "Resolver preview was not ready; probe was intentionally skipped."
        }
    }

    return [pscustomobject]@{
        failure_class = "unknown_probe_failure"
        http_status = $httpStatus
        failure_diagnostic = "ffprobe failed, but the error did not match a known provider, network, container, or tooling pattern."
    }
}

function Get-EpisodeProbeErrorHint {
    [CmdletBinding()]
    param(
        [string]$EpisodeProbeStatus = "",
        [bool]$ProbeOk = $false,
        [AllowNull()]
        [object]$ExitCode = $null,
        [string]$ProbeErrorSummary = ""
    )

    if ($ProbeOk -or $EpisodeProbeStatus -eq "episode_probe_ready") {
        return "probe_ready"
    }

    $text = ([string]$ProbeErrorSummary).Trim()
    $lower = $text.ToLowerInvariant()
    $statusLower = ([string]$EpisodeProbeStatus).ToLowerInvariant()
    $exitText = if ($null -eq $ExitCode) { "" } else { [string]$ExitCode }

    if ($statusLower -like "*timeout*" -or $lower -like "*timed out*") {
        return "probe_timeout"
    }

    if ($statusLower -like "*ffprobe_missing*" -or $lower -like "*ffprobe was not found*") {
        return "ffprobe_missing"
    }

    $httpSignal = Get-HttpStatusProbeSignal -Text $text
    if (-not [string]::IsNullOrWhiteSpace([string]$httpSignal.hint)) {
        return [string]$httpSignal.hint
    }

    if ($lower -like "*invalid data found*") {
        return "invalid_media_data"
    }

    if ($lower -like "*moov atom not found*") {
        return "moov_atom_not_found"
    }

    if ($lower -like "*end of file*" -or $lower -eq "eof") {
        return "stream_empty_or_eof"
    }

    if ($lower -like "*could not find codec*" -or $lower -like "*unsupported codec*" -or $lower -like "*codec*") {
        return "codec_or_container_issue"
    }

    if ($lower -like "*could not resolve*" -or $lower -like "*name or service not known*" -or $lower -like "*no such host*") {
        return "dns_resolution_failed"
    }

    if ($lower -like "*connection refused*") {
        return "connection_refused"
    }

    if ($lower -like "*connection reset*") {
        return "connection_reset"
    }

    if ($lower -like "*server returned*" -or $lower -like "*http error*") {
        return "provider_http_error_unparsed"
    }

    if ([string]::IsNullOrWhiteSpace($text) -and -not [string]::IsNullOrWhiteSpace($exitText) -and $exitText -ne "0") {
        return "ffprobe_exit_${exitText}_no_stderr"
    }

    if (-not [string]::IsNullOrWhiteSpace($exitText) -and $exitText -ne "0") {
        return "ffprobe_exit_${exitText}_unclassified"
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        return "no_stderr_available"
    }

    return "unclassified_probe_error"
}

function New-EpisodeProbePreviewResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$ResolverPreviewRow,

        [string]$EpisodeProbeStatus,
        [bool]$ProbeOk = $false,
        [double]$DurationSeconds = 0,
        [AllowNull()]
        [object]$ExitCode = $null,
        [string]$ProbeErrorSummary = "",
        [object]$PlaybackUrlSummary = $null,
        [string]$FailureClass = "",
        [string]$HttpStatus = "",
        [string]$FailureDiagnostic = "",
        [string]$ProbeStderrSnippetRedacted = ""
    )

    if ($null -eq $PlaybackUrlSummary) {
        $PlaybackUrlSummary = Get-RedactedUrlSummary -Url ""
    }

    if ([string]::IsNullOrWhiteSpace($ProbeStderrSnippetRedacted)) {
        $ProbeStderrSnippetRedacted = $ProbeErrorSummary
    }

    if ([string]::IsNullOrWhiteSpace($FailureClass) -or [string]::IsNullOrWhiteSpace($FailureDiagnostic)) {
        $classification = Get-EpisodeProbeFailureClassification `
            -EpisodeProbeStatus $EpisodeProbeStatus `
            -ProbeOk $ProbeOk `
            -ExitCode $ExitCode `
            -ProbeErrorSummary $ProbeErrorSummary

        if ([string]::IsNullOrWhiteSpace($FailureClass)) {
            $FailureClass = [string]$classification.failure_class
        }
        if ([string]::IsNullOrWhiteSpace($HttpStatus)) {
            $HttpStatus = [string]$classification.http_status
        }
        if ([string]::IsNullOrWhiteSpace($FailureDiagnostic)) {
            $FailureDiagnostic = [string]$classification.failure_diagnostic
        }
    }

    $queueId = Convert-ToIntSafe -Value (Get-PropertyValue -Object $ResolverPreviewRow -Names @("queue_id"))
    $localSeriesId = Convert-ToIntSafe -Value (Get-PropertyValue -Object $ResolverPreviewRow -Names @("local_series_id"))
    $providerSeriesId = [string](Get-PropertyValue -Object $ResolverPreviewRow -Names @("provider_series_id"))
    $episodeId = [string](Get-PropertyValue -Object $ResolverPreviewRow -Names @("episode_id"))
    $containerExtension = [string](Get-PropertyValue -Object $ResolverPreviewRow -Names @("container_extension"))

    return [pscustomobject]@{
        queue_id = $queueId
        local_series_id = $localSeriesId
        provider_series_id = $providerSeriesId
        episode_id = $episodeId
        container_extension = $containerExtension
        episode_probe_status = $EpisodeProbeStatus
        probe_ok = $ProbeOk
        duration_seconds = $DurationSeconds
        exit_code = $ExitCode
        episode_probe_exit_code = $ExitCode
        probe_error_summary = $ProbeErrorSummary
        episode_probe_stderr_summary_redacted = $ProbeErrorSummary
        episode_probe_stderr_snippet_redacted = $ProbeStderrSnippetRedacted
        episode_probe_stderr_snippet_sha256 = if ([string]::IsNullOrWhiteSpace($ProbeStderrSnippetRedacted)) { "" } else { Get-StringSha256 -Text $ProbeStderrSnippetRedacted }
        episode_probe_error_hint = Get-EpisodeProbeErrorHint -EpisodeProbeStatus $EpisodeProbeStatus -ProbeOk $ProbeOk -ExitCode $ExitCode -ProbeErrorSummary $ProbeErrorSummary
        episode_probe_failure_class = $FailureClass
        episode_probe_http_status = $HttpStatus
        episode_probe_failure_diagnostic = $FailureDiagnostic
        playback_url_summary = $PlaybackUrlSummary
        capture_preview = [pscustomobject]@{
            capture_allowed_now = $false
            capture_would_be_allowed_later = $ProbeOk
            reason = if ($ProbeOk) { "Resolved episode URL is probeable; frame capture remains disabled until a later gated step." } else { "Resolved episode URL is not probeable yet; no capture attempted. $FailureDiagnostic" }
        }
    }
}

function Get-EpisodeProbePreviewRows {
    [CmdletBinding()]
    param(
        [object[]]$ResolverPreviewRows,
        [string]$ProviderApiBaseUrl = "",
        [string]$ProviderUsername = "",
        [string]$ProviderPassword = "",
        [int]$TimeoutSec = 20
    )

    $probeRows = @()

    foreach ($row in @($ResolverPreviewRows)) {
        if ($null -eq $row) {
            continue
        }

        $resolverStatus = [string](Get-PropertyValue -Object $row -Names @("resolver_status"))

        if ($resolverStatus -ne "episode_resolution_preview_ready") {
            $probeRows += New-EpisodeProbePreviewResult `
                -ResolverPreviewRow $row `
                -EpisodeProbeStatus "episode_probe_skipped_not_resolved" `
                -ProbeErrorSummary "Resolver preview was not ready, so no ffprobe call was attempted."
            continue
        }

        $playbackUrl = Get-ResolvedEpisodePlaybackUrl `
            -ResolverPreviewRow $row `
            -ProviderApiBaseUrl $ProviderApiBaseUrl `
            -ProviderUsername $ProviderUsername `
            -ProviderPassword $ProviderPassword

        if ([string]::IsNullOrWhiteSpace($playbackUrl)) {
            $probeRows += New-EpisodeProbePreviewResult `
                -ResolverPreviewRow $row `
                -EpisodeProbeStatus "episode_probe_missing_playback_url" `
                -ProbeErrorSummary "Resolved episode row did not produce a playback URL."
            continue
        }

        $safePlaybackUrl = Get-SafePlaybackUrlForSummary `
            -PlaybackUrl $playbackUrl `
            -ProviderUsername $ProviderUsername `
            -ProviderPassword $ProviderPassword

        $safeUrlSummary = Get-RedactedUrlSummary -Url $safePlaybackUrl
        $safeUrlSummary | Add-Member -MemberType NoteProperty -Name full_url_sha256 -Value (Get-StringSha256 -Text $playbackUrl) -Force

        try {
            $probeResult = Invoke-FfprobeUrl -Url $playbackUrl -TimeoutSec $TimeoutSec
            $safeStderr = Get-SafeProbeStderrSnippet `
                -Text ([string]$probeResult.stderr) `
                -Secrets @($ProviderUsername, $ProviderPassword, $playbackUrl) `
                -MaxLength 300

            $episodeProbeStatus = if ($probeResult.ok) { "episode_probe_ready" } else { "episode_probe_$($probeResult.status)" }
            $classification = Get-EpisodeProbeFailureClassification `
                -EpisodeProbeStatus $episodeProbeStatus `
                -ProbeOk ([bool]$probeResult.ok) `
                -ExitCode $probeResult.exit_code `
                -ProbeErrorSummary $safeStderr

            $probeRows += New-EpisodeProbePreviewResult `
                -ResolverPreviewRow $row `
                -EpisodeProbeStatus $episodeProbeStatus `
                -ProbeOk ([bool]$probeResult.ok) `
                -DurationSeconds ([double]$probeResult.duration_seconds) `
                -ExitCode $probeResult.exit_code `
                -ProbeErrorSummary $safeStderr `
                -PlaybackUrlSummary $safeUrlSummary `
                -FailureClass ([string]$classification.failure_class) `
                -HttpStatus ([string]$classification.http_status) `
                -FailureDiagnostic ([string]$classification.failure_diagnostic) `
                -ProbeStderrSnippetRedacted $safeStderr
        }
        catch {
            $safeError = Get-SafeProbeStderrSnippet `
                -Text $_.Exception.Message `
                -Secrets @($ProviderUsername, $ProviderPassword, $playbackUrl) `
                -MaxLength 300

            $classification = Get-EpisodeProbeFailureClassification `
                -EpisodeProbeStatus "episode_probe_exception" `
                -ProbeOk $false `
                -ExitCode $null `
                -ProbeErrorSummary $safeError

            $probeRows += New-EpisodeProbePreviewResult `
                -ResolverPreviewRow $row `
                -EpisodeProbeStatus "episode_probe_exception" `
                -ProbeErrorSummary $safeError `
                -PlaybackUrlSummary $safeUrlSummary `
                -FailureClass ([string]$classification.failure_class) `
                -HttpStatus ([string]$classification.http_status) `
                -FailureDiagnostic ([string]$classification.failure_diagnostic) `
                -ProbeStderrSnippetRedacted $safeError
        }
    }

    return $probeRows
}

function Get-EpisodeProbePreviewSummary {
    [CmdletBinding()]
    param(
        [object[]]$EpisodeProbePreviewRows
    )

    $rows = @($EpisodeProbePreviewRows)
    $readyCount = @($rows | Where-Object { $_.episode_probe_status -eq "episode_probe_ready" }).Count
    $timeoutCount = @($rows | Where-Object { $_.episode_probe_status -eq "episode_probe_probe_timeout" }).Count
    $failedCount = @($rows | Where-Object {
        $_.episode_probe_status -ne "episode_probe_ready" -and
        $_.episode_probe_status -ne "episode_probe_skipped_not_resolved"
    }).Count
    $skippedCount = @($rows | Where-Object { $_.episode_probe_status -eq "episode_probe_skipped_not_resolved" }).Count

    $provider406Count = @($rows | Where-Object { $_.episode_probe_failure_class -eq "provider_unavailable_or_406" }).Count
    $providerHttpErrorCount = @($rows | Where-Object { $_.episode_probe_failure_class -eq "provider_http_error" }).Count
    $http401Count = @($rows | Where-Object { $_.episode_probe_http_status -eq "401" }).Count
    $http403Count = @($rows | Where-Object { $_.episode_probe_http_status -eq "403" }).Count
    $http404Count = @($rows | Where-Object { $_.episode_probe_http_status -eq "404" }).Count
    $http406Count = @($rows | Where-Object { $_.episode_probe_http_status -eq "406" }).Count
    $http429Count = @($rows | Where-Object { $_.episode_probe_http_status -eq "429" }).Count
    $http5xxCount = @($rows | Where-Object { ([string]$_.episode_probe_http_status) -like "5*" -or $_.episode_probe_http_status -eq "5xx" }).Count
    $http4xxUnparsedCount = @($rows | Where-Object { $_.episode_probe_http_status -eq "4xx" }).Count
    $http5xxUnparsedCount = @($rows | Where-Object { $_.episode_probe_http_status -eq "5xx" }).Count
    $httpUnparsedCount = @($rows | Where-Object { $_.episode_probe_http_status -eq "unparsed" }).Count
    $networkErrorCount = @($rows | Where-Object { $_.episode_probe_failure_class -eq "network_error" }).Count
    $containerProbeFailedCount = @($rows | Where-Object { $_.episode_probe_failure_class -eq "container_probe_failed" }).Count
    $ffprobeMissingCount = @($rows | Where-Object { $_.episode_probe_failure_class -eq "ffprobe_missing" }).Count
    $unknownProbeFailureCount = @($rows | Where-Object { $_.episode_probe_failure_class -eq "unknown_probe_failure" }).Count
    $missingPlaybackUrlCount = @($rows | Where-Object { $_.episode_probe_failure_class -eq "missing_playback_url" }).Count
    $nonzeroNoStderrCount = @($rows | Where-Object { ([string]$_.episode_probe_error_hint) -like "ffprobe_exit_*_no_stderr" }).Count
    $streamEmptyOrEofCount = @($rows | Where-Object { $_.episode_probe_error_hint -eq "stream_empty_or_eof" }).Count
    $invalidMediaDataCount = @($rows | Where-Object { $_.episode_probe_error_hint -eq "invalid_media_data" }).Count
    $codecOrContainerIssueCount = @($rows | Where-Object { $_.episode_probe_error_hint -eq "codec_or_container_issue" }).Count

    $hintValues = @($rows | ForEach-Object { [string]$_.episode_probe_error_hint } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $hintSummary = ($hintValues -join ",")
    $stderrSnippetCount = @($rows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.episode_probe_stderr_snippet_redacted) }).Count

    return [pscustomobject]@{
        attempted_count = @($rows | Where-Object { $_.episode_probe_status -ne "episode_probe_skipped_not_resolved" }).Count
        ready_count = $readyCount
        failed_count = $failedCount
        timeout_count = $timeoutCount
        skipped_count = $skippedCount
        provider_unavailable_or_406_count = $provider406Count
        provider_http_error_count = $providerHttpErrorCount
        http_401_count = $http401Count
        http_403_count = $http403Count
        http_404_count = $http404Count
        http_406_count = $http406Count
        http_429_count = $http429Count
        http_5xx_count = $http5xxCount
        http_4xx_unparsed_count = $http4xxUnparsedCount
        http_5xx_unparsed_count = $http5xxUnparsedCount
        http_unparsed_count = $httpUnparsedCount
        network_error_count = $networkErrorCount
        container_probe_failed_count = $containerProbeFailedCount
        ffprobe_missing_count = $ffprobeMissingCount
        unknown_probe_failure_count = $unknownProbeFailureCount
        missing_playback_url_count = $missingPlaybackUrlCount
        ffprobe_exit_nonzero_no_stderr_count = $nonzeroNoStderrCount
        stream_empty_or_eof_count = $streamEmptyOrEofCount
        invalid_media_data_count = $invalidMediaDataCount
        codec_or_container_issue_count = $codecOrContainerIssueCount
        stderr_snippet_count = $stderrSnippetCount
        error_hints = $hintSummary
    }
}


function Get-SupportCaseKeyPreview {
    [CmdletBinding()]
    param(
        [object]$ResolverPreviewRow,
        [object]$EpisodeProbePreviewRow = $null,
        [string]$DiagnosticClass = ""
    )

    $macUserId = [string](Get-PropertyValue -Object $ResolverPreviewRow -Names @("mac_user_id"))
    $provider = [string](Get-PropertyValue -Object $ResolverPreviewRow -Names @("provider"))
    $localSeriesId = [string](Get-PropertyValue -Object $ResolverPreviewRow -Names @("local_series_id"))
    $providerSeriesId = [string](Get-PropertyValue -Object $ResolverPreviewRow -Names @("provider_series_id"))
    $episodeId = [string](Get-PropertyValue -Object $ResolverPreviewRow -Names @("episode_id"))

    if ($null -ne $EpisodeProbePreviewRow) {
        $probeEpisodeId = [string](Get-PropertyValue -Object $EpisodeProbePreviewRow -Names @("episode_id"))
        if (-not [string]::IsNullOrWhiteSpace($probeEpisodeId)) {
            $episodeId = $probeEpisodeId
        }
    }

    $rawKey = "series_frame_capture_preview|mac=$macUserId|provider=$provider|local_series_id=$localSeriesId|provider_series_id=$providerSeriesId|episode_id=$episodeId|diagnostic=$DiagnosticClass"
    return Get-StringSha256 -Text $rawKey
}

function New-SupportCasePreviewRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$ResolverPreviewRow,

        [object]$EpisodeProbePreviewRow = $null
    )

    $queueId = Convert-ToIntSafe -Value (Get-PropertyValue -Object $ResolverPreviewRow -Names @("queue_id"))
    $localSeriesId = Convert-ToIntSafe -Value (Get-PropertyValue -Object $ResolverPreviewRow -Names @("local_series_id"))
    $providerSeriesId = [string](Get-PropertyValue -Object $ResolverPreviewRow -Names @("provider_series_id"))
    $macUserId = Convert-ToIntSafe -Value (Get-PropertyValue -Object $ResolverPreviewRow -Names @("mac_user_id"))
    $provider = [string](Get-PropertyValue -Object $ResolverPreviewRow -Names @("provider"))
    $triggerReason = [string](Get-PropertyValue -Object $ResolverPreviewRow -Names @("trigger_reason"))
    $missingFields = [string](Get-PropertyValue -Object $ResolverPreviewRow -Names @("missing_fields"))
    $episodeId = [string](Get-PropertyValue -Object $ResolverPreviewRow -Names @("episode_id"))
    $containerExtension = [string](Get-PropertyValue -Object $ResolverPreviewRow -Names @("container_extension"))
    $episodeTitle = [string](Get-PropertyValue -Object $ResolverPreviewRow -Names @("episode_title"))
    $resolverStatus = [string](Get-PropertyValue -Object $ResolverPreviewRow -Names @("resolver_status"))
    $resolverDiagnosticClass = [string](Get-PropertyValue -Object $ResolverPreviewRow -Names @("diagnostic_class"))
    $resolverPlayabilityStatus = [string](Get-PropertyValue -Object $ResolverPreviewRow -Names @("playability_status"))
    $resolverNeedsReview = Convert-ToIntSafe -Value (Get-PropertyValue -Object $ResolverPreviewRow -Names @("needs_review"))
    $resolverSuppressed = Convert-ToIntSafe -Value (Get-PropertyValue -Object $ResolverPreviewRow -Names @("suppressed_from_playback"))
    $resolverError = [string](Get-PropertyValue -Object $ResolverPreviewRow -Names @("resolver_error"))

    $probeRan = 0
    $probeStatus = "not_run"
    $diagnosticClass = $resolverDiagnosticClass
    $playabilityStatus = $resolverPlayabilityStatus
    $needsReview = $resolverNeedsReview
    $suppressedFromPlayback = $resolverSuppressed
    $supportSummary = "Episode resolver preview has not reached probeable media yet. No support case write was performed."
    $supportDetail = "resolver_status=$resolverStatus; trigger_reason=$triggerReason; missing_fields=$missingFields"
    $userMessage = "Playback details were inspected in preview mode. No support case was written."
    $probeFailureClass = ""
    $probeHttpStatus = ""
    $probeErrorHint = ""
    $probeExitCode = ""
    $stderrSnippetHash = ""
    $playbackUrlSummary = Get-PropertyValue -Object $ResolverPreviewRow -Names @("playback_url_summary")

    if ($null -ne $EpisodeProbePreviewRow) {
        $probeRan = 1
        $probeStatus = [string](Get-PropertyValue -Object $EpisodeProbePreviewRow -Names @("episode_probe_status"))
        $probeOk = [bool](Get-PropertyValue -Object $EpisodeProbePreviewRow -Names @("probe_ok"))
        $probeFailureClass = [string](Get-PropertyValue -Object $EpisodeProbePreviewRow -Names @("episode_probe_failure_class"))
        $probeHttpStatus = [string](Get-PropertyValue -Object $EpisodeProbePreviewRow -Names @("episode_probe_http_status"))
        $probeErrorHint = [string](Get-PropertyValue -Object $EpisodeProbePreviewRow -Names @("episode_probe_error_hint"))
        $probeExitCode = [string](Get-PropertyValue -Object $EpisodeProbePreviewRow -Names @("episode_probe_exit_code"))
        $stderrSnippetHash = [string](Get-PropertyValue -Object $EpisodeProbePreviewRow -Names @("episode_probe_stderr_snippet_sha256"))
        $probeDiagnostic = [string](Get-PropertyValue -Object $EpisodeProbePreviewRow -Names @("episode_probe_failure_diagnostic"))
        $probePlaybackSummary = Get-PropertyValue -Object $EpisodeProbePreviewRow -Names @("playback_url_summary")
        if ($null -ne $probePlaybackSummary) {
            $playbackUrlSummary = $probePlaybackSummary
        }

        $probeEpisodeId = [string](Get-PropertyValue -Object $EpisodeProbePreviewRow -Names @("episode_id"))
        if (-not [string]::IsNullOrWhiteSpace($probeEpisodeId)) {
            $episodeId = $probeEpisodeId
        }

        $probeContainerExtension = [string](Get-PropertyValue -Object $EpisodeProbePreviewRow -Names @("container_extension"))
        if (-not [string]::IsNullOrWhiteSpace($probeContainerExtension)) {
            $containerExtension = $probeContainerExtension
        }

        if ($probeOk -or $probeStatus -eq "episode_probe_ready") {
            $diagnosticClass = "frame_capture_probe_ready_preview"
            $playabilityStatus = "probe_ready"
            $needsReview = 0
            $suppressedFromPlayback = 0
            $supportSummary = "Resolved episode probe preview is ready for a later gated frame-capture step. No support case write was performed."
            $supportDetail = "resolver_status=$resolverStatus; probe_status=$probeStatus; episode_id=$episodeId; container_extension=$containerExtension"
            $userMessage = "This episode resolved and probed successfully in preview mode."
        }
        else {
            $diagnosticClass = if ([string]::IsNullOrWhiteSpace($probeFailureClass)) { "episode_probe_failed_preview" } else { "episode_probe_$probeFailureClass" }
            $playabilityStatus = if ($probeStatus -eq "episode_probe_probe_timeout") { "probe_timeout" } else { "probe_failed" }
            $needsReview = 1
            $suppressedFromPlayback = 0
            $supportSummary = "Resolved episode probe preview failed. No support case write was performed."
            $supportDetail = "resolver_status=$resolverStatus; probe_status=$probeStatus; failure_class=$probeFailureClass; http_status=$probeHttpStatus; error_hint=$probeErrorHint; exit_code=$probeExitCode; diagnostic=$probeDiagnostic"
            $userMessage = "Playback details were captured in preview mode for review."
        }
    }
    elseif ($resolverStatus -ne "episode_resolution_preview_ready") {
        $needsReview = $resolverNeedsReview
        $suppressedFromPlayback = 0
        $supportSummary = "Episode resolution preview did not produce a probeable playback URL. No support case write was performed."
        $supportDetail = "resolver_status=$resolverStatus; resolver_error=$resolverError; trigger_reason=$triggerReason; missing_fields=$missingFields"
        $userMessage = "Playback details were not complete enough to probe yet."
    }

    $playbackUrlHash = ""
    if ($null -ne $playbackUrlSummary) {
        $playbackUrlHash = [string](Get-PropertyValue -Object $playbackUrlSummary -Names @("full_url_sha256", "url_sha256"))
    }

    $supportCaseKey = Get-SupportCaseKeyPreview `
        -ResolverPreviewRow $ResolverPreviewRow `
        -EpisodeProbePreviewRow $EpisodeProbePreviewRow `
        -DiagnosticClass $diagnosticClass

    return [pscustomobject]@{
        preview_only = $true
        would_write_support_case = $false
        support_case_key_preview = $supportCaseKey
        queue_id = $queueId
        mac_user_id = $macUserId
        provider = $provider
        provider_dns = $provider
        media_type = "series"
        media_id = $localSeriesId
        provider_item_id = $providerSeriesId
        provider_episode_id = $episodeId
        container_extension = $containerExtension
        screen_type = "series_frame_capture_artwork"
        title = $episodeTitle
        category_id = ""
        provider_category_name = ""
        playback_url_hash = $playbackUrlHash
        original_failure_source = "series_port_900_image_repair_preview"
        original_failure_message = $missingFields
        http_status = $probeHttpStatus
        probe_ran = $probeRan
        probe_status = $probeStatus
        diagnostic_class = $diagnosticClass
        playability_status = $playabilityStatus
        support_summary = $supportSummary
        support_detail = $supportDetail
        user_message = $userMessage
        suppressed_from_playback = $suppressedFromPlayback
        needs_review = $needsReview
        resolver_status = $resolverStatus
        probe_failure_class = $probeFailureClass
        probe_error_hint = $probeErrorHint
        probe_exit_code = $probeExitCode
        stderr_snippet_sha256 = $stderrSnippetHash
    }
}

function Get-SupportCasePreviewRows {
    [CmdletBinding()]
    param(
        [object[]]$ResolverPreviewRows,
        [object[]]$EpisodeProbePreviewRows
    )

    $probeRows = @($EpisodeProbePreviewRows)
    $rows = @()

    foreach ($resolverRow in @($ResolverPreviewRows)) {
        $queueId = Convert-ToIntSafe -Value (Get-PropertyValue -Object $resolverRow -Names @("queue_id"))
        $localSeriesId = Convert-ToIntSafe -Value (Get-PropertyValue -Object $resolverRow -Names @("local_series_id"))
        $providerSeriesId = [string](Get-PropertyValue -Object $resolverRow -Names @("provider_series_id"))

        $matchingProbeRow = @($probeRows | Where-Object {
            (Convert-ToIntSafe -Value (Get-PropertyValue -Object $_ -Names @("queue_id"))) -eq $queueId -and
            (Convert-ToIntSafe -Value (Get-PropertyValue -Object $_ -Names @("local_series_id"))) -eq $localSeriesId -and
            ([string](Get-PropertyValue -Object $_ -Names @("provider_series_id"))) -eq $providerSeriesId
        } | Select-Object -First 1)

        $probeRow = $null
        if (@($matchingProbeRow).Count -gt 0) {
            $probeRow = @($matchingProbeRow)[0]
        }

        $rows += New-SupportCasePreviewRow `
            -ResolverPreviewRow $resolverRow `
            -EpisodeProbePreviewRow $probeRow
    }

    return $rows
}

function Get-SupportCasePreviewSummary {
    [CmdletBinding()]
    param(
        [object[]]$SupportCasePreviewRows
    )

    $rows = @($SupportCasePreviewRows)
    return [pscustomobject]@{
        preview_row_count = $rows.Count
        would_write_count = 0
        no_write_count = $rows.Count
        needs_review_count = @($rows | Where-Object { (Convert-ToIntSafe -Value $_.needs_review) -eq 1 }).Count
        suppressed_from_playback_count = @($rows | Where-Object { (Convert-ToIntSafe -Value $_.suppressed_from_playback) -eq 1 }).Count
        probe_ready_count = @($rows | Where-Object { $_.playability_status -eq "probe_ready" }).Count
        probe_failed_count = @($rows | Where-Object { $_.playability_status -eq "probe_failed" }).Count
        probe_timeout_count = @($rows | Where-Object { $_.playability_status -eq "probe_timeout" }).Count
        resolver_pending_count = @($rows | Where-Object { $_.probe_ran -eq 0 -and $_.resolver_status -ne "episode_resolution_preview_ready" }).Count
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
            -TimeoutSec $ResolverTimeoutSec

        $resolverPreviewSummary = Get-EpisodeResolverPreviewSummary -ResolverPreviewRows $resolverPreviewRows
    }

    if ($ProbeResolvedEpisodePreview -and @($resolverPreviewRows).Count -gt 0) {
        $episodeProbePreviewRows = Get-EpisodeProbePreviewRows `
            -ResolverPreviewRows $resolverPreviewRows `
            -ProviderApiBaseUrl $ProviderApiBaseUrl `
            -ProviderUsername $ProviderUsername `
            -ProviderPassword $ProviderPassword `
            -TimeoutSec $EpisodeProbeTimeoutSec

        $episodeProbePreviewSummary = Get-EpisodeProbePreviewSummary -EpisodeProbePreviewRows $episodeProbePreviewRows
    }

    if (@($resolverPreviewRows).Count -gt 0) {
        $supportCasePreviewRows = Get-SupportCasePreviewRows `
            -ResolverPreviewRows $resolverPreviewRows `
            -EpisodeProbePreviewRows $episodeProbePreviewRows

        $supportCasePreviewSummary = Get-SupportCasePreviewSummary -SupportCasePreviewRows $supportCasePreviewRows
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
