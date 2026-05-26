Write-Host "========================================="
Write-Host "MiraTV Series Materializer Worker (STEP 9)"
Write-Host "========================================="

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ------------------ HARD REQUIREMENTS ------------------

# Force TLS 1.2 (MANDATORY on Windows)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ------------------ CONFIG ------------------

$INGEST_ENDPOINT = "https://miratv.club/_workers/series_pipeline.php"
$INGEST_TOKEN    = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"

# ------------------ FETCH NEXT SERIES ------------------

Write-Host "🔍 Fetching next series ID..."

try {
    $next = Invoke-RestMethod `
        -Uri $INGEST_ENDPOINT `
        -Method GET `
        -Headers @{ "X-INGEST-TOKEN" = $INGEST_TOKEN } `
        -TimeoutSec 30
} catch {
    Write-Error "❌ HTTP failure fetching next series"
    Write-Error $_.Exception.Message
    exit 1
}

if ($next.done -eq $true) {
    Write-Host "✅ No series remaining. Worker exiting."
    exit 0
}

$seriesId   = $next.series_id

Write-Host "🎬 Processing series_id=$seriesId"



# ------------------ FETCH NEXT SERIES ------------------

$INGEST_TOKEN2 = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$PHP_ENDPOINT = "https://miratv.club/_ingest/series_materialize.php"

Write-Host "Materializing series_id=$seriesId"

try {
    $result = Invoke-RestMethod `
        -Uri $PHP_ENDPOINT `
        -Method POST `
        -Headers @{ "X-INGEST-TOKEN" = $INGEST_TOKEN2 } `
        -Body (@{ series_id = $seriesId } | ConvertTo-Json) `
        -ContentType "application/json" `
        -TimeoutSec 120
}
catch {
    Write-Error "Materialization HTTP failure"
    Write-Error $_.Exception.Message
    exit 2
}

if ($result.status -ne "ok") {
    Write-Error "Materialization failed"
    $result | ConvertTo-Json -Depth 6
    exit 3
}

Write-Host "✔ Materialization succeeded for series_id=$seriesId"
exit 0
