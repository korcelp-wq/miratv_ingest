Write-Host "[07] MATERIALIZE SERIES TRIGGER"

& "C:\miratv_ingest\workers\materialize_series_worker.ps1"
if ($LASTEXITCODE -ne 0) {
    Write-Error "[07] MATERIALIZATION FAILED"
    exit 1
}

Write-Host "[07] MATERIALIZATION COMPLETE"
exit 0
