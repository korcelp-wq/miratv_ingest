$token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$baseUrl = "https://miratv.club/_ingest/import_epg.php"

$limit = 100
$offset = 0
$done = $false

while (-not $done) {

    $url = "$baseUrl?offset=$offset&limit=$limit"

    Write-Host "`nCalling offset=$offset limit=$limit"

    try {
        $response = curl.exe -s -X POST $url `
            -H "X-Ingest-Token: $token"
    } catch {
        Write-Host "Request failed — retrying..."
        Start-Sleep -Seconds 5
        continue
    }

    if (-not $response) {
        Write-Host "Empty response — retrying..."
        Start-Sleep -Seconds 5
        continue
    }

    Write-Host $response

    try {
        $json = $response | ConvertFrom-Json
    } catch {
        Write-Host "Bad JSON — retrying..."
        Start-Sleep -Seconds 5
        continue
    }

    $offset = [int]$json.next_offset
    $done = [bool]$json.done

    # 🔥 CRITICAL: wait BEFORE next call
    Start-Sleep -Seconds 2
}

Write-Host "`nEPG import complete."