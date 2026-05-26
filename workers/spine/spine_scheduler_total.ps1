# ==================================================
# MiraTV Spine Scheduler (CANONICAL)
# ==================================================
# Purpose:
#  - Time-based execution of EXISTING triggers
#  - Executes BOTH pull + stream phases
#  - No business logic
#  - No DB logic
#  - No curl
# ==================================================

$TRIGGERS = "C:\miratv_ingest\workers\spine\triggers"

$lastSeries = $null
$lastLive   = $null
$lastVod    = $null
$lastEpg    = $null

Write-Host "========================================="
Write-Host "MiraTV Spine Scheduler STARTED"
Write-Host "========================================="

while ($true) {

    $now  = Get-Date
    $hour = $now.Hour

    Write-Host ""
    Write-Host "---- Scheduler Tick ----" $now

    # --------------------------------------------------
    # SERIES — daily (02:00)
    # --------------------------------------------------
    if ($hour -eq 2 -and ($lastSeries -ne $now.Date)) {

        Write-Host "[SERIES] PULL"
        & "$TRIGGERS\pull_series_trigger.bat"

        Write-Host "[SERIES] STREAM"
        & "$TRIGGERS\stream_series_trigger.bat"

        $lastSeries = $now.Date
    }

    # --------------------------------------------------
    # LIVE — every 6 hours
    # --------------------------------------------------
    if (($hour % 6) -eq 0 -and $lastLive -ne $hour) {

        Write-Host "[LIVE] PULL STREAMS"
        & "$TRIGGERS\pull_live_streams_trigger.bat"

        Write-Host "[LIVE] PULL CATEGORIES"
        & "$TRIGGERS\pull_live_cat_trigger.bat"

        Write-Host "[LIVE] STREAM STREAMS"
        & "$TRIGGERS\stream_live_streams_trigger.bat"

        Write-Host "[LIVE] STREAM CATEGORIES"
        & "$TRIGGERS\stream_live_cat_trigger.bat"

        $lastLive = $hour
    }

    # --------------------------------------------------
    # VOD — every 12 hours
    # --------------------------------------------------
    if ($hour -in 0,12 -and $lastVod -ne $hour) {

        Write-Host "[VOD] PULL STREAMS"
        & "$TRIGGERS\pull_vod_streams_trigger.bat"

        Write-Host "[VOD] PULL CATEGORIES"
        & "$TRIGGERS\pull_vod_cat_trigger.bat"

        Write-Host "[VOD] STREAM STREAMS"
        & "$TRIGGERS\stream_vod_streams_trigger.bat"

        Write-Host "[VOD] STREAM CATEGORIES"
        & "$TRIGGERS\stream_vod_cat_trigger.bat"

        $lastVod = $hour
    }

    # --------------------------------------------------
    # EPG — daily (04:00)
    # --------------------------------------------------
    if ($hour -eq 4 -and ($lastEpg -ne $now.Date)) {

        Write-Host "[EPG] PULL"
        & "$TRIGGERS\pull_epg_trigger.bat"

        Write-Host "[EPG] STREAM"
        & "$TRIGGERS\stream_epg_trigger.bat"

        $lastEpg = $now.Date
    }

    # --------------------------------------------------
    # Sleep (5 minutes)
    # --------------------------------------------------
    Start-Sleep -Seconds 300
}
