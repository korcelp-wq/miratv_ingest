# =========================================================
# MiraTV – Send Series Grinder Output to PHP Workers
# =========================================================

$ErrorActionPreference = "Stop"

# --- Paths ---
$Sep = "C:\miratv_ingest\series_sep"

# --- Endpoint base ---
$BaseUrl = "https://miratv.club/_workers"
$Token   = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"

# --- Worker map ---
$Map = @{
    "_series_ext.json"      = "import_series_ext.php"
    "_seasons.json"         = "import_series_seasons.php"
    "_season_ext.json"      = "import_series_seasons_ext.php"
    "_episodes.json"        = "import_series_episodes.php"
    "_series.json"          = "import_series.php"
}


Get-ChildItem $Sep -Filter "*.json" | ForEach-Object {

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
    $response = Invoke-RestMethod `
        -Uri $url `
        -Method Post `
        -ContentType "application/json" `
        -InFile $file.FullName `
        -ErrorAction Stop

    Write-Host "✔ Sent $name"
    Write-Host "↳ Response:" ($response | ConvertTo-Json -Depth 5)
}
catch {
    Write-Host "✖ HTTP FAILURE"

    if ($_.Exception.Response) {
        Write-Host "StatusCode:" $_.Exception.Response.StatusCode.value__
        Write-Host "StatusDesc:" $_.Exception.Response.StatusDescription

        $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        $body = $reader.ReadToEnd()
        Write-Host "ResponseBody:`n$body"
    }

    throw
}

}
