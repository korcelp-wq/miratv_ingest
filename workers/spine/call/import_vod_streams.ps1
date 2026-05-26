# MiraTV VOD Streams Importer - Chunked Upload
# Reads C:\miratv_ingest\raw\vod.steam.raw.json
# Uploads to https://miratv.club/_ingest/import_vod_streams.php in chunks to avoid request timeout.

$ErrorActionPreference = "Stop"

$SourceFile = "C:\miratv_ingest\raw\vod.steam.raw.json"
$ChunkDir = "C:\miratv_ingest\raw\vod_chunks"
$Endpoint = "https://miratv.club/_ingest/import_vod_streams.php"
$Token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"

$ChunkSize = 500

Write-Host "========================================="
Write-Host "MiraTV VOD Streams Importer - Chunked"
Write-Host "========================================="

if (-not (Test-Path $SourceFile)) {
    Write-Error "Source file not found: $SourceFile"
    exit 1
}

if (Test-Path $ChunkDir) {
    Remove-Item $ChunkDir -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $ChunkDir | Out-Null

Write-Host "Reading source file:"
Write-Host $SourceFile

$parsed = Get-Content $SourceFile -Raw | ConvertFrom-Json

$items = @()
foreach ($item in $parsed) {
    $items += $item
}

if ($items.Count -le 0) {
    Write-Error "No VOD items found in source file"
    exit 1
}

Write-Host "Total VOD items:"
Write-Host $items.Count

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$chunkFiles = New-Object System.Collections.Generic.List[string]

for ($i = 0; $i -lt $items.Count; $i += $ChunkSize) {
    $end = [Math]::Min($i + $ChunkSize - 1, $items.Count - 1)
    $chunk = $items[$i..$end]

    $chunkIndex = [int]($i / $ChunkSize)
    $chunkFile = Join-Path $ChunkDir ("vod_streams_chunk_{0:D5}.json" -f $chunkIndex)

    $json = ConvertTo-Json -InputObject $chunk -Depth 100 -Compress
    [System.IO.File]::WriteAllText($chunkFile, $json, $utf8NoBom)

    $chunkFiles.Add($chunkFile) | Out-Null
}

Write-Host "Chunk files created:"
Write-Host $chunkFiles.Count

$totalInserted = 0
$totalUpdated = 0
$totalSkipped = 0
$totalProcessed = 0
$failed = 0

foreach ($file in $chunkFiles) {
    $name = Split-Path $file -Leaf

    Write-Host ""
    Write-Host "Uploading $name..."

    $rawResponse = & curl.exe -s -X POST $Endpoint `
        -H "X-Ingest-Token: $Token" `
        -H "Content-Type: application/json" `
        --data-binary "@$file"

    $response = ($rawResponse | Out-String).Trim()
    Write-Host $response

    try {
        $jsonStart = $response.IndexOf("{")
        $jsonEnd = $response.LastIndexOf("}")

        if ($jsonStart -lt 0 -or $jsonEnd -lt $jsonStart) {
            throw "No JSON object found in response"
        }

        $jsonText = $response.Substring($jsonStart, $jsonEnd - $jsonStart + 1)
        $jsonResponse = $jsonText | ConvertFrom-Json

        if ($jsonResponse.ok -ne $true) {
            $failed = $failed + 1
            Write-Host "[FAILED] $name returned ok=false" -ForegroundColor Red
            continue
        }

        if ($null -ne $jsonResponse.inserted) {
            $totalInserted = $totalInserted + [int]$jsonResponse.inserted
        }

        if ($null -ne $jsonResponse.updated) {
            $totalUpdated = $totalUpdated + [int]$jsonResponse.updated
        }

        if ($null -ne $jsonResponse.skipped) {
            $totalSkipped = $totalSkipped + [int]$jsonResponse.skipped
        }

        if ($null -ne $jsonResponse.total) {
            $totalProcessed = $totalProcessed + [int]$jsonResponse.total
        }
    } catch {
        $failed = $failed + 1
        Write-Host "[FAILED] Could not parse response for $name" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
    }

    Start-Sleep -Milliseconds 250
}

Write-Host ""
Write-Host "========================================="
Write-Host "VOD Chunked Import Complete"
Write-Host "========================================="
Write-Host "Chunks:    $($chunkFiles.Count)"
Write-Host "Failed:    $failed"
Write-Host "Inserted:  $totalInserted"
Write-Host "Updated:   $totalUpdated"
Write-Host "Skipped:   $totalSkipped"
Write-Host "Total:     $totalProcessed"

if ($failed -gt 0) {
    exit 1
}

exit 0