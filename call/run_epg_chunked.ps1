$token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$baseUrl = "https://miratv.club/_ingest/import_epg.php"

$limit = 100
$offset = 0
$done = $false

while (-not $done) {

    $url = "$baseUrl?offset=$offset&limit=$limit"

    Write-Host "Calling offset=$offset limit=$limit"

    $response = curl.exe -s -X POST $url `
        -H "X-Ingest-Token: $token"

    Write-Host $response

    try {
        $json = $response | ConvertFrom-Json
    } catch {
        Write-Host "Failed to parse response — stopping"
        break
    }

    $offset = [int]$json.next_offset
    $done = [bool]$json.done

    Start-Sleep -Milliseconds 1000
}

Write-Host "EPG import complete."