<#
.SYNOPSIS
  EPG Gate 1: Download XMLTV file only.

.DESCRIPTION
  Calls the local/ignored EPG download script and validates the resulting local XMLTV file.
  This worker does not upload and does not import/upsert the DB.

.NOTES
  Keep provider URLs/secrets in local/epg/01_download_epg_xml.ps1.
#>

[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [string]$DownloadScript = ".\local\epg\01_download_epg_xml.ps1",
    [string]$LocalEpgPath = "C:\miratv_ingest\export\epg.xml",
    [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Get-Location).Path
}

$StartedAt = Get-Date
$Stamp = $StartedAt.ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$RunId = "epg-download-$Stamp"
$ReportDir = Join-Path $RepoRoot "runtime\reports\epg_download"
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

$SummaryJson = Join-Path $ReportDir "epg_download_summary_$Stamp.json"

function Invoke-LocalScript {
    param(
        [string]$Path,
        [string]$StepName
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$StepName script not found: $Path"
    }

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $scriptDir = Split-Path -Parent $resolvedPath

    Write-Host "[$StepName] Running: $resolvedPath"
    Write-Host "[$StepName] Working directory: $scriptDir"

    Push-Location $scriptDir
    try {
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $resolvedPath
        if ($LASTEXITCODE -ne 0) {
            throw "$StepName failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }
}

function Test-LocalXmlTvFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "EPG XML file missing: $Path"
    }

    $item = Get-Item -LiteralPath $Path
    if ($item.Length -lt 1024) {
        throw "EPG XML file is unexpectedly small: $($item.Length) bytes"
    }

    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Ignore

    $minStart = $null
    $maxStart = $null
    $minStop = $null
    $maxStop = $null
    $programmeCount = 0
    $maxScan = 250000

    $reader = [System.Xml.XmlReader]::Create($Path, $settings)
    try {
        while ($reader.Read()) {
            if ($reader.NodeType -eq [System.Xml.XmlNodeType]::Element -and $reader.Name -eq "programme") {
                $programmeCount++
                $startRaw = $reader.GetAttribute("start")
                $stopRaw = $reader.GetAttribute("stop")

                if ($startRaw) {
                    $digits = ($startRaw -replace '[^\d]', '')
                    if ($digits.Length -ge 14) {
                        $start14 = $digits.Substring(0, 14)
                        if (-not $minStart -or $start14 -lt $minStart) { $minStart = $start14 }
                        if (-not $maxStart -or $start14 -gt $maxStart) { $maxStart = $start14 }
                    }
                }

                if ($stopRaw) {
                    $digits = ($stopRaw -replace '[^\d]', '')
                    if ($digits.Length -ge 14) {
                        $stop14 = $digits.Substring(0, 14)
                        if (-not $minStop -or $stop14 -lt $minStop) { $minStop = $stop14 }
                        if (-not $maxStop -or $stop14 -gt $maxStop) { $maxStop = $stop14 }
                    }
                }

                if ($programmeCount -ge $maxScan) { break }
            }
        }
    }
    finally {
        $reader.Close()
    }

    if ($programmeCount -lt 1) {
        throw "No programme nodes found in XMLTV file."
    }

    return [pscustomobject]@{
        full_name = $item.FullName
        length_mb = [math]::Round($item.Length / 1MB, 2)
        last_write_time = $item.LastWriteTime.ToString("s")
        scanned_programme_count = $programmeCount
        min_start_raw = $minStart
        max_start_raw = $maxStart
        min_stop_raw = $minStop
        max_stop_raw = $maxStop
    }
}

try {
    Invoke-LocalScript -Path $DownloadScript -StepName "download"
    $xmlInfo = Test-LocalXmlTvFile -Path $LocalEpgPath
    $xmlInfo | Format-List

    $summary = [pscustomobject]@{
        run_id = $RunId
        worker_key = "epg_download_xml"
        stage_key = "media_refresh.epg.download"
        status = "pass"
        disposition = "download_completed"
        environment = $Environment
        local_epg_path = $LocalEpgPath
        xml_info = $xmlInfo
        started_at_utc = $StartedAt.ToUniversalTime().ToString("o")
        finished_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    }

    $summary | ConvertTo-Json -Depth 12 | Set-Content -Path $SummaryJson -Encoding UTF8
    $summary | Format-List run_id,worker_key,stage_key,status,disposition
    exit 0
}
catch {
    $summary = [pscustomobject]@{
        run_id = $RunId
        worker_key = "epg_download_xml"
        stage_key = "media_refresh.epg.download"
        status = "fail"
        disposition = "download_failed"
        environment = $Environment
        error = $_.Exception.Message
        started_at_utc = $StartedAt.ToUniversalTime().ToString("o")
        finished_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    }

    $summary | ConvertTo-Json -Depth 12 | Set-Content -Path $SummaryJson -Encoding UTF8
    Write-Error $_.Exception.Message
    exit 1
}
