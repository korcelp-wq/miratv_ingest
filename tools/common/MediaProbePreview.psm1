# MiraTV Media Probe Preview Helpers
# Extracted from tools/workers/capture_series_frame_artwork.ps1 as a no-behavior-change helper module.

Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot "FrameCapturePreviewCommon.psm1"
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "Required helper module not found at: $modulePath"
}
Import-Module $modulePath -Force -Global

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
        [int]$TimeoutSec = 20,
        [hashtable]$LogContext = @{},
        [string]$LogRoot = "runtime/logs"
    )

    $subcomponent = "media_probe_preview"
    $moduleName = "MediaProbePreview"
    $moduleStage = "resolved_episode_probe_preview"

    Write-FrameCaptureModuleEvent `
        -LogContext $LogContext `
        -ModuleName $moduleName `
        -Subcomponent $subcomponent `
        -ModuleStage $moduleStage `
        -EventType "module_started" `
        -Status "module_started" `
        -Payload @{ resolver_preview_count = @($ResolverPreviewRows).Count; timeout_sec = $TimeoutSec } `
        -LogRoot $LogRoot | Out-Null

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

    $summary = Get-EpisodeProbePreviewSummary -EpisodeProbePreviewRows $probeRows

    Write-FrameCaptureModuleEvent `
        -LogContext $LogContext `
        -ModuleName $moduleName `
        -Subcomponent $subcomponent `
        -ModuleStage $moduleStage `
        -EventType "module_completed" `
        -Status "module_completed" `
        -Payload @{ probe_attempted = $summary.attempted_count; probe_ready = $summary.ready_count; probe_failed = $summary.failed_count; probe_timeout = $summary.timeout_count; probe_http_error = $summary.provider_http_error_count; probe_unknown_failed = $summary.unknown_probe_failure_count } `
        -LogRoot $LogRoot | Out-Null

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

Export-ModuleMember -Function Get-HttpStatusProbeSignal, Get-EpisodeProbeFailureClassification, Get-EpisodeProbeErrorHint, New-EpisodeProbePreviewResult, Get-EpisodeProbePreviewRows, Get-EpisodeProbePreviewSummary, Test-FfmpegTooling, Invoke-FfprobeUrl
