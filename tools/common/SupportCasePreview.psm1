# MiraTV Support Case Preview Helpers
# Extracted from tools/workers/capture_series_frame_artwork.ps1 as a no-behavior-change helper module.

Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot "FrameCapturePreviewCommon.psm1"
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "Required helper module not found at: $modulePath"
}
Import-Module $modulePath -Force -Global

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
        [object[]]$EpisodeProbePreviewRows,
        [hashtable]$LogContext = @{},
        [string]$LogRoot = "runtime/logs"
    )

    $subcomponent = "support_case_preview"
    $moduleName = "SupportCasePreview"
    $moduleStage = "support_case_preview_payload"

    Write-FrameCaptureModuleEvent `
        -LogContext $LogContext `
        -ModuleName $moduleName `
        -Subcomponent $subcomponent `
        -ModuleStage $moduleStage `
        -EventType "module_started" `
        -Status "module_started" `
        -Payload @{ resolver_preview_count = @($ResolverPreviewRows).Count; episode_probe_preview_count = @($EpisodeProbePreviewRows).Count } `
        -LogRoot $LogRoot

    try {
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

        $summary = Get-SupportCasePreviewSummary -SupportCasePreviewRows $rows

        Write-FrameCaptureModuleEvent `
            -LogContext $LogContext `
            -ModuleName $moduleName `
            -Subcomponent $subcomponent `
            -ModuleStage $moduleStage `
            -EventType "module_completed" `
            -Status "module_completed" `
            -Payload @{ support_case_preview_rows = $summary.preview_row_count; support_case_preview_needs_review = $summary.needs_review_count; support_case_preview_probe_ready = $summary.probe_ready_count; support_case_preview_no_write = $summary.no_write_count } `
            -LogRoot $LogRoot

        return $rows
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

Export-ModuleMember -Function Get-SupportCaseKeyPreview, New-SupportCasePreviewRow, Get-SupportCasePreviewRows, Get-SupportCasePreviewSummary
