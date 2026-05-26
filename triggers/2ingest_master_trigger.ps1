$RawStore = "C:\miratv_ingest\raw_store\pickup\default"
$SeriesSep = "C:\miratv_ingest\series_sep"
$Archive   = "C:\miratv_ingest\archive"
$Failed    = "C:\miratv_ingest\failed"

$Grinder   = "C:\miratv_ingest\workers\series_grinder.ps1"

$ErrorActionPreference = "Stop"

foreach ($dir in @($RawStore, $SeriesSep, $Archive, $Failed)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
}

Get-ChildItem -Path $RawStore -Filter "*.raw.json" -File | ForEach-Object {

    $rawFile = $_.FullName
    $file    = $_.Name

    Write-Host "▶ Processing $file"

    try {
        & powershell.exe `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $Grinder `
            -InputFile $rawFile `
            -OutputRoot $SeriesSep

        Move-Item -Path $rawFile -Destination $Archive -Force
        Write-Host "✔ SUCCESS $file"
        Write-Host "Season matches: $([regex]::Matches($raw, $seasonPattern).Count)"
        Write-Host "Episode matches: $([regex]::Matches($raw, $episodePattern).Count)"

    }
    catch {
        $reason = $_.Exception.Message
        Move-Item -Path $rawFile -Destination $Failed -Force
        Write-Error "✖ FAILED $file :: $reason"
    }
}
