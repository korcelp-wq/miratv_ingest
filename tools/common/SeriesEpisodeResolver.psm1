# MiraTV Series Episode Resolver Preview Helpers
# Extracted from tools/workers/capture_series_frame_artwork.ps1 as a no-behavior-change helper module.

Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot "FrameCapturePreviewCommon.psm1"
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "Required helper module not found at: $modulePath"
}
Import-Module $modulePath -Force -Global

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
        [int]$TimeoutSec = 20,
        [hashtable]$LogContext = @{},
        [string]$LogRoot = "runtime/logs"
    )

    $subcomponent = "series_episode_resolver"
    $moduleName = "SeriesEpisodeResolver"
    $moduleStage = "episode_resolution_preview"

    Write-FrameCaptureModuleEvent `
        -LogContext $LogContext `
        -ModuleName $moduleName `
        -Subcomponent $subcomponent `
        -ModuleStage $moduleStage `
        -EventType "module_started" `
        -Status "module_started" `
        -Payload @{ candidate_count = @($Candidates).Count; timeout_sec = $TimeoutSec } `
        -LogRoot $LogRoot

    try {
        $results = @()

        foreach ($candidate in @($Candidates)) {
            $results += Resolve-SeriesEpisodePreview `
                -Candidate $candidate `
                -ProviderApiBaseUrl $ProviderApiBaseUrl `
                -ProviderUsername $ProviderUsername `
                -ProviderPassword $ProviderPassword `
                -TimeoutSec $TimeoutSec
        }

        $summary = Get-EpisodeResolverPreviewSummary -ResolverPreviewRows $results

        Write-FrameCaptureModuleEvent `
            -LogContext $LogContext `
            -ModuleName $moduleName `
            -Subcomponent $subcomponent `
            -ModuleStage $moduleStage `
            -EventType "module_completed" `
            -Status "module_completed" `
            -Payload @{ resolver_attempted = $summary.attempted_count; resolver_ready = $summary.ready_count; resolver_pending = $summary.pending_count; resolver_failed = $summary.failed_count; resolver_manual_needed = $summary.manual_needed_count } `
            -LogRoot $LogRoot

        return $results
    }
    catch {
        Write-FrameCaptureModuleEvent `
            -LogContext $LogContext `
            -ModuleName $moduleName `
            -Subcomponent $subcomponent `
            -ModuleStage $moduleStage `
            -EventType "module_failed" `
            -Status "module_failed" `
            -Payload @{ error_message = $_.Exception.Message } `
            -LogRoot $LogRoot
        throw
    }
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

Export-ModuleMember -Function Get-ProviderApiUrl, Get-ProviderStreamingBaseUrl, Get-SeriesInfoUrl, Get-FirstEpisodeCandidateFromSeriesInfo, New-EpisodeResolverPreviewResult, Resolve-SeriesEpisodePreview, Get-EpisodeResolverPreviewRows, Get-EpisodeResolverPreviewSummary, Get-ResolvedEpisodePlaybackUrl, Get-SafePlaybackUrlForSummary
