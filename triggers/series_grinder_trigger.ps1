Write-Host "========================================="
Write-Host "MiraTV Series Grinder Trigger"
Write-Host "========================================="

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "C:\miratv_ingest\workers\series_grinder.ps1"

Write-Host "========================================="
Write-Host "Series Grinder Trigger COMPLETE"
Write-Host "========================================="