# =========================================================
# MiraTV Episode Stream Resolver Worker (QUEUE DRAIN MODE)
# =========================================================

Write-Host "========================================="
Write-Host "MiraTV Episode Stream Resolver Worker"
Write-Host "========================================="
Write-Host "🚀 Worker started (queue-drain mode)"

# ------------------ CONFIG ------------------

$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$RESOLVER   = Join-Path $SCRIPT_DIR "episode_stream_resolver.ps1"

$SLEEP_SECONDS = 2
$MAX_ERRORS    = 5
$errorCount    = 0

# ------------------ VALIDATION ------------------

if (!(Test-Path $RESOLVER)) {
    Write-Error "❌ episode_stream_resolver.ps1 not found at $RESOLVER"
    exit 1
}

# ------------------ MAIN LOOP ------------------

while ($true) {

    Write-Host "🔎 Checking for unresolved episode streams..."

    try {
        & $RESOLVER
        $exitCode = $LASTEXITCODE
    } catch {
        Write-Error "❌ Resolver threw an exception"
        $errorCount++
        Start-Sleep -Seconds $SLEEP_SECONDS
        continue
    }

    # ------------------------------------------------
    # Exit conditions
    # ------------------------------------------------

    if ($exitCode -eq 0) {
        Write-Host "✅ No unresolved episodes — worker exiting cleanly"
        break
    }

    if ($exitCode -ne 0) {
        $errorCount++
        Write-Warning "⚠️ Resolver error (count=$errorCount)"

        if ($errorCount -ge $MAX_ERRORS) {
            Write-Error "🔥 Max error threshold reached — aborting worker"
            exit 1
        }
    } else {
        # Successful resolution
        $errorCount = 0
    }

    Start-Sleep -Seconds $SLEEP_SECONDS
}

Write-Host "🧊 Episode Stream Resolver Worker complete"
Write-Host "========================================="
