# =========================================================
# MiraTV – Send Series Grinder Output to PHP Workers
# =========================================================

$ErrorActionPreference = "Stop"

# --- Paths ---
$Processed = "C:\miratv_ingest\processed"

# --- Endpoint base ---
$BaseUrl = "https://YOURDOMAIN/_workers"
$Token   = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"

# --- Worker map ---
$Map = @{
    "_series_ext.json"      = "import_series_ext.php"
    "_seasons.json"         = "import_series_seasons.php"
    "_season_ext.json"      = "import_series_seasons_ext.php"
    "_episodes.json"        = "import_series_episodes.php"
}

if (-not (Test-Path $Processed)) {
    throw "Processed directory not found: $Processed"
}

Get-ChildItem $Processed -Filter "series_*.json" | ForEach-Object {

    $file = $_
    $name = $file.Name

    $worker = $null
    foreach ($suffix in $Map.Keys) {
        if ($name.EndsWith($suffix)) {
            $worker = $Map[$suffix]
            break
        }
    }

    if (-not $worker) {
        Write-Warning "Skipping unknown file type: $name"
        return
    }

    $url = "$BaseUrl/$worker?token=$Token"

    Write-Host "→ POST $name → $worker"

    try {
        Invoke-RestMethod `
            -Uri $url `
            -Method Post `
            -ContentType "application/json" `
            -InFile $file.FullName

        Write-Host "✔ Sent $name"
    }
    catch {
        Write-Error "✖ Failed sending $name"
        throw
    }
}
