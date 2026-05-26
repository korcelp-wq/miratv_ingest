# =========================================================
# MiraTV Ingest Spine — Self-Scheduling Loop (AUTHORITATIVE)
# =========================================================

$ErrorActionPreference = "Continue"

# ------------------ ROOTS ------------------
$ROOT  = "C:\miratv_ingest"
$STATE = "$ROOT\state"
$LOGS  = "$ROOT\logs"
$LOG   = "$LOGS\spine.log"

$TRIGGERS = "$ROOT\workers\spine\triggers"

$SLEEP_SECONDS = 60

# ------------------ ENSURE DIRS ------------------
foreach ($d in @($STATE, $LOGS)) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }
}

# ------------------ LOGGING ------------------
function Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $msg"
    $line | Tee-Object -FilePath $LOG -Append
}

# ------------------ STATE CHECK ------------------
function Due($name, $minutes) {
    $file = "$STATE\$name.last"
    if (-not (Test-Path $file)) { return $true }
    $age = (Get-Date) - (Get-Item $file).LastWriteTime
    return ($age.TotalMinutes -ge $minutes)
}

function MarkRun($name) {
    Set-Content "$STATE\$name.last" (Get-Date)
}

# ------------------ TIME WINDOW ------------------
function InNightWindow {
    $hour = (Get-Date).Hour
    return ($hour -ge 2 -and $hour -le 5)
}

# ------------------ SCHEDULE (MINUTES) ------------------
$LIVE_STREAMS_MIN    = 30
$LIVE_CATEGORIES_MIN = 720      # 12 hours
$VOD_STREAMS_MIN     = 1440     # 24 hours
$VOD_CATEGORIES_MIN  = 1440
$SERIES_INDEX_MIN    = 10080    # 7 days
$EPG_MIN             = 1440

# ------------------ START ------------------
Log "Spine loop started"

while ($true) {

    try {

        # ==================================================
        # LIVE STREAMS — every 30 minutes (any time)
        # ==================================================
        if (Due "live_streams" $LIVE_STREAMS_MIN) {
            Log "RUN live_streams"
            powershell -NoProfile -ExecutionPolicy Bypass `
                -File "$TRIGGERS\pull_live_trigger.bat"
            MarkRun "live_streams"
        }

        # ==================================================
        # LIVE CATEGORIES — every 12 hours (any time)
        # ==================================================
        if (Due "live_categories" $LIVE_CATEGORIES_MIN) {
            Log "RUN live_categories"
            powershell -NoProfile -ExecutionPolicy Bypass `
                -File "$TRIGGERS\pull_live_cat_trigger.bat"
            MarkRun "live_categories"
        }

        # ==================================================
        # NIGHT WINDOW JOBS (02:00–05:00 ONLY)
        # ==================================================
        if (InNightWindow) {

            # ------------------ VOD STREAMS — daily ------------------
            if (Due "vod_streams" $VOD_STREAMS_MIN) {
                Log "RUN vod_streams"
                powershell -NoProfile -ExecutionPolicy Bypass `
                    -File "$TRIGGERS\pull_vod_trigger.bat"
                MarkRun "vod_streams"
            }

            # ------------------ VOD CATEGORIES — daily ------------------
            if (Due "vod_categories" $VOD_CATEGORIES_MIN) {
                Log "RUN vod_categories"
                powershell -NoProfile -ExecutionPolicy Bypass `
                    -File "$TRIGGERS\pull_vod_cat_trigger.bat"
                MarkRun "vod_categories"
            }

            # ------------------ SERIES INDEX — weekly ------------------
            if (Due "series_index" $SERIES_INDEX_MIN) {
                Log "RUN series_index"
                powershell -NoProfile -ExecutionPolicy Bypass `
                    -File "$TRIGGERS\pull_series_trigger.bat"
                MarkRun "series_index"
            }

            # ------------------ EPG — daily ------------------
            if (Due "epg" $EPG_MIN) {
                Log "RUN epg"
                powershell -NoProfile -ExecutionPolicy Bypass `
                    -File "$TRIGGERS\pull_epg_trigger.bat"
                MarkRun "epg"
            }
        }

    }
    catch {
        Log "ERROR: $_"
    }

    Start-Sleep -Seconds $SLEEP_SECONDS
}
