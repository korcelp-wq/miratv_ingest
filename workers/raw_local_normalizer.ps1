param (
    [Parameter(Mandatory = $true)]
    [string]$InputFile,

    [Parameter(Mandatory = $true)]
    [string]$OutputFile
)

$ErrorActionPreference = "Stop"

Write-Host "🧼 RAW LOCAL NORMALIZER (TEXT-ONLY)"

# --------------------------------------------------
# 1) Load input safely
# --------------------------------------------------
if (-not (Test-Path $InputFile)) {
    throw "Input file not found: $InputFile"
}

$text = Get-Content $InputFile -Raw -Encoding UTF8

if ([string]::IsNullOrWhiteSpace($text)) {
    throw "Normalizer received empty input file"
}

# --------------------------------------------------
# 2) GLOBAL DISPLAY-WRAP REPAIR
#    Join tokens split by rendering
# --------------------------------------------------
# Examples:
#   se\n ason -> season
#   2 \n0 -> 20
#   jp \ng -> jpg
$text = $text -replace "([^\s])\r?\n\s*([^\s])", '$1$2'

# Normalize excessive line breaks (cosmetic)
$text = $text -replace "\r?\n{3,}", "`n`n"

# --------------------------------------------------
# 3) EPISODES-SCOPED NORMALIZATION
#    Gentle, semantic-aware, no parsing
# --------------------------------------------------
$epIndex = $text.IndexOf('"episodes"')

if ($epIndex -ge 0) {

    $start = $text.IndexOf('{', $epIndex)
    if ($start -ge 0) {

        $depth = 0
        $end = -1

        for ($i = $start; $i -lt $text.Length; $i++) {
            if ($text[$i] -eq '{') {
                $depth++
            }
            elseif ($text[$i] -eq '}') {
                $depth--
                if ($depth -eq 0) {
                    $end = $i
                    break
                }
            }
        }

        if ($end -gt $start) {

            $episodesBlob = $text.Substring($start, $end - $start + 1)

            # ------------------------------------------
            # Identifier repair
            #   "epis ode_num" -> "episode_num"
            # ------------------------------------------
            $episodesBlob = $episodesBlob -replace '"([a-zA-Z]+)\s+([a-zA-Z_]+)"', '"$1$2"'

            # ------------------------------------------
            # Numeric repair
            #   2 0 -> 20
            #   3 .5 -> 3.5
            # ------------------------------------------
            $episodesBlob = $episodesBlob -replace '(\d)\s+(\d)', '$1$2'
            $episodesBlob = $episodesBlob -replace '(\d)\s+\.(\d)', '$1.$2'

            # ------------------------------------------
            # URL / path repair
            # ------------------------------------------
            $episodesBlob = $episodesBlob -replace '(https?:\/\/[^\s"]+)\s+([^\s"])', '$1$2'
            $episodesBlob = $episodesBlob -replace '\\\/\s+([a-zA-Z0-9])', '\\/$1'

            # ------------------------------------------
            # Reinsert normalized episodes blob
            # ------------------------------------------
            $text =
                $text.Substring(0, $start) +
                $episodesBlob +
                $text.Substring($end + 1)
        }
    }
}

# --------------------------------------------------
# 4) WRITE OUTPUT (ALWAYS)
# --------------------------------------------------
Set-Content -Path $OutputFile -Value $text -Encoding UTF8

Write-Host "✔ Normalized → $OutputFile"
Write-Host "✔ Output length: $($text.Length)"

return
