$File  = "C:\miratv_ingest\export\epg.xml"
$Url   = "https://miratv.club/_ingest/upload_epg_chunk.php"
$Token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"

$ChunkSize = 1MB
$tempChunk = "C:\miratv_ingest\call\chunk.tmp"
$buffer = New-Object byte[] $ChunkSize

$fs = [System.IO.File]::OpenRead($File)

try {
    $chunk = 0

    while (($read = $fs.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $bytes = New-Object byte[] $read
        [Array]::Copy($buffer, $bytes, $read)

        $first = if ($chunk -eq 0) { "1" } else { "0" }
        $last  = if ($fs.Position -eq $fs.Length) { "1" } else { "0" }

        $sendUrl = "{0}?chunk={1}&first={2}&last={3}" -f $Url, $chunk, $first, $last

        Write-Host "Uploading chunk=$chunk bytes=$read first=$first last=$last"

        [System.IO.File]::WriteAllBytes($tempChunk, $bytes)

        & curl.exe -sS --fail --max-time 60 `
          -X POST `
          -H "X-Ingest-Token: $Token" `
          -H "Content-Type: application/octet-stream" `
          --data-binary "@$tempChunk" `
          "$sendUrl"

        if ($LASTEXITCODE -ne 0) {
            throw "curl failed on chunk $chunk"
        }

        $chunk++
    }

    Write-Host "UPLOAD COMPLETE chunks=$chunk"
}
finally {
    $fs.Close()

    if (Test-Path $tempChunk) {
        Remove-Item $tempChunk -Force
    }
}