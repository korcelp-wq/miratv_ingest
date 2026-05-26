# =========================================================
# MiraTV — Series Details Ingest Driver (PowerShell)
# =========================================================

$TOKEN      = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$BASE_URL   = "https://miratv.club/_ingest"
$PROVIDER   = "http://uxurwymd.eldervpn.xyz:8080"
$USERNAME   = "Marina2025"
$PASSWORD   = "3KY586YR"

$WORKDIR = "C:\miratv_ingest"
$NEXT_JSON = "$WORKDIR\next_series.json"
$INFO_JSON = "$WORKDIR\series_info.json"

Write-Host "=== MiraTV Series Detail Ingest ===" -ForegroundColor Cyan

while ($true) {

    Write-Host "`nChecking for next series..." -ForegroundColor Yellow

    try {
        Invoke-RestMethod `
            -Uri "$BASE_URL/get_next_series.php" `
            -Headers @{ "X-Ingest-Token" = $TOKEN } `
            -OutFile $NEXT_JSON
    }
    catch {
        Write-Host "ERROR: Cannot reach get_next_series.php" -ForegroundColor Red
        Start-Sleep -Seconds 30
        continue
    }

    $next = Get-Content $NEXT_JSON | ConvertFrom-Json

    if ($next.done -eq $true) {
        Write-Host "`nAll series processed. Exiting cleanly." -ForegroundColor Green
        break
    }

    $SERIES_ID = $next.series_id
    Write-Host "Processing series_id: $SERIES_ID" -ForegroundColor Cyan

    # -------------------------------------------------
    # Fetch series info from provider
    # -------------------------------------------------
    $seriesInfoUrl = "$PROVIDER/player_api.php?username=$USERNAME&password=$PASSWORD&action=get_series_info&series_id=$SERIES_ID"

    try {
        Invoke-RestMethod `
            -Uri $seriesInfoUrl `
            -OutFile $INFO_JSON
    }
    catch {
        Write-Host "ERROR: Provider fetch failed for $SERIES_ID" -ForegroundColor Red
        Start-Sleep -Seconds 60
        continue
    }

    # -------------------------------------------------
    # Upload to MiraTV ingest endpoint
    # -------------------------------------------------
    try {
        Invoke-RestMethod `
            -Uri "$BASE_URL/import_series_info.php" `
            -Method Post `
            -Headers @{
                "X-Ingest-Token" = $TOKEN
                "Content-Type"  = "application/json"
            } `
            -InFile $INFO_JSON
    }
    catch {
        Write-Host "ERROR: Upload failed for $SERIES_ID" -ForegroundColor Red
        Start-Sleep -Seconds 60
        continue
    }

    Write-Host "✔ Completed series_id $SERIES_ID" -ForegroundColor Green

    # -------------------------------------------------
    # Throttle
    # -------------------------------------------------
    Start-Sleep -Seconds 60
}

Write-Host "`n=== INGEST COMPLETE ===" -ForegroundColor Cyan
