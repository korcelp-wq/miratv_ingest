# ==================================================
# MiraTV Spool-Based Telemetry Watcher
# Purpose: Monitor pipeline execution and write to spool files
# Mode: External observer writing to existing spool infrastructure
# Integration: Uses CVI (Callosum Vector Integration) layer
# ==================================================

$ErrorActionPreference = "Continue"
Set-StrictMode -Version Latest

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "MiraTV Spool Telemetry Watcher" -ForegroundColor Cyan
Write-Host "CVI Integration Mode" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

# Spool paths (existing infrastructure)
$spoolPaths = @{
    ops = "c:\miratv_ingest\ops_spool"
    lake = "c:\miratv_ingest\lake_spool"
    igm = "c:\miratv_ingest\igm_spool"
}

# Ensure spool directories exist
foreach ($path in $spoolPaths.Values) {
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        Write-Host "[Watcher] Created spool: $path" -ForegroundColor Yellow
    }
}

# Track active processes
$activeJobs = @{}

# ==================================================
# Function: Write-SpoolEvent
# Purpose: Append event to appropriate spool file
# Format: timestamp | source | state | worker | stage | record_id | payload
# ==================================================
function Write-SpoolEvent {
    param(
        [string]$Spool,          # ops, lake, or igm
        [string]$EventType,      # start, checkpoint, success, failure
        [string]$Component,      # master, trigger, worker
        [string]$JobName,        # master_runner2, 00_series_pipeline_trigger, etc.
        [string]$Message,
        [hashtable]$Metadata = @{}
    )

    $timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffffffK"
    $source = "WATCHER"
    $state = $EventType.ToUpper()
    $worker = $Component
    $stage = $JobName
    $recordId = if ($Metadata.ContainsKey('pid')) { $Metadata.pid } else { 0 }
    
    # Build payload (compact key=value format)
    $payloadParts = @()
    foreach ($key in $Metadata.Keys) {
        $payloadParts += "$key=$($Metadata[$key])"
    }
    $payload = if ($payloadParts.Count -gt 0) { $payloadParts -join " " } else { $Message }
    
    # Spool line format: timestamp | source | state | worker | stage | record_id | payload
    $spoolLine = "$timestamp | $source | state=$state | worker=$worker | stage=$stage | series_id=$recordId | $payload"
    
    $spoolFile = Join-Path $spoolPaths[$Spool] "watcher_$(Get-Date -Format 'yyyyMMdd').spool"
    
    try {
        Add-Content -Path $spoolFile -Value $spoolLine -Encoding UTF8
        Write-Host "[Watcher → $Spool] $state | $worker/$stage" -ForegroundColor Gray
    }
    catch {
        Write-Warning "[Watcher] Failed to write to $Spool spool: $_"
    }
}

# ==================================================
# Monitor: Process Watcher
# ==================================================
Write-Host "[Watcher] Starting process monitor..." -ForegroundColor Yellow

$processWatcher = {
    param($SpoolPaths, $ActiveJobs)
    
    while ($true) {
        # Watch for batch file executions
        $batchProcesses = Get-Process -Name "cmd" -ErrorAction SilentlyContinue | 
            Where-Object { $_.CommandLine -match "master_runner|MASTER_ACCESSORY" }
        
        foreach ($proc in $batchProcesses) {
            $procKey = "$($proc.Id)"
            
            if (-not $ActiveJobs.ContainsKey($procKey)) {
                # New job detected
                $jobName = if ($proc.CommandLine -match "(master_runner\d?|MASTER_ACCESSORY)\.bat") {
                    $matches[1]
                } else {
                    "unknown_batch"
                }
                
                $ActiveJobs[$procKey] = @{
                    name = $jobName
                    start_time = Get-Date
                    pid = $proc.Id
                }
                
                # Write to ops spool
                Write-SpoolEvent -Spool "ops" `
                    -EventType "start" `
                    -Component "master" `
                    -JobName $jobName `
                    -Message "Batch execution detected" `
                    -Metadata @{ pid = $proc.Id }
            }
        }
        
        # Check for completed jobs
        $completedKeys = @()
        foreach ($key in $ActiveJobs.Keys) {
            $job = $ActiveJobs[$key]
            $proc = Get-Process -Id $job.pid -ErrorAction SilentlyContinue
            
            if (-not $proc) {
                # Process ended
                $duration = ((Get-Date) - $job.start_time).TotalSeconds
                
                # Write to ops spool
                Write-SpoolEvent -Spool "ops" `
                    -EventType "success" `
                    -Component "master" `
                    -JobName $job.name `
                    -Message "Batch execution completed" `
                    -Metadata @{ 
                        duration_sec = [math]::Round($duration, 2)
                        pid = $job.pid 
                    }
                
                $completedKeys += $key
            }
        }
        
        foreach ($key in $completedKeys) {
            $ActiveJobs.Remove($key)
        }
        
        Start-Sleep -Seconds 2
    }
}

# ==================================================
# Monitor: Statistics Reporter
# ==================================================
Write-Host "[Watcher] Starting statistics monitor..." -ForegroundColor Yellow

$statsReporter = {
    param($SpoolPaths)
    
    while ($true) {
        Start-Sleep -Seconds 30
        
        # Count spool events
        $stats = @{}
        foreach ($spoolName in $SpoolPaths.Keys) {
            $spoolDir = $SpoolPaths[$spoolName]
            if (Test-Path $spoolDir) {
                $files = Get-ChildItem $spoolDir -Filter "*.spool" -ErrorAction SilentlyContinue
                $totalLines = 0
                foreach ($file in $files) {
                    $lines = Get-Content $file.FullName -ErrorAction SilentlyContinue
                    $totalLines += $lines.Count
                }
                $stats[$spoolName] = $totalLines
            }
        }
        
        # Write stats to lake spool
        Write-SpoolEvent -Spool "lake" `
            -EventType "checkpoint" `
            -Component "watcher" `
            -JobName "spool_stats" `
            -Message "Spool statistics" `
            -Metadata $stats
    }
}

# ==================================================
# Start watchers as background jobs
# ==================================================
Write-Host "[Watcher] Launching monitors..." -ForegroundColor Green
Write-Host "[Watcher] Writing to existing spool infrastructure" -ForegroundColor Cyan
Write-Host "[Watcher] CVI layer will handle database ingestion" -ForegroundColor Cyan
Write-Host ""

try {
    # Start process watcher
    $procJob = Start-Job -ScriptBlock $processWatcher -ArgumentList $spoolPaths, $activeJobs -InitializationScript {
        function Write-SpoolEvent {
            param($Spool, $EventType, $Component, $JobName, $Message, $Metadata = @{})
            $spoolPaths = @{
                ops = "c:\miratv_ingest\ops_spool"
                lake = "c:\miratv_ingest\lake_spool"
                igm = "c:\miratv_ingest\igm_spool"
            }
            $timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffffffK"
            $payloadParts = @()
            foreach ($key in $Metadata.Keys) {
                $payloadParts += "$key=$($Metadata[$key])"
            }
            $payload = if ($payloadParts.Count -gt 0) { $payloadParts -join " " } else { $Message }
            $recordId = if ($Metadata.ContainsKey('pid')) { $Metadata.pid } else { 0 }
            $spoolLine = "$timestamp | WATCHER | state=$($EventType.ToUpper()) | worker=$Component | stage=$JobName | series_id=$recordId | $payload"
            $spoolFile = Join-Path $spoolPaths[$Spool] "watcher_$(Get-Date -Format 'yyyyMMdd').spool"
            Add-Content -Path $spoolFile -Value $spoolLine -Encoding UTF8 -ErrorAction SilentlyContinue
        }
    }
    Write-Host "✅ Process monitor started (Job ID: $($procJob.Id))" -ForegroundColor Green
    
    # Start stats reporter
    $statsJob = Start-Job -ScriptBlock $statsReporter -ArgumentList $spoolPaths -InitializationScript {
        function Write-SpoolEvent {
            param($Spool, $EventType, $Component, $JobName, $Message, $Metadata = @{})
            $spoolPaths = @{
                ops = "c:\miratv_ingest\ops_spool"
                lake = "c:\miratv_ingest\lake_spool"
                igm = "c:\miratv_ingest\igm_spool"
            }
            $timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fffffffK"
            $payloadParts = @()
            foreach ($key in $Metadata.Keys) {
                $payloadParts += "$key=$($Metadata[$key])"
            }
            $payload = if ($payloadParts.Count -gt 0) { $payloadParts -join " " } else { $Message }
            $spoolLine = "$timestamp | WATCHER | state=$($EventType.ToUpper()) | worker=$Component | stage=$JobName | series_id=0 | $payload"
            $spoolFile = Join-Path $spoolPaths[$Spool] "watcher_$(Get-Date -Format 'yyyyMMdd').spool"
            Add-Content -Path $spoolFile -Value $spoolLine -Encoding UTF8 -ErrorAction SilentlyContinue
        }
    }
    Write-Host "✅ Statistics reporter started (Job ID: $($statsJob.Id))" -ForegroundColor Green
    
    Write-Host ""
    Write-Host "Watching... Press Ctrl+C to stop" -ForegroundColor Yellow
    Write-Host ""
    
    # Keep script alive and show job output
    while ($true) {
        Receive-Job -Job $procJob -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
        Receive-Job -Job $statsJob -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
        Start-Sleep -Seconds 1
    }
}
finally {
    Write-Host ""
    Write-Host "Stopping watchers..." -ForegroundColor Yellow
    Get-Job | Stop-Job
    Get-Job | Remove-Job
    Write-Host "✅ Telemetry watcher stopped" -ForegroundColor Green
}
