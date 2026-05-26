# =========================================================
# MiraTV — XMLTV → JSON EPG Normalizer
# =========================================================
# Input : XMLTV file (epg.xml)
# Output: JSON file (epg_latest.json)
#
# Maps:
#   programme/@channel  → channel_id (string)
#   title               → title
#   desc                → description
#   start/stop          → start/end (Y-m-d H:i:s)
# =========================================================

param (
    [string]$InputXml  = "C:\miratv_ingest\raw\epg.xml",
    [string]$OutputJson = "C:\miratv_ingest\raw\epg_latest.json"
)

Write-Host "Loading XMLTV EPG..." -ForegroundColor Cyan

[xml]$xml = Get-Content $InputXml

$epgList = @()

foreach ($p in $xml.tv.programme) {

    # Convert XMLTV timestamps: YYYYMMDDHHMMSS +0000
    $start = [datetime]::ParseExact(
        $p.start.Substring(0,14),
        "yyyyMMddHHmmss",
        $null
    ).ToString("yyyy-MM-dd HH:mm:ss")

    $end = [datetime]::ParseExact(
        $p.stop.Substring(0,14),
        "yyyyMMddHHmmss",
        $null
    ).ToString("yyyy-MM-dd HH:mm:ss")

    $epgList += [pscustomobject]@{
        channel_id  = $p.channel
        title       = $p.title.'#text'
        description = $p.desc.'#text'
        start       = $start
        end         = $end
    }
}

Write-Host "Parsed $($epgList.Count) EPG entries" -ForegroundColor Green

# Wrap in container expected by PHP
$result = @{
    epg_listings = $epgList
}

$result | ConvertTo-Json -Depth 5 | Set-Content $OutputJson -Encoding UTF8

Write-Host "EPG JSON written to:" -ForegroundColor Cyan
Write-Host $OutputJson
