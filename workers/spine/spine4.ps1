# =========================================================
# MiraTV Ingest Spine — Self-Scheduling Loop (AUTHORITATIVE)
# Schedule locked by user:
# - live streams:    every 30 minutes
# - live categories: every 12 hours
# - vod streams:     every 24 hours (02:00–05:00 only)
# - vod categories:  every 24 hours (02:00–05:00 only)
# - series index:    weekly          (02:00–05:00 only)
# - epg:             daily           (02:00–05:00 only)
# =========================================================

$ErrorActionPreference = "Continue"

# ------------------ ROOTS ------------------
$ROOT  = "C:\miratv_ingest"
$STATE = Join-Path $ROOT "state"
$LOGS  = Join-Path $ROOT "logs"
$LOG   = Join-Path $LOGS "spine.log"

$TRIGGERS = Join-Path $ROOT "workers\spine\triggers"

$SLEEP_SECONDS = 60

# ------------------ ENSURE DIRS ------------------
foreach ($d in @($STATE, $LOGS)) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }
}

# ------------------ LOGGING ------------------
function Log([string]$msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $msg"
    $line | Tee-Object -FilePath $LOG -Append
}

# ------------------ STATE CHECK ------------------
function Due([string]$name, [int]$minutes) {
    $file = Join-Path $STATE "$name.last"
    if (-not (Test-Path $file)) { return $true }
    $age = (Get-Date) - (Get-Item $file).LastWriteTime
    return ($age.TotalMinutes -ge $minutes)
}

function MarkRun([string]$name) {
    Set-Content (Join-Path $STATE "$name.last") (Get-Date)
}

# ------------------ TIME WINDOW ------------------
function InNightWindow {
    $hour = (Get-Date).Hour
    return ($hour -ge 2 -and $hour -le 5)
}

# ------------------ RUNNER (BAT SAFE) ------------------
function Run-TriggerBat([string]$batName, [string]$tag) {
    $batPath = Join-Path $TRIGGERS $batName

    if (-not (Test-Path $batPath)) {
        Log "ERROR missing trigger: $batPath"
        return $false
    }

    Log "RUN $tag -> $batName"

    # Use CMD to run .bat reliably
    & cmd.exe /c "`"$batPath`""
    $code = $LASTEXITCODE

    if ($code -ne 0) {
        Log "ERROR $tag failed (exit $code)"
        return $false
    }

    Log "OK $tag complete"
    return $true
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
        # LIVE STREAMS — every 30 minutes
        if (Due "live_streams" $LIVE_STREAMS_MIN) {
            if (Run-TriggerBat "pull_live_trigger.bat" "live_streams") {
                MarkRun "live_streams"
            }
        }

        # LIVE CATEGORIES — every 12 hours
        if (Due "live_categories" $LIVE_CATEGORIES_MIN) {
            if (Run-TriggerBat "pull_live_cat_trigger.bat" "live_categories") {
                MarkRun "live_categories"
            }
        }

        # NIGHT WINDOW JOBS (02:00–05:00 ONLY)
        if (InNightWindow) {

            # VOD STREAMS — daily
            if (Due "vod_streams" $VOD_STREAMS_MIN) {
                if (Run-TriggerBat "pull_vod_trigger.bat" "vod_streams") {
                    MarkRun "vod_streams"
                }
            }

            # VOD CATEGORIES — daily
            if (Due "vod_categories" $VOD_CATEGORIES_MIN) {
                if (Run-TriggerBat "pull_vod_cat_trigger.bat" "vod_categories") {
                    MarkRun "vod_categories"
                }
            }

            # SERIES INDEX — weekly
            if (Due "series_index" $SERIES_INDEX_MIN) {
                if (Run-TriggerBat "pull_series_trigger.bat" "series_index") {
                    MarkRun "series_index"
                }
            }

            # EPG — daily
            if (Due "epg" $EPG_MIN) {
                if (Run-TriggerBat "pull_epg_trigger.bat" "epg") {
                    MarkRun "epg"
                }
            }
        }
    }
    catch {
        Log "ERROR: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds $SLEEP_SECONDS
}
