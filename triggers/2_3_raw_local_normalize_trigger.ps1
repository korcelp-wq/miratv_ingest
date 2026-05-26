Write-Host "========================================="
Write-Host "MiraTV RAW LOCAL NORMALIZE TRIGGER (2.3)"
Write-Host "========================================="

$ErrorActionPreference = "Stop"

$RawStore    = "C:\miratv_ingest\raw_store"
$ParsedDir   = Join-Path $RawStore "parsed"
$Normalized  = Join-Path $RawStore "normalized"
$Normalizer  = "C:\miratv_ingest\workers\raw_local_normalizer.ps1"

# Ensure directories
foreach ($d in @($ParsedDir, $Normalized)) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }
}

$files = Get-ChildItem -Path $ParsedDir -Filter "*.raw.json" -File

if (-not $files) {
    Write-Host "🟡 No parsed files to normalize"
    exit 0
}

foreach ($f in $files) {
    Write-Host "▶ Normalizing $($f.Name)"

    $outFile = Join-Path $Normalized $f.Name

    try {
        powershell `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $Normalizer `
            -InputFile $f.FullName `
            -OutputFile $outFile

        Write-Host "✔ Normalized → $outFile"
    }
    catch {
        Write-Error "✖ Normalize failed: $($f.Name)"
    }
}

Write-Host "✅ RAW LOCAL NORMALIZE TRIGGER COMPLETE"
exit 0
