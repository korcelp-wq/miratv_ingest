<#
=========================================================
 MiraTV – Seasons Extractor
 PURPOSE:
 - Read clean raw payload as TEXT
 - Locate the "seasons" block by anchor
 - Extract season units by structure, not schema
 - Write series_<id>_seasons.json
 - Do NOT halt the wider pipeline on malformed input
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

    try {
        if (-not (Test-Path $Path)) {
            New-Item -ItemType Directory -Force -Path $Path | Out-Null
        }
        return $true
    }
    catch {
        Write-Host "[SEASONS][ERROR] Failed to ensure directory: $Path"
        Write-Host "[SEASONS][ERROR] $($_.Exception.Message)"
        return $false
    }
}

function Get-LatestRawFile {
    try {
        return Get-ChildItem $RAW_INPUT_DIR -Filter "series_*.raw.json" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    }
    catch {
        Write-Host "[SEASONS][ERROR] Failed to read raw input directory: $RAW_INPUT_DIR"
        Write-Host "[SEASONS][ERROR] $($_.Exception.Message)"
        return $null
    }
}

function Get-SeriesIdFromName {
    param([string]$Name)

    try {
        if ($Name -match 'series[_\-](\d+)') {
            return [int]$Matches[1]
        }

        Write-Host "[SEASONS][WARN] Unable to resolve series_id from filename: $Name"
        return $null
    }
    catch {
        Write-Host "[SEASONS][ERROR] Failed parsing series_id from filename: $Name"
        Write-Host "[SEASONS][ERROR] $($_.Exception.Message)"
        return $null
    }
}

# Extract a brace-balanced block starting after a key
function Get-BraceBlock {
    param(
        [string]$Text,
        [string]$Key
    )

    try {
        $keyIdx = $Text.IndexOf($Key)
        if ($keyIdx -lt 0) { return $null }

        $braceStart = $Text.IndexOf('[', $keyIdx)
        if ($braceStart -lt 0) { return $null }

        $depth = 0
        $inString = $false

        for ($i = $braceStart; $i -lt $Text.Length; $i++) {
            $c = $Text[$i]

            if ($c -eq '"' -and ($i -eq 0 -or $Text[$i-1] -ne '\')) {
                $inString = -not $inString
            }

            if ($inString) { continue }

            if ($c -eq '[') {
                $depth++
            }
            elseif ($c -eq ']') {
                $depth--
                if ($depth -eq 0) {
                    return $Text.Substring($braceStart, $i - $braceStart + 1)
                }
            }
        }

        return $null
    }
    catch {
        Write-Host "[SEASONS][ERROR] Failed locating brace block for key: $Key"
        Write-Host "[SEASONS][ERROR] $($_.Exception.Message)"
        return $null
    }
}

# Pull top-level object blocks from array text
function Get-ObjectBlocks {
    param([string]$Text)

    try {
        $blocks = @()
        $depth = 0
        $inString = $false
        $start = -1

        for ($i = 0; $i -lt $Text.Length; $i++) {
            $c = $Text[$i]

            if ($c -eq '"' -and ($i -eq 0 -or $Text[$i-1] -ne '\')) {
                $inString = -not $inString
            }

            if ($inString) { continue }

            if ($c -eq '{') {
                if ($depth -eq 0) { $start = $i }
                $depth++
            }
            elseif ($c -eq '}') {
                $depth--
                if ($depth -eq 0 -and $start -ge 0) {
                    $blocks += $Text.Substring($start, $i - $start + 1)
                    $start = -1
                }
            }
        }

        return $blocks
    }
    catch {
        Write-Host "[SEASONS][ERROR] Failed extracting object blocks"
        Write-Host "[SEASONS][ERROR] $($_.Exception.Message)"
        return @()
    }
}

# --------------------------------------------------
# MAIN
# --------------------------------------------------
try {
    $ok = Ensure-Dir $OUTPUT_DIR
    if (-not $ok) {
        Write-Host "[SEASONS] PASS-THROUGH (output dir unavailable)"
        exit 0
    }

    $rawFile = Get-LatestRawFile
    if (-not $rawFile) {
        Write-Host "[SEASONS] No raw series file found"
        exit 0
    }

    $seriesId = Get-SeriesIdFromName $rawFile.Name
    if (-not $seriesId) {
        Write-Host "[SEASONS] PASS-THROUGH (could not resolve series_id)"
        exit 0
    }

    Write-Host "[SEASONS] Processing series_id=$seriesId"
    Write-Host "[SEASONS] Raw file: $($rawFile.FullName)"

    try {
        $text = Get-Content $rawFile.FullName -Raw -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-Host "[SEASONS][ERROR] Failed to read raw file: $($rawFile.FullName)"
        Write-Host "[SEASONS][ERROR] $($_.Exception.Message)"
        Write-Host "[SEASONS] PASS-THROUGH (read failure)"
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        Write-Host "[SEASONS][WARN] Raw file is empty"
        Write-Host "[SEASONS] PASS-THROUGH (empty input)"
        exit 0
    }

    # --------------------------------------------------
    # LOCATE SEASONS BLOCK
    # --------------------------------------------------
    $seasonsBlock = Get-BraceBlock -Text $text -Key '"seasons"'
    if (-not $seasonsBlock) {
        Write-Host "[SEASONS] No seasons block present — implicit or episode-derived series"
        Write-Host "[SEASONS] PASS-THROUGH (no seasons written)"
        exit 0
    }

    # --------------------------------------------------
    # EXTRACT SEASON OBJECTS
    # --------------------------------------------------
    $seasonObjects = Get-ObjectBlocks $seasonsBlock
    if (-not $seasonObjects -or $seasonObjects.Count -eq 0) {
        Write-Host "[SEASONS] No season objects found"
        Write-Host "[SEASONS] PASS-THROUGH (no seasons written)"
        exit 0
    }

    $seasons = @()
    $skipped = 0

    foreach ($b in $seasonObjects) {
        try {
            if ($b -notmatch '"season_number"\s*:\s*(\d+)') {
                Write-Host "[SEASONS][WARN] Skipping season object: missing season_number"
                $skipped++
                continue
            }

            $seasonNum = [int]$Matches[1]

            $s = [ordered]@{
                series_id     = $seriesId
                season_number = $seasonNum
            }

            if ($b -match '"name"\s*:\s*"([^"]+)"') {
                $s.name = $Matches[1]
            }

            if ($b -match '"episode_count"\s*:\s*(\d+)') {
                $s.episode_count = [int]$Matches[1]
            }

            if ($b -match '"air_date"\s*:\s*"([^"]+)"') {
                $s.air_date = $Matches[1]
            }

            if ($b -match '"cover"\s*:\s*"([^"]+)"') {
                $s.cover = $Matches[1]
            }

            $seasons += [pscustomobject]$s
        }
        catch {
            Write-Host "[SEASONS][WARN] Failed to parse one season object for series_id=$seriesId"
            Write-Host "[SEASONS][WARN] $($_.Exception.Message)"
            $skipped++
            continue
        }
    }

    if ($seasons.Count -eq 0) {
        Write-Host "[SEASONS][WARN] Zero valid season objects extracted"
        Write-Host "[SEASONS][WARN] Skipped: $skipped"
        Write-Host "[SEASONS] PASS-THROUGH (nothing written)"
        exit 0
    }

    # --------------------------------------------------
    # WRITE OUTPUT
    # --------------------------------------------------
    $outFile = Join-Path $OUTPUT_DIR "series_$seriesId`_seasons.json"

    try {
        $seasons |
            ConvertTo-Json -Depth 5 |
            Set-Content -Encoding UTF8 $outFile -ErrorAction Stop

        Write-Host "[SEASONS] WROTE: $outFile"
        Write-Host "[SEASONS] Count: $($seasons.Count)"
        if ($skipped -gt 0) {
            Write-Host "[SEASONS] Skipped malformed objects: $skipped"
        }
        Write-Host "[SEASONS] DONE"
        exit 0
    }
    catch {
        Write-Host "[SEASONS][ERROR] Failed writing output file: $outFile"
        Write-Host "[SEASONS][ERROR] $($_.Exception.Message)"
        Write-Host "[SEASONS] PASS-THROUGH (write failure)"
        exit 0
    }
}
catch {
    Write-Host "[SEASONS][FATAL-NONBLOCKING] Unexpected error"
    Write-Host "[SEASONS][FATAL-NONBLOCKING] $($_.Exception.Message)"
    Write-Host "[SEASONS] PASS-THROUGH (non-blocking failure)"
    exit 0
}