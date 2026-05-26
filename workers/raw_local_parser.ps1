param(
    [Parameter(Mandatory)]
    [string]$InputFile,

    [Parameter(Mandatory)]
    [string]$OutputFile
)

$ErrorActionPreference = "Stop"

Write-Host "🧪 RAW TEXT PARSER (NON-VALIDATING)"
Write-Host "▶ Input : $InputFile"
Write-Host "▶ Output: $OutputFile"

$text = Get-Content $InputFile -Raw

# Find FIRST opening brace
$start = $text.IndexOf('{')

# Find LAST closing brace
$end   = $text.LastIndexOf('}')

if ($start -lt 0 -or $end -le $start) {
    # Still write SOMETHING so pipeline never blocks
    Write-Host "⚠ No brace range found — writing full file as-is"
    $payload = $text
}
else {
    $payload = $text.Substring($start, ($end - $start + 1))
}

# Write text ONLY — no parsing, no validation
[System.IO.File]::WriteAllText(
    $OutputFile,
    $payload,
    [System.Text.Encoding]::UTF8
)

Write-Host "✔ Payload written (text-only, unchecked)"
exit 0
