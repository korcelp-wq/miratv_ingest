<#
=========================================================
 MiraTV – Legacy Series Grinder Trigger (FS-based)
 PURPOSE:
 - Run old forensic series grinder
 - Produce normalized FS outputs
 - Invoke parse_series_fs.php
 SAFE:
 - No DB access
 - No materializer
 - Test-run friendly
=========================================================
#>

$ErrorActionPreference = "Stop"

# -------------------------
# CONFIG
# -------------------------
$RAW_INPUT_DIR   = "C:\miratv_ingest\raw_store"
$NORMALIZED_DIR  = "C:\miratv_ingest\raw_store"

$SERIES_GRINDER  = "C:\miratv_ingest\workers\series_grinder.ps1"

$PARSE_FS_URL = "https://miratv.club/automated/parse_series_fs.php"
$INGEST_TOKEN = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"

# -------------------------
# SELECT ONE RAW FILE
# -------------------------
$rawFile = Get-ChildItem `
    -Path $RAW_INPUT_DIR `
    -Filter "series_*.raw.json" `
    | Sort-Object LastWriteTime `
    | Select-Object -First 1

if (-not $rawFile) {
    Write-Host "[INFO] No raw series files found."
    exit 0
}

Write-Host "[INFO] Processing $($rawFile.Name)"

# -------------------------
# ENSURE OUTPUT DIR
# -------------------------
if (-not (Test-Path $NORMALIZED_DIR)) {
    New-Item -ItemType Directory -Force -Path $NORMALIZED_DIR | Out-Null
}

# -------------------------
# RUN LEGACY SERIES GRINDER
# -------------------------
& $SERIES_GRINDER `
    -InputFile  $rawFile.FullName `
    -OutputRoot $NORMALIZED_DIR `
    -VerboseLog

Write-Host "[INFO] Grinder complete."

# -------------------------
# INVOKE LEGACY PHP FS PARSER
# -------------------------
Write-Host "[INFO] Invoking parse_series_fs.php"

Invoke-WebRequest `
    -Uri "$PARSE_FS_URL?token=$INGEST_TOKEN" `
    -UseBasicParsing `
    -Method GET `
    | Out-Null

Write-Host "[SUCCESS] Legacy series parse trigger complete."
