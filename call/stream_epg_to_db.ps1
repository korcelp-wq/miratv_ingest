$File  = "C:\miraTV_ingest\export\epg.xml"
$Url   = "https://miratv.club/_ingest/import_epg_batch.php"
$Token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"

$Provider = "silvervpn"
$BatchSize = 1000

function Convert-EpgDate {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    # XMLTV format example: 20260427000000 +0000
    return $Value.Substring(0, [Math]::Min(14, $Value.Length))
}

function Send-Batch {
    param([array]$Batch)

    if ($Batch.Count -eq 0) {
        return
    }

    $payload = @{
        provider = $Provider
        programmes = $Batch
    } | ConvertTo-Json -Depth 5 -Compress

    $response = Invoke-RestMethod `
        -Uri $Url `
        -Method POST `
        -Headers @{ "X-Ingest-Token" = $Token } `
        -ContentType "application/json" `
        -Body $payload `
        -TimeoutSec 300

    Write-Host "Sent=$($Batch.Count) Processed=$($response.processed) Inserted=$($response.inserted) Skipped=$($response.skipped)"
}

$settings = New-Object System.Xml.XmlReaderSettings
$settings.IgnoreWhitespace = $true
$settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore

$reader = [System.Xml.XmlReader]::Create($File, $settings)

$batch = New-Object System.Collections.ArrayList
$total = 0

try {
    while ($reader.Read()) {
        if ($reader.NodeType -eq [System.Xml.XmlNodeType]::Element -and $reader.Name -eq "programme") {

            $channel = $reader.GetAttribute("channel")
            $start   = Convert-EpgDate $reader.GetAttribute("start")
            $end     = Convert-EpgDate $reader.GetAttribute("stop")

            $outer = $reader.ReadOuterXml()
            [xml]$node = $outer

            $title = ""
            $desc = ""

            if ($node.programme.title) {
                $title = [string]$node.programme.title[0].InnerText
            }

            if ($node.programme.desc) {
                $desc = [string]$node.programme.desc[0].InnerText
            }

            [void]$batch.Add(@{
                channel = $channel
                start_time = $start
                end_time = $end
                title = $title
                description = $desc
            })

            $total++

            if ($batch.Count -ge $BatchSize) {
                Send-Batch -Batch $batch
                $batch.Clear()
            }
        }
    }

    Send-Batch -Batch $batch
}
finally {
    $reader.Close()
}

Write-Host "DONE total programmes streamed=$total"