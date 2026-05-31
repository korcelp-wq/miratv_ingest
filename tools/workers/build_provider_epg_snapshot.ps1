[CmdletBinding()]
param(
    [string]$Provider = "default",
    [string]$InputXmlPath = "C:\miratv_ingest\export\epg.xml",
    [string]$Environment = "dev",
    [string]$DatabaseKey = "content",
    [string]$DeltaSince = "",
    [int]$MaxRows = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path ".").Path
$Stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$RunId = "epg-snapshot-$Stamp"

$OutDir = Join-Path $RepoRoot "runtime\provider_snapshots\epg"
$LogDir = Join-Path $RepoRoot "runtime\logs\provider_epg_snapshot"

New-Item -ItemType Directory -Force $OutDir | Out-Null
New-Item -ItemType Directory -Force $LogDir | Out-Null

$CsvPath = Join-Path $OutDir "provider_epg_snapshot_$Stamp.csv"
$JsonPath = Join-Path $OutDir "provider_epg_snapshot_$Stamp.json"
$SummaryPath = Join-Path $OutDir "provider_epg_snapshot_summary_$Stamp.json"
$LogPath = Join-Path $LogDir "build_provider_epg_snapshot-$((Get-Date).ToUniversalTime().ToString('yyyyMMdd')).jsonl"

function Write-Event {
    param([hashtable]$Event)

    $Event.run_id = $RunId
    $Event.worker_name = "build_provider_epg_snapshot"
    $Event.component = "provider_epg_snapshot"
    $Event.environment = $Environment
    $Event.timestamp = (Get-Date).ToUniversalTime().ToString("o")

    ($Event | ConvertTo-Json -Depth 8 -Compress) | Add-Content -Path $LogPath -Encoding UTF8
}

function Convert-XmlTvDate {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $core = $Value.Trim()
    if ($core.Length -lt 14) {
        return $null
    }

    $core = $core.Substring(0, 14)

    try {
        return [datetime]::ParseExact(
            $core,
            "yyyyMMddHHmmss",
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal
        )
    }
    catch {
        return $null
    }
}

function Get-StateDeltaDate {
    if (-not [string]::IsNullOrWhiteSpace($DeltaSince)) {
        return [datetime]::Parse($DeltaSince)
    }

    $modulePath = Join-Path $RepoRoot "tools\common\DbQuery.psm1"
    if (-not (Test-Path $modulePath)) {
        return $null
    }

    Import-Module $modulePath -Force

    $sql = "SELECT last_successful_epg_import_date FROM epg_import_state WHERE provider = ? LIMIT 1;"
    $result = Invoke-DogOpenProc -DatabaseKey $DatabaseKey -Sql $sql -Params @($Provider) -TimeoutSec 30

    if ($null -eq $result -or -not ($result.PSObject.Properties.Name -contains "rows")) {
        return $null
    }

    $rows = @($result.rows)
    if ($rows.Count -eq 0) {
        return $null
    }

    $value = [string]$rows[0].last_successful_epg_import_date
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    return [datetime]::Parse($value)
}

Write-Event @{
    event_type = "job_started"
    status = "started"
    source_name = $InputXmlPath
    provider = $Provider
}

if (-not (Test-Path $InputXmlPath)) {
    throw "EPG XML not found: $InputXmlPath"
}

$deltaDate = Get-StateDeltaDate
$rows = New-Object System.Collections.Generic.List[object]

$settings = New-Object System.Xml.XmlReaderSettings
$settings.IgnoreWhitespace = $true
$settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore

$reader = [System.Xml.XmlReader]::Create($InputXmlPath, $settings)

$totalSeen = 0
$totalIncluded = 0
$totalSkippedBeforeDelta = 0
$minStart = $null
$maxEnd = $null

try {
    while ($reader.Read()) {
        if ($reader.NodeType -ne [System.Xml.XmlNodeType]::Element -or $reader.Name -ne "programme") {
            continue
        }

        $totalSeen++

        $channel = [string]$reader.GetAttribute("channel")
        $startDt = Convert-XmlTvDate $reader.GetAttribute("start")
        $endDt = Convert-XmlTvDate $reader.GetAttribute("stop")

        if ($null -eq $startDt -or $null -eq $endDt) {
            continue
        }

        if ($null -ne $deltaDate -and $startDt -le $deltaDate) {
            $totalSkippedBeforeDelta++
            continue
        }

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

        $item = [pscustomobject][ordered]@{
            provider = $Provider
            epg_channel_id = $channel
            channel = $channel
            title = $title
            description = $desc
            start_time = $startDt.ToString("yyyy-MM-dd HH:mm:ss")
            end_time = $endDt.ToString("yyyy-MM-dd HH:mm:ss")
            catchup = 0
            provider_channel_id = 0
            canonical_channel = $channel
        }

        $rows.Add($item)
        $totalIncluded++

        if ($null -eq $minStart -or $startDt -lt $minStart) { $minStart = $startDt }
        if ($null -eq $maxEnd -or $endDt -gt $maxEnd) { $maxEnd = $endDt }

        if ($MaxRows -gt 0 -and $totalIncluded -ge $MaxRows) {
            break
        }
    }
}
finally {
    $reader.Close()
}

$rows | Export-Csv -NoTypeInformation -Path $CsvPath -Encoding UTF8
$rows | ConvertTo-Json -Depth 6 | Set-Content -Path $JsonPath -Encoding UTF8

$summary = [pscustomobject][ordered]@{
    run_id = $RunId
    provider = $Provider
    input_xml_path = $InputXmlPath
    delta_since = if ($null -eq $deltaDate) { "" } else { $deltaDate.ToString("yyyy-MM-dd HH:mm:ss") }
    total_seen = $totalSeen
    total_included = $totalIncluded
    total_skipped_before_delta = $totalSkippedBeforeDelta
    min_start_time = if ($null -eq $minStart) { "" } else { $minStart.ToString("yyyy-MM-dd HH:mm:ss") }
    max_end_time = if ($null -eq $maxEnd) { "" } else { $maxEnd.ToString("yyyy-MM-dd HH:mm:ss") }
    csv_path = $CsvPath
    json_path = $JsonPath
    status = "pass"
}

$summary | ConvertTo-Json -Depth 6 | Set-Content -Path $SummaryPath -Encoding UTF8

Write-Event @{
    event_type = "job_completed"
    status = "pass"
    source_row_count = $totalSeen
    rows_inserted = 0
    rows_updated = 0
    rows_skipped = $totalSkippedBeforeDelta
    rows_failed = 0
    total_included = $totalIncluded
    summary_path = $SummaryPath
}

Write-Output "OK: EPG snapshot completed. included=$totalIncluded seen=$totalSeen skipped_before_delta=$totalSkippedBeforeDelta summary=$SummaryPath"
