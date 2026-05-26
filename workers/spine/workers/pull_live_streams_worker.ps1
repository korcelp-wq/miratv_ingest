# MiraTV Live Streams Index Worker (RAW INGEST - DIRECT STREAM)

$ErrorActionPreference = "Stop"

Write-Host "=============================="
Write-Host "MiraTV Live Streams Index Worker"
Write-Host "=============================="

# TLS
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Config
$ROOT = "C:\miratv_ingest"
$RAW_DIR = "$ROOT\raw"
$OUTPUT = "$RAW_DIR\live.streams.index.raw.json"

$URL = "http://uxurwymd.silvervpn.net:8080/player_api.php?username=Marina2025&password=3KY586YR&action=get_live_streams"

# Ensure dir
if (-not (Test-Path $RAW_DIR)) {
    New-Item -ItemType Directory -Path $RAW_DIR | Out-Null
}

Write-Host "Downloading live streams index (streaming)..."

# Stream directly to file (no buffering, no stringify)
Invoke-WebRequest `
    -Uri $URL `
    -Method GET `
    -OutFile $OUTPUT `
    -TimeoutSec 300 `
    -Headers @{ "User-Agent" = "MiraTV-Ingest" }

# Validate
if (-not (Test-Path $OUTPUT)) {
    Write-Error "Output file not created"
    exit 1
}

$bytes = (Get-Item $OUTPUT).Length
if ($bytes -lt 1000000) {
    Write-Error "Output file unexpectedly small ($bytes bytes)"
    exit 1
}

Write-Host "Series index captured successfully"
Write-Host "Bytes:"
Write-Host $bytes
Write-Host "Output file:"
Write-Host $OUTPUT

exit 0

