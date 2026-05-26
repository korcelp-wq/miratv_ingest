Write-Host "[02] SERIES ARRAY GRINDER TRIGGER"

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Normalizer = "C:\miratv_ingest\workers\raw_local_normalizer.ps1"
$Grinder    = "C:\miratv_ingest\workers\series_grinder_arrays.ps1"

$Pickup = "C:\miratv_ingest\raw_store\pickup\arrays"
$Norm   = "C:\miratv_ingest\raw_store\normalized"

if (-not (Test-Path $Pickup)) {
    Write-Host "[02] No array pickup directory – nothing to do"
    exit 0
}

Get-ChildItem $Pickup -Filter "*.raw.json" | ForEach-Object {

    Write-Host "[02] Processing $($_.Name)"

    & powershell -NoProfile -ExecutionPolicy Bypass -File $Normalizer -InputFile $_.FullName -OutputFile "$Norm\$($_.Name)"
    if ($LASTEXITCODE -ne 0) { continue }

    & powershell -NoProfile -ExecutionPolicy Bypass -File $Grinder -InputFile "$Norm\$($_.Name)"
}

Write-Host "[02] ARRAY GRINDER COMPLETE"
exit 0
