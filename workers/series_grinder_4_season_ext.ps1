<#
=========================================================
 MiraTV – Season EXT Extractor
 PURPOSE:
 - Read clean raw payload as TEXT
 - Locate the "seasons" array by anchor
 - Extract extended season metadata
 - Write series_<id>_season_ext.json
 - Do not stop the wider pipeline on malformed input
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
        Write-Host "[SEASON_EXT][ERROR] Failed to ensure directory: $Path"
        Write-Host "[SEASON_EXT][ERROR] $($_.Exception.Message)"
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
        Write-Host "[SEASON_EXT][ERROR] Failed to read raw input directory: $RAW_INPUT_DIR"
        Write-Host "[SEASON_EXT][ERROR] $($_.Exception.Message)"
        return $null
    }
}

function Get-SeriesIdFromName {
    param([string]$Name)

    try {
        if ($Name -match 'series[_\-](\d+)') {
            return [int]$Matches[1]
        }

        Write-Host "[SEASON_EXT][WARN] Unable to resolve series_id from filename: $Name"
        return $null
    }
    catch {
        Write-Host "[SEASON_EXT][ERROR] Failed parsing series_id from filename: $Name"
        Write-Host "[SEASON_EXT][ERROR] $($_.Exception.Message)"
        return $null
    }
}

function Get-BracketBlock {
    param(
        [string]$Text,
        [string]$Key
    )

    try {
        $idx = $Text.IndexOf($Key)
        if ($idx -lt 0) { return $null }

        $start = $Text.IndexOf('[', $idx)
        if ($start -lt 0) { return $null }

        $depth = 0
        $inString = $false

        for ($i = $start; $i -lt $Text.Length; $i++) {
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
                    return $Text.Substring($start, $i - $start + 1)
                }
            }
        }

        return $null
    }
    catch {
        Write-Host "[SEASON_EXT][ERROR] Failed locating bracket block for key: $Key"
        Write-Host "[SEASON_EXT][ERROR] $($_.Exception.Message)"
        return $null
    }
}

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
        Write-Host "[SEASON_EXT][ERROR] Failed extracting object blocks"
        Write-Host "[SEASON_EXT][ERROR] $($_.Exception.Message)"
        return @()
    }
}

# --------------------------------------------------
# MAIN
# --------------------------------------------------
try {
    $ok = Ensure-Dir $OUTPUT_DIR
    if (-not $ok) {
        Write-Host "[SEASON_EXT] PASS-THROUGH (output dir unavailable)"
        exit 0
    }

    $rawFile = Get-LatestRawFile
    if (-not $rawFile) {
        Write-Host "[SEASON_EXT] No raw series file found"
        exit 0
    }

    $seriesId = Get-SeriesIdFromName $rawFile.Name
    if (-not $seriesId) {
        Write-Host "[SEASON_EXT] PASS-THROUGH (could not resolve series_id)"
        exit 0
    }

    Write-Host "[SEASON_EXT] Processing series_id=$seriesId"
    Write-Host "[SEASON_EXT] Raw file: $($rawFile.FullName)"

    try {
        $text = Get-Content $rawFile.FullName -Raw -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-Host "[SEASON_EXT][ERROR] Failed to read raw file: $($rawFile.FullName)"
        Write-Host "[SEASON_EXT][ERROR] $($_.Exception.Message)"
        Write-Host "[SEASON_EXT] PASS-THROUGH (read failure)"
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        Write-Host "[SEASON_EXT][WARN] Raw file is empty"
        Write-Host "[SEASON_EXT] PASS-THROUGH (empty input)"
        exit 0
    }

    # --------------------------------------------------
    # LOCATE SEASONS ARRAY
    # --------------------------------------------------
    $seasonsBlock = Get-BracketBlock -Text $text -Key '"seasons"'
    if (-not $seasonsBlock) {
        Write-Host "[SEASON_EXT] seasons block not found"
        Write-Host "[SEASON_EXT] PASS-THROUGH (no seasons block)"
        exit 0
    }

    $seasonObjects = Get-ObjectBlocks $seasonsBlock
    if (-not $seasonObjects -or $seasonObjects.Count -eq 0) {
        Write-Host "[SEASON_EXT] No season objects found"
        Write-Host "[SEASON_EXT] PASS-THROUGH (no seasons written)"
        exit 0
    }

    # --------------------------------------------------
    # EXTRACT EXTENDED FIELDS
    # --------------------------------------------------
    $seasonExt = @()
    $skipped = 0

    foreach ($b in $seasonObjects) {
        try {
            if ($b -notmatch '"season_number"\s*:\s*(\d+)') {
                Write-Host "[SEASON_EXT][WARN] Skipping season object: missing season_number"
                $skipped++
                continue
            }

            $seasonNum = [int]$Matches[1]

            $s = [ordered]@{
                series_id     = $seriesId
                season_number = $seasonNum
            }

            if ($b -match '"overview"\s*:\s*"([^"]*)"') {
                $s.overview = $Matches[1]
            }

            if ($b -match '"cover_big"\s*:\s*"([^"]+)"') {
                $s.cover_big = $Matches[1]
            }

            if ($b -match '"id"\s*:\s*(\d+)') {
                $s.provider_season_id = [int]$Matches[1]
            }

            $seasonExt += [pscustomobject]$s
        }
        catch {
            Write-Host "[SEASON_EXT][WARN] Failed to parse one season object for series_id=$seriesId"
            Write-Host "[SEASON_EXT][WARN] $($_.Exception.Message)"
            $skipped++
            continue
        }
    }

    if ($seasonExt.Count -eq 0) {
        Write-Host "[SEASON_EXT][WARN] Zero valid season objects extracted"
        Write-Host "[SEASON_EXT][WARN] Skipped: $skipped"
        Write-Host "[SEASON_EXT] PASS-THROUGH (nothing written)"
        exit 0
    }

    # --------------------------------------------------
    # WRITE OUTPUT
    # --------------------------------------------------
    $outFile = Join-Path $OUTPUT_DIR "series_$seriesId`_season_ext.json"

    try {
        $seasonExt |
            ConvertTo-Json -Depth 5 |
            Set-Content -Encoding UTF8 $outFile -ErrorAction Stop

        Write-Host "[SEASON_EXT] WROTE: $outFile"
        Write-Host "[SEASON_EXT] Count: $($seasonExt.Count)"
        if ($skipped -gt 0) {
            Write-Host "[SEASON_EXT] Skipped malformed objects: $skipped"
        }
        Write-Host "[SEASON_EXT] DONE"
        exit 0
    }
    catch {
        Write-Host "[SEASON_EXT][ERROR] Failed writing output file: $outFile"
        Write-Host "[SEASON_EXT][ERROR] $($_.Exception.Message)"
        Write-Host "[SEASON_EXT] PASS-THROUGH (write failure)"
        exit 0
    }
}
catch {
    Write-Host "[SEASON_EXT][FATAL-NONBLOCKING] Unexpected error"
    Write-Host "[SEASON_EXT][FATAL-NONBLOCKING] $($_.Exception.Message)"
    Write-Host "[SEASON_EXT] PASS-THROUGH (non-blocking failure)"
    exit 0
}