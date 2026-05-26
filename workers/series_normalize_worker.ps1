# =========================================================
# MiraTV Series Normalize Worker (QUEUE DRAIN MODE)
# =========================================================

Write-Host "========================================="
Write-Host "MiraTV Series Normalize Worker"
Write-Host "========================================="
Write-Host "🚀 Worker started (queue-drain mode)"

# ------------------ CONFIG ------------------

$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$NORMALIZER = Join-Path $SCRIPT_DIR "series_normalize.ps1"

$SLEEP_SECONDS = 2
$MAX_ERRORS    = 5
$errorCount    = 0

# ------------------ VALIDATION ------------------

if (!(Test-Path $NORMALIZER)) {
    Write-Error "❌ series_normalize.ps1 not found at $NORMALIZER"
    exit 1
}

# ------------------ MAIN LOOP ------------------

while ($true) {

    Write-Host "🔎 Checking for raw series payloads..."

    try {
        & $NORMALIZER
        $exitCode = $LASTEXITCODE
    } catch {
        Write-Error "❌ Normalizer threw an exception"
        $errorCount++
        Start-Sleep -Seconds $SLEEP_SECONDS
        continue
    }

    # ------------------------------------------------
    # Exit conditions
    # ------------------------------------------------

    if ($exitCode -eq 0) {
        Write-Host "✅ No remaining payloads — worker exiting cleanly"
        break
    }

    if ($exitCode -ne 0) {
        $errorCount++
        Write-Warning "⚠️ Normalizer error (count=$errorCount)"

        if ($errorCount -ge $MAX_ERRORS) {
            Write-Error "🔥 Max error threshold reached — aborting worker"
            exit 1
        }
    } else {
        # Successful normalization
        $errorCount = 0
    }

    Start-Sleep -Seconds $SLEEP_SECONDS
}

Write-Host "🧊 Series Normalize Worker complete"
Write-Host "========================================="
