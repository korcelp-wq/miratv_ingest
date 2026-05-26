Write-Host "========================================="
Write-Host "MiraTV RAW LOCAL PARSE TRIGGER (2.2)"
Write-Host "========================================="

$ErrorActionPreference = "Stop"

$RawStore   = "C:\miratv_ingest\raw_store"
$ParsedDir  = Join-Path $RawStore "parsed"
$Parser     = "C:\miratv_ingest\workers\raw_local_parser.ps1"

# Ensure directories
foreach ($d in @($ParsedDir)) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }
}

$files = Get-ChildItem -Path $RawStore -Filter "*.raw.json" -File

if (-not $files) {
    Write-Host "🟡 No raw files to parse"
    exit 0
}

foreach ($f in $files) {
    Write-Host "▶ Parsing $($f.Name)"

    $outFile = Join-Path $ParsedDir $f.Name

    try {
        powershell `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $Parser `
            -InputFile $f.FullName `
            -OutputFile $outFile

        Write-Host "✔ Parsed → $outFile"
    }
    catch {
        Write-Error "✖ Parse failed: $($f.Name)"
    }
}

Write-Host "✅ RAW LOCAL PARSE TRIGGER COMPLETE"
exit 0
