# ==================================================
# Spool Uploader - Streams spool files to CVI
# No JSON processing - just reads text and posts
# ==================================================

$ErrorActionPreference = "Continue"

$CVI_ENDPOINT = "https://miratv.club/_workers/cvi_request.php"
$TOKEN = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$SPOOL_DIRS = @("c:\miratv_ingest\ops_spool", "c:\miratv_ingest\lake_spool", "c:\miratv_ingest\igm_spool")

Write-Host "[Uploader] Starting spool file monitoring..." -ForegroundColor Cyan

while ($true) {
    foreach ($dir in $SPOOL_DIRS) {
        if (-not (Test-Path $dir)) { continue }
        
        $logFiles = Get-ChildItem "$dir\*.log" -ErrorAction SilentlyContinue
        
        foreach ($file in $logFiles) {
            $lines = Get-Content $file.FullName -ErrorAction SilentlyContinue
            
            if ($lines.Count -eq 0) { continue }
            
            foreach ($line in $lines) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                
                # Post raw line to CVI
                try {
                    $response = curl.exe -X POST "$CVI_ENDPOINT`?token=$TOKEN" `
                        -H "Content-Type: text/plain" `
                        -d $line `
                        --max-time 5 2>&1
                    
                    Write-Host "[Uploaded] $($file.Name)" -ForegroundColor Gray
                }
                catch {
                    Write-Warning "[Upload Failed] $($file.Name): $_"
                }
            }
            
            # Move processed file
            $processed = "c:\miratv_ingest\processed"
            if (-not (Test-Path $processed)) { New-Item -ItemType Directory -Path $processed | Out-Null }
            Move-Item $file.FullName "$processed\$($file.Name).processed" -Force
        }
    }
    
    Start-Sleep -Seconds 5
}
