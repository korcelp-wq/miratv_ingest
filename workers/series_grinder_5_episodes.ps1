<#
=========================================================
 MiraTV – Series Grinder STEP 5 (Episodes)
 PURPOSE:
 - Extract episode units from provider payload
 - Preserve original extraction behavior
 - Add fallback for season-keyed episode objects
 - File-only operation (NO DB ACCESS)
=========================================================
#>

Set-StrictMode -Version Latest
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

# --------------------------------------------------
# MAIN
# --------------------------------------------------
Ensure-Dir $OUTPUT_DIR

$rawFile = Get-LatestRawFile
if (-not $rawFile) {
    Write-Host "[EPISODES] No raw series file found"
    exit 0
}

$seriesId = Get-SeriesIdFromName $rawFile.Name

Write-Host "[EPISODES] Processing series_id=$seriesId"
Write-Host "[EPISODES] Raw file: $($rawFile.FullName)"

$text = Get-Content $rawFile.FullName -Raw -Encoding UTF8
$data = $text | ConvertFrom-Json

$episodesOut = @()

# ==================================================
# PRIMARY STRATEGY (EXISTING BEHAVIOR)
# ==================================================
try {

    if ($data.PSObject.Properties.Name -contains 'episodes' -and
        ($data.episodes -is [System.Collections.IEnumerable])) {

        foreach ($ep in $data.episodes) {

            $epOut = [ordered]@{
                series_id = $seriesId
            }

            if ($ep.PSObject.Properties.Name -contains 'season') {
                $epOut.season_number = $ep.season
            }

            if ($ep.PSObject.Properties.Name -contains 'episode_num') {
                $epOut.episode_number = $ep.episode_num
            }

            if ($ep.PSObject.Properties.Name -contains 'title') {
                $epOut.title = $ep.title
            }

            if ($ep.PSObject.Properties.Name -contains 'id') {
                $epOut.provider_episode_id = $ep.id
            }

            if ($ep.PSObject.Properties.Name -contains 'container_extension') {
                $epOut.container_extension = $ep.container_extension
            }

            if ($ep.PSObject.Properties.Name -contains 'added') {
                $epOut.added = $ep.added
            }

            if ($ep.PSObject.Properties.Name -contains 'bitrate') {
                $epOut.bitrate = $ep.bitrate
            }

            if ($ep.PSObject.Properties.Name -contains 'info') {
                if ($ep.info -and
                    $ep.info.PSObject.Properties.Name -contains 'duration_secs') {
                    $epOut.duration_secs = $ep.info.duration_secs
                }
            }

            if ($epOut.Keys.Count -gt 1) {
                $episodesOut += [pscustomobject]$epOut
            }
        }
    }

} catch {
    # swallow — fallback decides truth
}

# ==================================================
# FALLBACK STRATEGY (SEASON-KEYED OBJECT)
# ==================================================
if ($episodesOut.Count -eq 0 -and
    $data.PSObject.Properties.Name -contains 'episodes' -and
    ($data.episodes -is [psobject])) {

    Write-Host "[EPISODES] Fallback: season-keyed episode structure detected"

    foreach ($seasonProp in $data.episodes.PSObject.Properties) {

        if ($seasonProp.Name -notmatch '^\d+$') {
            continue
        }

        $seasonNumber = [int]$seasonProp.Name
        $episodeArray = $seasonProp.Value

        if (-not ($episodeArray -is [System.Collections.IEnumerable])) {
            continue
        }

        foreach ($ep in $episodeArray) {

            $epOut = [ordered]@{
                series_id     = $seriesId
                season_number = $seasonNumber
            }

            if ($ep.PSObject.Properties.Name -contains 'episode_num') {
                $epOut.episode_number = $ep.episode_num
            }

            if ($ep.PSObject.Properties.Name -contains 'title') {
                $epOut.title = $ep.title
            }

            if ($ep.PSObject.Properties.Name -contains 'id') {
                $epOut.provider_episode_id = $ep.id
            }

            if ($ep.PSObject.Properties.Name -contains 'container_extension') {
                $epOut.container_extension = $ep.container_extension
            }

            if ($ep.PSObject.Properties.Name -contains 'added') {
                $epOut.added = $ep.added
            }

            if ($ep.PSObject.Properties.Name -contains 'bitrate') {
                $epOut.bitrate = $ep.bitrate
            }

            if ($ep.PSObject.Properties.Name -contains 'info') {
                if ($ep.info -and
                    $ep.info.PSObject.Properties.Name -contains 'duration_secs') {
                    $epOut.duration_secs = $ep.info.duration_secs
                }
            }

            $episodesOut += [pscustomobject]$epOut
        }
    }
}

# --------------------------------------------------
# OUTPUT
# --------------------------------------------------
if ($episodesOut.Count -eq 0) {
    throw "[EPISODES] Episodes block present but no episode units extracted"
}

$outFile = Join-Path $OUTPUT_DIR "series_${seriesId}_episodes.json"

$episodesOut |
    ConvertTo-Json -Depth 6 |
    Set-Content -Encoding UTF8 $outFile

Write-Host "[EPISODES] WROTE: $outFile"
Write-Host "[EPISODES] Count: $($episodesOut.Count)"
Write-Host "[EPISODES] DONE"
