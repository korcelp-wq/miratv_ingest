$RawStore  = "C:\miratv_ingest\raw_store"
$Processed = "C:\miratv_ingest\processed"
$Archive   = "C:\miratv_ingest\archive"
$Failed    = "C:\miratv_ingest\failed"

$Grinder   = "C:\miratv_ingest\scripts\series_grinder.ps1"

$ErrorActionPreference = "Stop"

foreach ($dir in @($RawStore, $Processed, $Archive, $Failed)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
}

Get-ChildItem $RawStore -Filter "*.trigger" | ForEach-Object {

    $trigger = $_.FullName
    $base    = $_.BaseName
    $rawFile = Join-Path $RawStore "$base.raw"

    Write-Host "▶ Processing $base"

    if (-not (Test-Path $rawFile)) {
        Write-Error "Missing raw file for $base"
        Move-Item $trigger $Failed -Force
        return
    }

    try {
        & $Grinder -InputFile $rawFile

        Move-Item $rawFile  $Archive -Force
        Move-Item $trigger  $Archive -Force

        Write-Host "✔ SUCCESS $base"
    }
    catch {
        Move-Item $rawFile  $Failed -Force
        Move-Item $trigger  $Failed -Force

        Write-Error "✖ FAILED $base"
    }
}
