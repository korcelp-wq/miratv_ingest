Write-Host "========================================="
Write-Host "MiraTV Pipeline Runner"
Write-Host "========================================="

while ($true) {

    Write-Host "Tick: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

    & "C:\miratv_ingest\triggers\raw_ingest_trigger.ps1"
    & "C:\miratv_ingest\triggers\normalize_trigger.ps1"
    & "C:\miratv_ingest\triggers\episode_resolver_trigger.ps1"

    Write-Host "Cycle complete” sleeping 30s
    Start-Sleep -Seconds 60
}
