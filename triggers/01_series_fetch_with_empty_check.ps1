# =========================================================
# Series Fetch with Empty Check (Intermediate Trigger)
# =========================================================
# Purpose: Fetch series details and fast-track empty ones
# =========================================================

$ErrorActionPreference = "Stop"

Write-Host "[01] SERIES FETCH WITH EMPTY CHECK"

:FETCH_LOOP while ($true) {
    
    # Call the worker to fetch series details
    Write-Host "Calling series_details_worker..."
    & pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\miratv_ingest\workers\series_details_worker.ps1"
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Worker failed"
        exit 1
    }
    
    # Check the most recent raw file
    $rawFiles = Get-ChildItem "C:\miratv_ingest\raw_store" -Filter "*.raw.json" | 
                Sort-Object LastWriteTime -Descending | 
                Select-Object -First 1
    
    if (-not $rawFiles) {
        Write-Host "No raw file found - exiting normally"
        exit 0
    }
    
    $rawFile = $rawFiles
    $fileSize = $rawFile.Length
    
    Write-Host "Raw file: $($rawFile.Name) ($fileSize bytes)"
    
    # Check if file is too small (empty series response)
    if ($fileSize -le 20) {
        $content = Get-Content $rawFile.FullName -Raw
        
        # Detect empty responses
        if ($content -match '^\s*\[\s*\]\s*$' -or 
            $content -match '^\s*\{\s*"episodes"\s*:\s*\[\s*\]\s*\}\s*$') {
            
            Write-Host ""
            Write-Host "⚠️  EMPTY SERIES DETECTED: $($rawFile.Name)"
            Write-Host "📄 Content: $($content.Trim())"
            Write-Host "⏭️  Fast-tracking to finalization (skipping steps 2-8)..."
            Write-Host ""
            
            # STEP 9: Episode resolver
            Write-Host "  [STEP 9] Running episode resolver..."
            & pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\miratv_ingest\triggers\9episode_resolver_trigger.ps1"
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Episode resolver failed"
                exit 1
            }
            Write-Host "  ✅ STEP 9 COMPLETE"
            
            # STEP 10: Finalize series
            Write-Host "  [STEP 10] Running finalize series..."
            & pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\miratv_ingest\triggers\08_finalize_series_trigger.ps1"
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Finalize series failed"
                exit 1
            }
            Write-Host "  ✅ STEP 10 COMPLETE"
            
            Write-Host ""
            Write-Host "✅ Empty series finalized - fetching next..."
            Write-Host ""
            
            # Loop back to fetch next series
            Start-Sleep -Seconds 2
            continue
        }
    }
    
    # Normal size file - exit to continue normal pipeline
    Write-Host "✅ Series has data - continuing to normal pipeline"
    break
}

Write-Host "[01] SERIES FETCH COMPLETE"
exit 0

