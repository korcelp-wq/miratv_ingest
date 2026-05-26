# ==================================================
# STEP 9.5 — Materialize VOD Canonical Info (REMOTE)
# File: triggers\95materialize_vod_batch_runner.ps1
# Purpose: Call materialize_vod.php over HTTPS
#          to fill missing canonical fields on VOD rows
# ==================================================

param(
    [Parameter(Mandatory = $true)]
    [int]$VodId
)

Write-Host "==============================================="
Write-Host "MiraTV MATERIALIZE VOD TRIGGER (STEP 9.5)"
Write-Host "==============================================="

$ErrorActionPreference = "Stop"

# ---------------- CONFIG ----------------

$BaseMaterializeUrl = "https://miratv.club/_workers/materialize_vod5.php"
$Token              = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$TIMEOUT_SEC        = 60

# ---------------- EXECUTION ----------------
try {
    if ($VodId -le 0) {
        throw "VodId must be greater than 0"
    }

    $MATERIALIZE_URL = "{0}?token={1}&vod_id={2}" -f $BaseMaterializeUrl, $Token, $VodId

    Write-Host "Running ingest for vod_id=$VodId"
    Write-Host "▶ Calling materialize_vod.php"
    Write-Host "▶ URL: $MATERIALIZE_URL"

    $response = Invoke-WebRequest `
        -Uri $MATERIALIZE_URL `
        -Method GET `
        -TimeoutSec $TIMEOUT_SEC `
        -UseBasicParsing

    if ($response.StatusCode -ne 200) {
        throw "HTTP $($response.StatusCode)"
    }

    $body = $response.Content
    if (-not [string]::IsNullOrWhiteSpace($body)) {
        Write-Host "▶ Response: $body"
    }

    Write-Host "✔ VOD materialization complete"
}
catch {
    Write-Error "✖ MATERIALIZE VOD FAILED :: $($_.Exception.Message)"
    exit 1
}

Write-Host "==============================================="
Write-Host "END MATERIALIZE VOD TRIGGER"
Write-Host "==============================================="

exit 0