<#
=========================================================
 MiraTV – Series EXT Extractor
 PURPOSE:
 - Read clean raw payload as TEXT
 - Locate the "info" block by anchor
 - Extract EXTENDED series metadata only
 - Write series_<id>_series_ext.json
 - No JSON object traversal
=========================================================
#>

$ErrorActionPreference = "Continue"

# --------------------------------------------------
# CONFIG
# --------------------------------------------------
$RAW_INPUT_DIR = "C:\miratv_ingest\raw_store\pickup\default"
$OUTPUT_DIR    = "C:\miratv_ingest\series_sep"


# --------------------------------------------------
# HELPERS
# --------------------------------------------------
function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Get-LatestRawFile {
    Get-ChildItem $RAW_INPUT_DIR -Filter "series_*.raw.json" |
        Sort-Object LastWriteTime |
        Select-Object -First 1
}

function Get-SeriesIdFromName {
    param([string]$Name)
    if ($Name -match 'series[_\-](\d+)') {
        return [int]$Matches[1]
    }
    throw "Unable to resolve series_id from filename"
}

# Brace-balanced object extractor
function Get-ObjectBlock {
    param(
        [string]$Text,
        [string]$Key
    )

    $idx = $Text.IndexOf($Key)
    if ($idx -lt 0) { return $null }

    $start = $Text.IndexOf('{', $idx)
    if ($start -lt 0) { return $null }

    $depth = 0
    $inString = $false

    for ($i = $start; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]

        if ($c -eq '"' -and ($i -eq 0 -or $Text[$i-1] -ne '\')) {
            $inString = -not $inString
        }

        if ($inString) { continue }

        if ($c -eq '{') { $depth++ }
        elseif ($c -eq '}') {
            $depth--
            if ($depth -eq 0) {
                return $Text.Substring($start, $i - $start + 1)
            }
        }
    }

    return $null
}

# --------------------------------------------------
# MAIN
# --------------------------------------------------
Ensure-Dir $OUTPUT_DIR

$rawFile = Get-LatestRawFile
if (-not $rawFile) {
    Write-Host "[SERIES_EXT] No raw series file found"
    exit 0
}

$seriesId = Get-SeriesIdFromName $rawFile.Name
Write-Host "[SERIES_EXT] Processing series_id=$seriesId"
Write-Host "[SERIES_EXT] Raw file: $($rawFile.FullName)"

$text = Get-Content $rawFile.FullName -Raw -Encoding UTF8
$scan = ($text.Fullname -replace '\s+', ' ')


# --------------------------------------------------
# LOCATE INFO BLOCK
# --------------------------------------------------
$infoBlock = Get-ObjectBlock -Text $text -Key '"info"'
if (-not $infoBlock) {
    Write-Host "[SERIES_EXT] No series block present"
    Write-Host "[SERIES_EXT] PASS-THROUGH (no seasons written)"
    exit 0
}

# --------------------------------------------------
# EXTRACT EXTENDED SERIES METADATA
# --------------------------------------------------
$seriesExt = [ordered]@{
    series_id = $seriesId
}

$fields = @(
    'cast',
    'director',
    'episode_run_time',
    'youtube_trailer',
    'last_modified',
    'rating_5based'
)

foreach ($f in $fields) {
    if ($infoBlock -match ("`"" + $f + "`"\s*:\s*(""[^""]*""|\d+)")) {
        $seriesExt[$f] = $Matches[1].Trim('"')
    }
}

# backdrop_path can be array or single string — treat as raw text
if ($infoBlock -match '"backdrop_path"\s*:\s*(\[[^\]]*\]|"[^"]+")') {
    $seriesExt.backdrop_path = $Matches[1]
}

# --------------------------------------------------
# WRITE OUTPUT
# --------------------------------------------------
$outFile = Join-Path $OUTPUT_DIR "series_$seriesId`_series_ext.json"

$seriesExt |
    ConvertTo-Json -Depth 4 |
    Set-Content -Encoding UTF8 $outFile

Write-Host "[SERIES_EXT] WROTE: $outFile"
Write-Host "[SERIES_EXT] DONE"
