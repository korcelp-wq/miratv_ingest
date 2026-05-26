param(
    [int]$MacUserId = 2,

    [string]$Provider = "megaott",

    [string]$ProviderBaseUrl = "http://uxurwymd.silvervpn.net:8080",

    [Parameter(Mandatory = $true)]
    [string]$Username,

    [Parameter(Mandatory = $true)]
    [string]$Password,

    [string]$IngestUrl = "https://miratv.club/_workers/ai/api/ingest_live_availability.php",

    [string]$IngestToken = "",

    [int]$TimeoutSec = 180,

    [switch]$PostEvenIfEmpty
)

$ErrorActionPreference = "Stop"

function Convert-ToArray {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        return @($Value)
    }

    return @($Value)
}

function Invoke-XtreamRaw {
    param(
        [string]$Action
    )

    $base = $ProviderBaseUrl.TrimEnd("/")
    $url = "$base/player_api.php?username=$([uri]::EscapeDataString($Username))&password=$([uri]::EscapeDataString($Password))&action=$([uri]::EscapeDataString($Action))"

    Write-Host "Fetching provider action=$Action ..." -ForegroundColor Cyan

    $response = Invoke-WebRequest `
        -Uri $url `
        -Method GET `
        -TimeoutSec $TimeoutSec `
        -Headers @{
            "Accept" = "application/json"
            "User-Agent" = "VLC/3.0.20 LibVLC/3.0.20"
        }

    if (-not $response.Content) {
        throw "Provider returned empty HTTP body for action=$Action"
    }

    $preview = $response.Content
    if ($preview.Length -gt 500) {
        $preview = $preview.Substring(0, 500)
    }

    Write-Host "HTTP status for ${Action}: $($response.StatusCode)" -ForegroundColor DarkGray
    Write-Host "Raw preview for ${Action}: $preview" -ForegroundColor DarkGray

    try {
        $parsed = $response.Content | ConvertFrom-Json
    } catch {
        throw "Provider returned non-JSON for action=$Action. Preview: $preview"
    }

    return @{
        Raw = $response.Content
        Parsed = $parsed
        Preview = $preview
    }
}

function Assert-XtreamArray {
    param(
        [string]$Action,
        $Parsed
    )

    $arr = Convert-ToArray $Parsed

    if ($arr.Count -eq 1) {
        $first = $arr[0]

        if ($first -is [pscustomobject]) {
            $props = $first.PSObject.Properties.Name

            if ($props -contains "user_info" -or
                $props -contains "server_info" -or
                $props -contains "error" -or
                $props -contains "message") {
                $json = $first | ConvertTo-Json -Depth 8 -Compress
                throw "Provider did not return an array for action=$Action. It returned an object: $json"
            }
        }
    }

    return $arr
}

function Remove-InvalidUnicode {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    # Remove isolated UTF-16 surrogate characters before UTF-8 JSON POST.
    return [regex]::Replace($Value, '[\uD800-\uDFFF]', '')
}

function Sanitize-JsonValue {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string]) {
        return Remove-InvalidUnicode $Value
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $out[$key] = Sanitize-JsonValue $Value[$key]
        }
        return $out
    }

    if ($Value -is [System.Array]) {
        $items = @()
        foreach ($item in $Value) {
            $items += ,(Sanitize-JsonValue $item)
        }
        return $items
    }

    if ($Value -is [pscustomobject]) {
        $out = [ordered]@{}
        foreach ($prop in $Value.PSObject.Properties) {
            $out[$prop.Name] = Sanitize-JsonValue $prop.Value
        }
        return $out
    }

    return $Value
}

Write-Host "G-1C-2b Client Live Availability Sync v3 UTF-8 POST" -ForegroundColor Green
Write-Host "ProviderBaseUrl: $ProviderBaseUrl"
Write-Host "MacUserId: $MacUserId"
Write-Host "Provider: $Provider"
Write-Host ""

$categoriesResult = Invoke-XtreamRaw -Action "get_live_categories"
$streamsResult = Invoke-XtreamRaw -Action "get_live_streams"

$categories = Assert-XtreamArray -Action "get_live_categories" -Parsed $categoriesResult.Parsed
$streams = Assert-XtreamArray -Action "get_live_streams" -Parsed $streamsResult.Parsed

Write-Host "Categories from provider: $($categories.Count)" -ForegroundColor Green
Write-Host "Streams from provider: $($streams.Count)" -ForegroundColor Green

if (($categories.Count -eq 0 -or $streams.Count -eq 0) -and -not $PostEvenIfEmpty) {
    Write-Host ""
    Write-Host "STOPPED: provider returned zero categories or zero streams." -ForegroundColor Red
    Write-Host "Nothing was posted to MiraTV ingest endpoint." -ForegroundColor Yellow
    Write-Host "To force posting empty results anyway, rerun with -PostEvenIfEmpty." -ForegroundColor DarkYellow
    exit 2
}

$payload = [ordered]@{
    mac_user_id = $MacUserId
    provider = $Provider
    provider_base_url = $ProviderBaseUrl
    provider_username = $Username
    categories = $categories
    streams = $streams
}

Write-Host "Sanitizing provider JSON text..." -ForegroundColor Cyan
$sanitizedPayload = Sanitize-JsonValue $payload

$json = $sanitizedPayload | ConvertTo-Json -Depth 40 -Compress
$utf8Body = [System.Text.Encoding]::UTF8.GetBytes($json)

Write-Host "Payload JSON chars: $($json.Length)" -ForegroundColor DarkGray
Write-Host "Payload UTF-8 bytes: $($utf8Body.Length)" -ForegroundColor DarkGray

$headers = @{
    "Accept" = "application/json"
}

if ($IngestToken -ne "") {
    $headers["X-Ingest-Token"] = $IngestToken
}

Write-Host "Posting UTF-8 JSON to ingest endpoint..." -ForegroundColor Cyan
Write-Host $IngestUrl

$result = Invoke-WebRequest `
    -Uri $IngestUrl `
    -Method POST `
    -Headers $headers `
    -ContentType "application/json; charset=utf-8" `
    -Body $utf8Body `
    -TimeoutSec $TimeoutSec

Write-Host ""
Write-Host "Ingest response:" -ForegroundColor Green
$result.Content

$parsedResponse = $result.Content | ConvertFrom-Json

if (-not $parsedResponse.ok) {
    throw "Ingest endpoint returned ok=false: $($parsedResponse.error)"
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "category_count_received=$($parsedResponse.category_count_received)"
Write-Host "stream_count_received=$($parsedResponse.stream_count_received)"
Write-Host "matched_local_stream_count=$($parsedResponse.matched_local_stream_count)"
