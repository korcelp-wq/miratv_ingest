# C:\miratv_ingest\dashboard\Launch-Dashboard.ps1
Write-Host "Launching MiraTV Master Control Dashboard..." -ForegroundColor Cyan
Start-Process "file:///C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe" -ArgumentList "--app=file:///C:/miratv_ingest/dashboard/index.html"
# Or for default browser:
# Start-Process "file:///C:/miratv_ingest/dashboard/index.html"