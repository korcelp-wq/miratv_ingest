# =========================================================
# MiraTV — STEP 6 FINAL CLEANER (FILESYSTEM ONLY)
# =========================================================

$ErrorActionPreference = "Stop"

$pickupRoots = @(
    "C:\miratv_ingest\raw_store\pickup\default",
    "C:\miratv_ingest\raw_store\pickup\arrays",
    "C:\miratv_ingest\raw_store\pickup\quarantine"
)

Write-Host "🧹 STEP 6 — Cleaning processed series files"

$seriesIds = New-Object System.Collections.Generic.HashSet[int]

foreach ($dir in $pickupRoots) {
    if (-not (Test-Path $dir)) { continue }

    Get-ChildItem $dir -Filter "series_*.raw.json" -File | ForEach-Object {
        if ($_.Name -match '^series_(\d+)\.raw\.json$') {
            [void]$seriesIds.Add([int]$matches[1])
        }
    }
}

if ($seriesIds.Count -eq 0) {
    Write-Host "↪ No series files found — nothing to clean"
    exit 0
}

foreach ($seriesId in $seriesIds) {

    Write-Host "🧹 Removing raw artifacts for series_id=$seriesId"

    $filename = "series_${seriesId}.raw.json"

    $paths = @(
        "C:\miratv_ingest\raw_store\pickup\default\$filename",
        "C:\miratv_ingest\raw_store\pickup\arrays\$filename",
        "C:\miratv_ingest\raw_store\pickup\quarantine\$filename",
        "C:\miratv_ingest\raw_store\$filename",
        "C:\miratv_ingest\raw_store\series_${seriesId}.newman.json",
        "C:\miratv_ingest\series_sep\$filename"
    )

    foreach ($path in $paths) {
        if (Test-Path $path) {
            Remove-Item $path -Force
            Write-Host "✔ Removed: $path"
        }
    }
}

Write-Host "✅ STEP 6 complete — filesystem clean"
exit 0
