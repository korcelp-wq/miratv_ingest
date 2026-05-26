$InputFile = "C:\miratv_ingest\export\epg.xml"
$Part1     = "C:\miratv_ingest\export\epg_part1.xml"
$Part2     = "C:\miratv_ingest\export\epg_part2.xml"

# Count programme starts
$totalPrograms = 0
Get-Content $InputFile | ForEach-Object {
    if ($_ -match "<programme\b") {
        $totalPrograms++
    }
}

$splitAt = [Math]::Ceiling($totalPrograms / 2)

Write-Host "Total programmes=$totalPrograms"
Write-Host "Split at=$splitAt"

$w1 = New-Object System.IO.StreamWriter($Part1, $false, [System.Text.Encoding]::UTF8)
$w2 = New-Object System.IO.StreamWriter($Part2, $false, [System.Text.Encoding]::UTF8)

$programCount = 0
$currentWriter = $w1
$beforePrograms = $true
$headerLines = New-Object System.Collections.Generic.List[string]

try {
    Get-Content $InputFile | ForEach-Object {
        $line = $_

        if ($beforePrograms) {
            if ($line -match "<programme\b") {
                $beforePrograms = $false

                # Write original header/channel section to BOTH files
                foreach ($h in $headerLines) {
                    $w1.WriteLine($h)
                    $w2.WriteLine($h)
                }

                $programCount++
                $currentWriter = if ($programCount -le $splitAt) { $w1 } else { $w2 }
                $currentWriter.WriteLine($line)
            }
            else {
                # Skip final </tv> if it appears before programmes somehow
                if ($line -notmatch "</tv>") {
                    $headerLines.Add($line)
                }
            }
        }
        else {
            if ($line -match "<programme\b") {
                $programCount++
                $currentWriter = if ($programCount -le $splitAt) { $w1 } else { $w2 }
            }

            if ($line -notmatch "</tv>") {
                $currentWriter.WriteLine($line)
            }
        }
    }

    $w1.WriteLine("</tv>")
    $w2.WriteLine("</tv>")
}
finally {
    $w1.Close()
    $w2.Close()
}

Write-Host "DONE split."
Write-Host "Part1=$Part1"
Write-Host "Part2=$Part2"