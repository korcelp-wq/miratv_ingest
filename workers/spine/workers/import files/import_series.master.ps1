param (
    [Parameter(Mandatory)]
    [string]$Environment,

    [ValidateSet("debug","quiet")]
    [string]$Mode = "debug"
)

# ------------------ CONFIG ------------------
$DebugMode = ($Mode -eq "debug")

$BaseUrl = "https://miratv.club"
$Token   = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"

# ------------------ HELPERS ------------------
function Log {
    param([string]$Msg)
    if ($DebugMode) {
        Write-Host "[DEBUG] $Msg"
    }
}

function Die {
    param([string]$Msg)
    Write-Host "[FATAL] $Msg"
    exit 1
}

# ------------------ MAIN LOOP ------------------
Log "Import series master started (env=$Environment)"

while ($true) {

    Log "Requesting next series..."

    try {
        $resp = Invoke-RestMethod `
            -Method Get `
            -Uri "$BaseUrl/_workers/series_pipeline.php" `
            -Headers @{ "X-Ingest-Token" = $Token } `
            -TimeoutSec 15
    }
    catch {
        Die "Failed to reach series_pipeline.php.php"
    }

    if ($resp.busy) {
        Log "Pipeline busy — exiting cleanly"
        break
    }

    if ($resp.done) {
        Log "No more series to process — done"
        break
    }

    if (-not $resp.ok) {
        Die "Unexpected response from get_next_series"
    }

    $seriesId = $resp.series_id
    $provider = $resp.provider_series_id
    $lockName = $resp.lock

    Log "Selected series_id=$seriesId provider_id=$provider lock=$lockName"

    # --------------------------------------------------
    # PHASE: SERIES INFO
    # --------------------------------------------------
    Log "Running series info import"

    & newman run `
        "C:\MiraTV\postman\sCollection.postman_collection.json" `
        --folder "get_series_info" `
        --env-var "series_id=$seriesId" `
        --env-var "env=$Environment"

    if ($LASTEXITCODE -ne 0) {
        Die "Series info import failed for series_id=$seriesId"
    }

    # --------------------------------------------------
    # FUTURE PHASES (INTENTIONALLY COMMENTED)
    # --------------------------------------------------
    # Log "Running seasons import"
    # Log "Running episodes import"
    # Log "Marking series complete"

    Log "Series $seriesId processed successfully (MVP phase)"

    # MVP behavior: process ONE series, then stop
    Log "MVP mode — stopping after one series"
    break
}

Log "Master runner finished"
