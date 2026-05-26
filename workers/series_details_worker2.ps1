# =========================================================
# MiraTV Series Details Worker (RAW INGEST ONLY)
# =========================================================

Write-Host "========================================="
Write-Host "MiraTV Series Details Worker"
Write-Host "========================================="
Write-Host "MiraTV Series Details Worker STARTED"

# ------------------ HARD REQUIREMENTS ------------------

# Force TLS 1.2 (MANDATORY on Windows)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ------------------ CONFIG ------------------

$INGEST_ENDPOINT = "https://miratv.club/_ingest/get_next_series.php"
$INGEST_TOKEN    = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"

$COLLECTION      = "C:\miratv_ingest\sCollection.postman_collection.json"
$RAW_DIR         = "C:\miratv_ingest\raw_store"
$NEWMAN_BIN      = "newman"

# Ensure raw store exists
if (!(Test-Path $RAW_DIR)) {
    New-Item -ItemType Directory -Path $RAW_DIR | Out-Null
}

# ------------------ FETCH NEXT SERIES ------------------

Write-Host "Fetching next series ID..."

try {
    $next = Invoke-RestMethod `
        -Uri $INGEST_ENDPOINT `
        -Method GET `
        -Headers @{ "X-INGEST-TOKEN" = $INGEST_TOKEN } `
        -TimeoutSec 30
} catch {
    Write-Error "HTTP failure fetching next series"
    Write-Error $_.Exception.Message
    exit 1
}

if ($next.done -eq $true) {
    Write-Host "No series remaining. Worker exiting."
    exit 0
}

$seriesId   = $next.series_id
$internalId = $next.internal_id

Write-Host "Processing series_id=$seriesId (internal_id=$internalId)"

# ------------------ RUN NEWMAN (STDOUT CAPTURE) ------------------

$rawFile = Join-Path $RAW_DIR "series_$seriesId.raw.json"

Write-Host "Running Newman (stdout capture)..."

$stdout = & $NEWMAN_BIN run $COLLECTION `
    --folder get_series_info `
    --env-var series_id=$seriesId `
    --verbose 2>&1 | Out-String

# Always write what we got
$stdout | Out-File -FilePath $rawFile -Encoding utf8

$bytes = (Get-Item $rawFile).Length

if ($bytes -eq 0) {
    Write-Error "Newman produced ZERO output"
    exit 1
}

Write-Host "Raw payload captured"
Write-Host "Bytes written: $bytes"
Write-Host "File: $rawFile"

# ------------------ DONE ------------------

Write-Host "Worker complete (raw capture only, no parsing)"
Write-Host "========================================="

exit