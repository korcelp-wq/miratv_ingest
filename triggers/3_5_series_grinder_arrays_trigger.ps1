Write-Host "========================================="
Write-Host "MiraTV ARRAY GRINDER TRIGGER (3.5)"
Write-Host "========================================="

$PickupArrays = "C:\miratv_ingest\raw_store\pickup\arrays"
$Normalized   = "C:\miratv_ingest\raw_store\normalized"
$SeriesSep    = "C:\miratv_ingest\series_sep"

$Normalizer = "C:\miratv_ingest\workers\raw_local_normalizer.ps1"
$Grinder    = "C:\miratv_ingest\workers\series_grinder_arrays.ps1"

$ErrorActionPreference = "Stop"

# Ensure directories exist
foreach ($dir in @($Normalized, $SeriesSep)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
}

Get-ChildItem -Path $PickupArrays -Filter "*.raw.json" -File | ForEach-Object {

    $rawFile  = $_.FullName
    $fileName = $_.Name
    $normFile = Join-Path $Normalized $fileName

    Write-Host "▶ ARRAY GRINDER processing $fileName"

    try {
        # -----------------------------------------
        # STEP 1: TEXT-ONLY NORMALIZATION
        # -----------------------------------------
        & powershell.exe `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $Normalizer `
            -InputFile $rawFile `
            -OutputFile $normFile

        # -----------------------------------------
        # STEP 2: ARRAY GRINDER (STRUCTURAL PARSE)
        # -----------------------------------------
        & powershell.exe `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $Grinder `
            -InputFile $normFile `
            

        Write-Host "✔ ARRAY SUCCESS $fileName"

        Remove-Item $rawFile -Force
        Remove-Item $normFile -Force
    }
    catch {
        Write-Error "✖ ARRAY FAILED $fileName :: $($_.Exception.Message)"
    }
}

Write-Host "✅ ARRAY GRINDER TRIGGER COMPLETE"
