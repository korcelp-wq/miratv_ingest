# ==================================================
# STEP 10 — Finalize Series Stream (REMOTE)
# File: triggers\10_finalize_series_trigger.ps1
# Purpose: Call finalize_series.php over HTTPS
# ==================================================

Write-Host "========================================="
Write-Host "MiraTV FINALIZE SERIES TRIGGER (STEP 10)"
Write-Host "========================================="

$ErrorActionPreference = "Stop"

# ---------------- CONFIG ----------------

$FINALIZE_URL = "https://miratv.club/_workers/finalize_series.php?token=WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$TIMEOUT_SEC  = 60

# ---------------- EXECUTION ----------------
try {
    Write-Host "▶ Calling finalize_series.php"
    Write-Host "▶ URL: $FINALIZE_URL"

    $response = Invoke-WebRequest `
        -Uri $FINALIZE_URL `
        -Method GET `
        -TimeoutSec $TIMEOUT_SEC `
        -UseBasicParsing

    if ($response.StatusCode -ne 200) {
        throw "HTTP $($response.StatusCode)"
    }

    Write-Host "✔ Series finalization complete"
}
catch {
    Write-Error "✖ FINALIZE SERIES FAILED :: $($_.Exception.Message)"
    exit 1
}

Write-Host "========================================="
Write-Host "END FINALIZE SERIES TRIGGER"
Write-Host "========================================="

exit 0
