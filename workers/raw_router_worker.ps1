# =========================================================
# MiraTV RAW ROUTER WORKER
# =========================================================
# PURPOSE:
# - TEMP MODE: Route ALL raw payloads to default
# - Preserve router structure for later re-enable
# - NEVER parse JSON
# - NEVER block pipeline
#
# NOTE:
# - Shape detection intentionally disabled
# - This is a safe staging posture
# =========================================================

Write-Host "🔀 RAW ROUTER WORKER STARTED (DEFAULT-ONLY MODE)"

$ErrorActionPreference = "Continue"

# ---------------------------------------------------------
# PATHS (CANONICAL)
# ---------------------------------------------------------
$RawStore = "C:\miratv_ingest\raw_store"
$Pickup   = Join-Path $RawStore "pickup"

$Dirs = @{
    default = Join-Path $Pickup "default"
}

# ---------------------------------------------------------
# ENSURE DIRECTORY EXISTS
# ---------------------------------------------------------
if (-not (Test-Path $Dirs.default)) {
    New-Item -ItemType Directory -Force -Path $Dirs.default | Out-Null
}

# ---------------------------------------------------------
# FETCH RAW FILES
# ---------------------------------------------------------
$files = Get-ChildItem -Path $RawStore -Filter "*.raw.json" -File

if (-not $files -or $files.Count -eq 0) {
    Write-Host "🟡 No raw files to route"
    exit 0
}

foreach ($f in $files) {

    Write-Host "📄 Routing $($f.Name)"
    Write-Host "   → default (router_passthrough)"

    try {
        Move-Item -Path $f.FullName -Destination $Dirs.default -Force
    }
    catch {
        Write-Host "   ⚠️ Failed to move file — leaving in place"
        continue
    }
}

Write-Host "✅ RAW ROUTER WORKER COMPLETE (DEFAULT-ONLY MODE)"
exit 0
