# =========================================================
# MiraTV Spine Scheduler (UNLOCKED / SAFE)
# Purpose:
#  - Time-based orchestration only
#  - Calls existing trigger .bat files
#  - NO business logic
#  - NO ingest logic
#  - Does NOT touch locked spine runner
# =========================================================

$ROOT     = "C:\miratv_ingest\workers\spine"
$TRIGGERS = "$ROOT\triggers"
$STATE    = "$ROOT\state"
$LOG      = "$ROOT\spine_scheduler.log"

$SLEEP_SECONDS = 60   # check every minute

# ------------------ ENSURE DIRS ------------------
foreach ($dir in @($STATE)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }
}

# ------------------ HELPERS ------------------
function Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $msg"
    Add-Content -Path $LOG -Value $line
    Write-Host $line
}

function LastRun($name) {
    $file = "$STATE\$name.last"
    if (Test-Path $file) {
        return [int64](Get-Content $file)
    }
    return 0
}

function MarkRun($name) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Set-Content "$STATE\$name.last" $now
}

function Due($name, $intervalSeconds) {
    $last = LastRun $name
    $now  = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    return (($now - $last) -ge $intervalSeconds)
}

function RunTrigger($label, $batFile) {
    Log "RUN $label"
    cmd.exe /c "`"$batFile`""
    if ($LASTEXITCODE -ne 0) {
        Log "FAIL $label (exit $LASTEXITCODE)"
        return $false
    }
    Log "OK $label"
    return $true
}

# ------------------ START ------------------
Log "Spine scheduler started"

while ($true) {

    # LIVE STREAMS — every 30 minutes
    if (Due "live_streams" 1800) {
        if (RunTrigger "LIVE_STREAMS" "$TRIGGERS\stream_live_streams_trigger.bat") {
            MarkRun "live_streams"
        }
    }

    # LIVE CATEGORIES — every 12 hours
    if (Due "live_categories" 43200) {
        if (RunTrigger "LIVE_CATEGORIES" "$TRIGGERS\stream_live_cat_trigger.bat") {
            MarkRun "live_categories"
        }
    }

    # VOD STREAMS — every 24 hours
    if (Due "vod_streams" 86400) {
        if (RunTrigger "VOD_STREAMS" "$TRIGGERS\stream_vod_streams_trigger.bat") {
            MarkRun "vod_streams"
        }
    }

    # VOD CATEGORIES — every 24 hours
    if (Due "vod_categories" 86400) {
        if (RunTrigger "VOD_CATEGORIES" "$TRIGGERS\stream_vod_cat_trigger.bat") {
            MarkRun "vod_categories"
        }
    }

    # SERIES — weekly (2–5am window optional later)
    if (Due "series" 604800) {
        if (RunTrigger "SERIES" "$TRIGGERS\stream_series_trigger.bat") {
            MarkRun "series"
        }
    }

    # EPG — every 12 hours
    if (Due "epg" 43200) {
        if (RunTrigger "EPG" "$TRIGGERS\stream_epg_trigger.bat") {
            MarkRun "epg"
        }
    }

    Start-Sleep -Seconds $SLEEP_SECONDS
}
