Write-Host "========================================="
Write-Host "MiraTV Series Materialization Trigger"
Write-Host "========================================="

# MUST come from master

Write-Host "Triggering series_id for materialization"

& "C:\miratv_ingest\workers\materialize_series_worker.ps1"

if ($LASTEXITCODE -ne 0) {
    Write-Error "STEP 9 FAILED"
    exit 2
}

Write-Host "✔ STEP 9 COMPLETE"
exit 0


