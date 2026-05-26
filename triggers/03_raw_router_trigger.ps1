Write-Host "[03] RAW ROUTER TRIGGER"

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Worker = "C:\miratv_ingest\workers\raw_router_worker.ps1"

& powershell -NoProfile -ExecutionPolicy Bypass -File $Worker
if ($LASTEXITCODE -ne 0) {
    Write-Error "[03] RAW ROUTER FAILED"
    exit 1
}

Write-Host "[03] RAW ROUTER COMPLETE"
exit 0
