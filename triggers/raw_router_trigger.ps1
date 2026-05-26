# =========================================================
# MiraTV RAW ROUTER TRIGGER
# LOCATION: triggers/raw_router_trigger.ps1
# =========================================================

$Worker = "C:\miratv_ingest\workers\raw_router_worker.ps1"

Write-Host "[ROUTER] Trigger started"

powershell `
  -ExecutionPolicy Bypass `
  -NoProfile `
  -File $Worker

if ($LASTEXITCODE -ne 0) {
    Write-Error "[ROUTER] Worker returned non-zero exit"
    exit 1
}

Write-Host "[ROUTER] Trigger complete"
exit 0
