# MiraTV Live Category Index Worker (RAW INGEST - DIRECT STREAM)

$ErrorActionPreference = "Stop"

Write-Host "=============================="
Write-Host "MiraTV Live Category Index Worker"
Write-Host "=============================="

# TLS
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Config
$ROOT = "C:\miratv_ingest"
$RAW_DIR = "$ROOT\raw"

# IMPORTANT:
# stream_live_cat_trigger.bat expects this exact filename:
# C:\miratv_ingest\raw\live.category.index.raw.json
$OUTPUT = "$RAW_DIR\live.category.index.raw.json"

$URL = "http://uxurwymd.silvervpn.net:8080/player_api.php?username=Marina2025&password=3KY586YR&action=get_live_categories"

# Ensure dir
if (-not (Test-Path $RAW_DIR)) {
    New-Item -ItemType Directory -Path $RAW_DIR | Out-Null
}

Write-Host "Downloading live category index (streaming)..."

# Stream directly to file
Invoke-WebRequest `
    -Uri $URL `
    -Method GET `
    -OutFile $OUTPUT `
    -TimeoutSec 300 `
    -Headers @{ "User-Agent" = "MiraTV-Ingest" }

# Validate file exists
if (-not (Test-Path $OUTPUT)) {
    Write-Error "Output file not created: $OUTPUT"
    exit 1
}

$bytes = (Get-Item $OUTPUT).Length

# Live category files can be small. Only reject truly empty/truncated files.
if ($bytes -lt 100) {
    Write-Error "Output file unexpectedly small ($bytes bytes): $OUTPUT"
    exit 1
}

# Validate JSON shape
try {
    $raw = Get-Content $OUTPUT -Raw
    $json = $raw | ConvertFrom-Json

    if ($null -eq $json) {
        Write-Error "Downloaded live category file parsed to null"
        exit 1
    }

    if ($json -isnot [System.Array] -and $json.PSObject.Properties.Name -notcontains "category_id") {
        # This still allows provider responses that are arrays.
        # If it is not an array and does not look like a category object, fail loudly.
        Write-Error "Downloaded live category file does not look like a category JSON payload"
        exit 1
    }
} catch {
    Write-Error "Downloaded live category file is not valid JSON: $($_.Exception.Message)"
    exit 1
}

Write-Host "Live category index captured successfully"
Write-Host "Bytes:"
Write-Host $bytes
Write-Host "Output file:"
Write-Host $OUTPUT

exit 0