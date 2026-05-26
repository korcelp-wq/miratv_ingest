$ErrorActionPreference = "Stop"

if (-not $env:MIRATV_SERIES_ID) {
  Write-Error "MIRATV_SERIES_ID env var not set"
  exit 1
}

$seriesId = [int]$env:MIRATV_SERIES_ID
Write-Host "[00] ONE-OFF series_id=$seriesId"

# Now call the *existing* step-01 worker, but inject the id
# Example: if your existing worker is the "Series Details Worker" script:
pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\miratv_ingest\workers\series_details_worker.ps1" -SeriesId $seriesId
exit $LASTEXITCODE