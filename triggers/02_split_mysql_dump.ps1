$InputFile = "C:\MiraTV_infrastructure\PARAMS_DOCS\MyAdmin SQL Dump2.txt"
$OutDir    = "C:\MiraTV_infrastructure\PARAMS_DOCS\dump_segments"

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$content = Get-Content $InputFile -Raw
$content = $content -replace "`r`n", "`n"

# Normalize spacing
$content = "`n" + $content

# Define real MySQL statement starters
$pattern = '(?=\n(?:CREATE TABLE|ALTER TABLE|CREATE PROCEDURE|DROP TABLE|DROP VIEW|DROP PROCEDURE|INSERT INTO|SET |USE ))'

$segments = $content -split $pattern

$i = 1
foreach ($seg in $segments) {

    $clean = $seg.Trim()

    if ($clean.Length -lt 40) { continue }

    $file = Join-Path $OutDir ("segment_{0:D3}.sql" -f $i)
    Set-Content -Path $file -Value $clean -Encoding UTF8
    $i++
}

Write-Host "Segments created:" ($i - 1)
