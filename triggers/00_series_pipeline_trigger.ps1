$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Write-Host "[00] SERIES PIPELINE TRIGGER START"

try {
    $response = Invoke-WebRequest `
        -Uri "https://miratv.club/_workers/series_pipeline.php" `
        -Headers @{ "X-INGEST-TOKEN" = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY" } `
        -UseBasicParsing `
        -TimeoutSec 60

    $json = $response.Content | ConvertFrom-Json

    Write-Host "[00] SERIES PIPELINE TRIGGER COMPLETE"
    Write-Output "SERIES_ID=$($json.series_id)"
}
catch {
    Write-Error "[00] SERIES PIPELINE TRIGGER FAILED: $($_.Exception.Message)"
    exit 1
}

exit 0

