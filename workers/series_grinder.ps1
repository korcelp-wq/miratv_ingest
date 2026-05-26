<#
=========================================================
 MiraTV – Series CORE Extractor
 PURPOSE:
 - Read clean raw payload as TEXT
 - Locate the "info" block by anchor
 - Extract SERIES CORE fields only
 - Write series_<id>_series.json
 - No JSON object traversal
=========================================================
#>

$ErrorActionPreference = "Stop"

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

        Write-Host "The path is: $Path"
    }
}

function Get-LatestRawFile {
    Get-ChildItem $RAW_INPUT_DIR -Filter "series_*.raw.json" |
        Sort-Object LastWriteTime |
        Select-Object -First 1
    
    Write-Host "The path is: $Path"
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
    Write-Host "[SERIES] No raw series file found"
    exit 0
}

$seriesId = Get-SeriesIdFromName $rawFile.Name
Write-Host "[SERIES] Processing series_id=$seriesId"
Write-Host "[SERIES] Raw file: $($rawFile.FullName)"


# 🔑 TEXT NORMALIZATION (MUST BE HERE)
$text = Get-Content $rawFile.FullName -Raw -Encoding UTF8
$scan = ($text -replace '\s+', ' ')


# --------------------------------------------------
# LOCATE INFO BLOCK
# --------------------------------------------------
$infoBlock = Get-ObjectBlock -Text $text -Key '"info"'
if (-not $infoBlock) {
    
    Write-Host "[SERIES] No series block present"
    Write-Host "[SERIES] PASS-THROUGH (no seasons written)"
    exit 0
}

# --------------------------------------------------
# EXTRACT SERIES CORE
# --------------------------------------------------
$series = [ordered]@{
    series_id = $seriesId
}

# Core fields only — boring and stable
$fields = @(
    'name',
    'cover',
    'plot',
    'genre',
    'releaseDate',
    'rating',
    'category_id'
)

foreach ($f in $fields) {
    if ($infoBlock -match ("`"" + $f + "`"\s*:\s*(""[^""]*""|\d+)")) {
        $val = $Matches[1].Trim('"')
        $series[$f] = $val
    }
}

# --------------------------------------------------
# WRITE OUTPUT
# --------------------------------------------------
$outFile = Join-Path $OUTPUT_DIR "series_$seriesId`_series.json"

$series |
    ConvertTo-Json -Depth 4 |
    Set-Content -Encoding UTF8 $outFile

Write-Host "[SERIES] WROTE: $outFile"
Write-Host "[SERIES] DONE"
