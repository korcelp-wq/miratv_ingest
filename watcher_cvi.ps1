# ==================================================
# MiraTV Watcher - Pure CVI Client
# Purpose: Track batch execution via CVI requests
# Credentials: None (uses token only)
# ==================================================

$ErrorActionPreference = "Continue"

$CVI_ENDPOINT = "https://miratv.club/_workers/cvi_request.php"
$TOKEN = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "MiraTV Watcher (Pure CVI Mode)" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

# ==================================================
# Function: Submit-CviRequest
# Purpose: Post coordination request to CVI
# ==================================================
function Submit-CviRequest {
    param(
        [string]$Routine,
        [hashtable]$Context
    )
    
    $payload = @{
        routine = $Routine
        context = $Context
        source = "watcher_cvi"
    } | ConvertTo-Json -Compress
    
    try {
        $response = Invoke-RestMethod -Uri "$CVI_ENDPOINT`?token=$TOKEN" `
            -Method POST `
            -ContentType "application/json" `
            -Body $payload `
            -TimeoutSec 5
        
        Write-Host "[CVI] $Routine -> request_id=$($response.request_id)" -ForegroundColor Green
    }
    catch {
        Write-Warning "[CVI] Failed: $_"
    }
}

# ==================================================
# Monitor: Process Watcher
# ==================================================
Write-Host "[Watcher] Monitoring batch executions..." -ForegroundColor Yellow

$activeJobs = @{}

while ($true) {
    $batchProcesses = Get-Process -Name "cmd" -ErrorAction SilentlyContinue
    
    foreach ($proc in $batchProcesses) {
        $procKey = "$($proc.Id)"
        
        if (-not $activeJobs.ContainsKey($procKey)) {
            $activeJobs[$procKey] = @{
                pid = $proc.Id
                start_time = Get-Date
            }
            
            Submit-CviRequest -Routine "record_batch_start" `
                -Context @{
                    pid = $proc.Id
                    timestamp = (Get-Date).ToString("o")
                }
        }
    }
    
    $completedKeys = @()
    foreach ($key in $activeJobs.Keys) {
        $job = $activeJobs[$key]
        $proc = Get-Process -Id $job.pid -ErrorAction SilentlyContinue
        
        if (-not $proc) {
            $duration = ((Get-Date) - $job.start_time).TotalSeconds
            
            Submit-CviRequest -Routine "record_batch_complete" `
                -Context @{
                    pid = $job.pid
                    duration_sec = [math]::Round($duration, 2)
                    timestamp = (Get-Date).ToString("o")
                }
            
            $completedKeys += $key
        }
    }
    
    foreach ($key in $completedKeys) {
        $activeJobs.Remove($key)
    }
    
    Start-Sleep -Seconds 2
}
