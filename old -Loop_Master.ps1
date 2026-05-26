# ============================================
# MiraTV — Series Runner Loop (3-Minute Tick)
# ============================================

$ErrorActionPreference = "Stop"

$MASTER_BAT = "C:\miratv_ingest\master_series_runner.bat"
$SLEEP_SEC = 180   # 3 minutes

Write-Host "========================================="
Write-Host "MiraTV SERIES LOOP STARTED"
Write-Host "Tick interval: $SLEEP_SEC seconds"
Write-Host "========================================="

while ($true) {
    $start = Get-Date
    Write-Host ""
    Write-Host "▶ Tick start: $start"

    try {
        cmd /c "`"$MASTER_BAT`""
        Write-Host "✔ Runner completed"
    }
    catch {
        Write-Host "✖ Runner error: $($_.Exception.Message)"
    }

    $elapsed = (Get-Date) - $start
    Write-Host "⏱ Tick duration: $($elapsed.TotalSeconds)s"

    Write-Host "⏸ Sleeping $SLEEP_SEC seconds..."
    Start-Sleep -Seconds $SLEEP_SEC
}
