#!/usr/bin/env pwsh
# =====================================================================
# MIRATV INGEST UPLOADER
# Monitors C:\miratv_ingest for .spool, .txt, .log files
# =====================================================================

param(
    [string]$Mode = "menu"  # menu, watch, or file
)

# Locked configuration
$script:config = @{
    Token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
    Endpoint = "https://miratv.club/_workers/api/series/dog_open.php?token=
    "
    Database = "ops"
    
    # Locked to C:\miratv_ingest\uploads
    WatchDir = "C:\miratv_ingest\uploads"
    ProcessedDir = "C:\miratv_ingest\processed"
    FailedDir = "C:\miratv_ingest\failed"
    
    # Only these file types
    AllowedExtensions = @('.spool', '.txt', '.log')
    
    LogFile = "C:\miratv_ingest\upload_log.txt"
}

# Create directories if they don't exist
foreach ($dir in @($script:config.ProcessedDir, $script:config.FailedDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "📁 Created: $dir" -ForegroundColor Gray
    }
}

# Simple logging
function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMsg = "[$timestamp] $Message"
    Write-Host $logMsg -ForegroundColor $Color
    Add-Content -Path $script:config.LogFile -Value $logMsg
}

# Upload function
function Upload-File {
    param([string]$FilePath)
    
    $fileName = [System.IO.Path]::GetFileName($FilePath)
    Write-Log "📤 Uploading: $fileName" -Color "Cyan"
    
    try {
        # Read file
        $content = Get-Content -Path $FilePath -Raw -ErrorAction Stop
        $fileSize = (Get-Item $FilePath).Length
        
        # Escape for SQL
        $escapedContent = $content -replace "'", "''"
        $escapedFileName = $fileName -replace "'", "''"
        
        # Insert into ai_memory_index
        $sql = @"
INSERT INTO ai_memory_index (
    unit_type,
    domain,
    source_db,
    source_table,
    summary,
    content_ref,
    confidence,
    active,
    created_at
) VALUES (
    'ingest_file',
    'miratv_ingest',
    'ops',
    'ingest',
    'File: $escapedFileName | Size: $fileSize bytes',
    '$escapedContent',
    0.95,
    1,
    NOW()
)
"@

        $body = @{
            token = $script:config.Token
            db = $script:config.Database
            sql = $sql
            params = @()
        } | ConvertTo-Json

        $response = Invoke-RestMethod -Uri $script:config.Endpoint -Method Post -Body $body -ContentType "application/json" -TimeoutSec 30
        
        # Move to processed
        $dest = Join-Path $script:config.ProcessedDir $fileName
        Move-Item -Path $FilePath -Destination $dest -Force
        Write-Log "✅ Uploaded and moved to processed: $fileName" -Color "Green"
        
        return $true
    }
    catch {
        Write-Log "❌ Failed: $fileName - $_" -Color "Red"
        
        # Move to failed
        $dest = Join-Path $script:config.FailedDir $fileName
        Move-Item -Path $FilePath -Destination $dest -Force
        Write-Log "📦 Moved to failed folder" -Color "Gray"
        
        return $false
    }
}

# Scan and upload all matching files
function Scan-And-Upload {
    Write-Log "
    C:\miratv_ingest\uploads for .spool, .txt, .log files..." -Color "Yellow"
    
    $files = Get-ChildItem -Path $script:config.WatchDir -File | Where-Object { 
        $_.Extension -in $script:config.AllowedExtensions 
    }
    
    if ($files.Count -eq 0) {
        Write-Log "No matching files found" -Color "Yellow"
        return
    }
    
    Write-Log "Found $($files.Count) files to upload" -Color "Green"
    
    $success = 0
    $failed = 0
    
    foreach ($file in $files) {
        if (Upload-File -FilePath $file.FullName) {
            $success++
        } else {
            $failed++
        }
    }
    
    Write-Log "📊 Summary: $success uploaded, $failed failed" -Color "Cyan"
}

# Watch folder for new files
function Start-Watcher {
    Write-Log "👁️ Watching C:\miratv_ingest\uploads for .spool, .txt, .log files..." -Color "Magenta"
    Write-Log "Press Ctrl+C to stop" -Color "Yellow"
    
    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $script:config.WatchDir
    $watcher.Filter = "*.*"
    $watcher.EnableRaisingEvents = $true
    
    $action = {
        $path = $Event.SourceEventArgs.FullPath
        $changeType = $Event.SourceEventArgs.ChangeType
        $extension = [System.IO.Path]::GetExtension($path).ToLower()
        
        if ($changeType -eq 'Created' -and $extension -in $using:script:config.AllowedExtensions) {
            Start-Sleep -Seconds 1  # Wait for file to be written
            Write-Log "📥 New file detected: $([System.IO.Path]::GetFileName($path))" -Color "Magenta"
            Upload-File -FilePath $path
        }
    }
    
    Register-ObjectEvent -InputObject $watcher -EventName "Created" -Action $action | Out-Null
    
    try {
        while ($true) { Start-Sleep -Seconds 5 }
    }
    finally {
        $watcher.EnableRaisingEvents = $false
        $watcher.Dispose()
        Get-EventSubscriber | Unregister-Event
    }
}

# Menu
function Show-Menu {
    Clear-Host
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║     MIRATV INGEST UPLOADER                              ║" -ForegroundColor Cyan
    Write-Host "║     C:\miratv_ingest → OPS Database                     ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "📁 Watching: C:\miratv_ingest" -ForegroundColor Yellow
    Write-Host "📁 Processed: $($script:config.ProcessedDir)" -ForegroundColor Gray
    Write-Host "📁 Failed: $($script:config.FailedDir)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "📄 File types: .spool, .txt, .log" -ForegroundColor White
    Write-Host ""
    Write-Host "1) Scan and upload all files now" -ForegroundColor Green
    Write-Host "2) Watch folder continuously (auto-upload)" -ForegroundColor Green
    Write-Host "3) View last 10 log entries" -ForegroundColor Green
    Write-Host "Q) Quit" -ForegroundColor Red
    Write-Host ""
}

# View logs
function Show-Logs {
    if (Test-Path $script:config.LogFile) {
        Write-Host "`n📋 Last 10 log entries:" -ForegroundColor Cyan
        Get-Content $script:config.LogFile -Tail 10
    } else {
        Write-Host "No log file yet" -ForegroundColor Yellow
    }
}

# Main
switch ($Mode.ToLower()) {
    "watch" {
        Start-Watcher
    }
    "file" {
        # Just upload and exit (for batch files)
        Scan-And-Upload
    }
    default {
        do {
            Show-Menu
            $choice = Read-Host "Choice"
            
            switch ($choice) {
                "1" { Scan-And-Upload; Read-Host "`nPress Enter" }
                "2" { Start-Watcher }
                "3" { Show-Logs; Read-Host "`nPress Enter" }
            }
        } while ($choice -ne "Q" -and $choice -ne "q")
    }
}