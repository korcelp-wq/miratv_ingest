# ==================================================
# STEP 9.5 — Materialize Series Canonical Info (REMOTE)
# File: triggers\9materialize_series_trigger.ps1
# Purpose: Call materialize_series.php over HTTPS
#          to fill missing canonical fields on parent
#          series row before finalization
# ==================================================

param(
    [int]$SeriesId
)

Write-Host "==============================================="
Write-Host "MiraTV MATERIALIZE SERIES TRIGGER (STEP 9.5)"
Write-Host "==============================================="

$ErrorActionPreference = "Stop"

# ---------------- CONFIG ----------------

$MATERIALIZE_URL = "https://miratv.club/_workers/materialize_series4.php?token=WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$TIMEOUT_SEC     = 60

# ---------------- EXECUTION ----------------
try {
    Write-Host "Running ingest for series_id=$SeriesId"
    Write-Host "▶ Calling materialize_series.php"
    Write-Host "▶ URL: $MATERIALIZE_URL"

    $response = Invoke-WebRequest `
        -Uri $MATERIALIZE_URL `
        -Method GET `
        -TimeoutSec $TIMEOUT_SEC `
        -UseBasicParsing

    if ($response.StatusCode -ne 200) {
        throw "HTTP $($response.StatusCode)"
    }

    Write-Host "✔ Series materialization complete"
}
catch {
    Write-Error "✖ MATERIALIZE SERIES FAILED :: $($_.Exception.Message)"
    exit 1
}

Write-Host "==============================================="
Write-Host "END MATERIALIZE SERIES TRIGGER"
Write-Host "==============================================="

exit 0