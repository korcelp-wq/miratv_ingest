param (
    [string]$InputFile
)

$ErrorActionPreference = "Continue"

$BASE = "C:\miratv_ingest"
$OUT  = Join-Path $BASE "series_sep"

if (!(Test-Path $OUT)) {
    New-Item -ItemType Directory -Force -Path $OUT | Out-Null
}

# ---------------- SERIES ID ----------------
$seriesId = ($InputFile | Split-Path -Leaf) -replace '[^\d]', ''
if (-not $seriesId) { return }

# ---------------- LOAD BLOB ----------------
$raw = Get-Content $InputFile -Raw -Encoding UTF8

# ---------------- REPAIR DISPLAY WRAPPING ----------------
# Join split tokens: letters, digits, URLs
$blob = $raw -replace "([^\s])\r?\n\s*([^\s])", '$1$2'

# ---------------- BASIC PRESENCE CHECK ----------------
if (-not ($blob -match '"info"\s*:') -or -not ($blob -match '"episodes"\s*:')) {
    return   # no quarantine, just skip
}

# =========================================================
# 1️⃣ series_N_series.json  (TEXT BUILD)
# =========================================================
$seriesText = @()
$seriesText += '{'
$seriesText += "  `"series_id`": $seriesId,"

foreach ($key in @('name','cover','plot','genre','releaseDate','rating','category_id')) {
    if ($blob -match "`"$key`"\s*:\s*([^,}\]]+)") {
        $seriesText += "  `"$key`": $($Matches[1]),"
    }
}

$seriesText[-1] = $seriesText[-1].TrimEnd(',')
$seriesText += '}'

$seriesText -join "`n" |
    Out-File (Join-Path $OUT "series_${seriesId}_series.json") -Encoding UTF8

# =========================================================
# 2️⃣ series_N_series_ext.json
# =========================================================
$extText = @()
$extText += '{'
$extText += "  `"series_id`": $seriesId,"

foreach ($key in @('cast','director','episode_run_time','youtube_trailer','last_modified','rating_5based')) {
    if ($blob -match "`"$key`"\s*:\s*([^,}\]]+)") {
        $extText += "  `"$key`": $($Matches[1]),"
    }
}

$extText[-1] = $extText[-1].TrimEnd(',')
$extText += '}'

$extText -join "`n" |
    Out-File (Join-Path $OUT "series_${seriesId}_series_ext.json") -Encoding UTF8

# =========================================================
# 3️⃣ series_N_seasons.json  (ARRAY TEXT)
# =========================================================
$seasonMatches = [regex]::Matches($blob, '\{[^{}]*"season_number"\s*:\s*\d+[^{}]*\}')

$seasonOut = @('[')
foreach ($m in $seasonMatches) {
    $seasonOut += "  $($m.Value),"
}
if ($seasonOut.Count -gt 1) {
    $seasonOut[-1] = $seasonOut[-1].TrimEnd(',')
}
$seasonOut += ']'

$seasonOut -join "`n" |
    Out-File (Join-Path $OUT "series_${seriesId}_seasons.json") -Encoding UTF8

# =========================================================
# 4️⃣ series_N_season_ext.json (same blocks, reused)
# =========================================================
$seasonOut -join "`n" |
    Out-File (Join-Path $OUT "series_${seriesId}_season_ext.json") -Encoding UTF8

# =========================================================
# 5️⃣ series_N_episodes.json (FLATTENED)
# =========================================================
$episodeMatches = [regex]::Matches($blob, '\{[^{}]*"episode_num"\s*:\s*\d+[^{}]*\}')

$episodeOut = @('[')
foreach ($m in $episodeMatches) {
    $episodeOut += "  $($m.Value),"
}
if ($episodeOut.Count -gt 1) {
    $episodeOut[-1] = $episodeOut[-1].TrimEnd(',')
}
$episodeOut += ']'

$episodeOut -join "`n" |
    Out-File (Join-Path $OUT "series_${seriesId}_episodes.json") -Encoding UTF8

return
