# One-shot spool uploader - called from batch files
$CVI_ENDPOINT = "https://miratv.club/_workers/cvi_request.php"
$TOKEN = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$SPOOL_DIRS = @("c:\miratv_ingest\ops_spool", "c:\miratv_ingest\lake_spool", "c:\miratv_ingest\igm_spool")
$uploaded = 0

foreach ($dir in $SPOOL_DIRS) {
    if (-not (Test-Path $dir)) { continue }
    
    $logFiles = Get-ChildItem "$dir\*.log" -ErrorAction SilentlyContinue
    
    foreach ($file in $logFiles) {
        $lines = Get-Content $file.FullName -ErrorAction SilentlyContinue
        if ($lines.Count -eq 0) { continue }
        
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            
            curl.exe -X POST "$CVI_ENDPOINT`?token=$TOKEN" -H "Content-Type: text/plain" -d $line --max-time 5 2>$null | Out-Null
            $uploaded++
        }
        
        # Move processed
        $processed = "c:\miratv_ingest\processed"
        if (-not (Test-Path $processed)) { New-Item -ItemType Directory -Path $processed | Out-Null }
        Move-Item $file.FullName "$processed\$($file.Name).$(Get-Date -Format 'yyyyMMddHHmmss')" -Force
    }
}

if ($uploaded -gt 0) {
    Write-Host "Uploaded $uploaded spool entries" -ForegroundColor Gray
}
