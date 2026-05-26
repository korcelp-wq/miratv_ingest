# =========================================================
# MiraTV – Series Pipeline Trigger
# =========================================================
# Runs:
# 1) series grinder
# 2) series sender (uploads JSON to workers)
# =========================================================

$ErrorActionPreference = "Stop"

Write-Host "=== SERIES PIPELINE START ==="

# --- Paths ---
#$Grinder = "C:\miratv_ingest\workers\series_grinder.ps1"
$Sender  = "C:\miratv_ingest\workers\2send_series_to_workers.ps1"

# --- Sanity checks ---
#if (!(Test-Path $Grinder)) {
 #   throw "Missing grinder: $Grinder"
#}
if (!(Test-Path $Sender)) {
    throw "Missing sender: $Sender"
}

# --- Step 1: Grinder ---
#Write-Host "→ Running series grinder"
#powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Grinder

#Write-Host "✔ Grinder complete"

# --- Step 2: Sender ---
Write-Host "→ Sending series artifacts to workers"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Sender

Write-Host "✔ Sender complete"

Write-Host "=== SERIES PIPELINE END ==="
