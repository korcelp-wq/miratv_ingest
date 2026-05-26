#!/usr/bin/env pwsh
# Enhanced Spool Uploader - Handles .spool, .txt, and .log files

$token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$cviEndpoint = "https://miratv.club/_workers/api/series/dog_open.php"

# Directories to check
$spoolDirs = @{
    "ops_spool" = @{
        path = "C:\miratv_ingest\ops_spool"
        db = "xpdgxfsp_ops"
        table = "ops_events"
        description = "OPS Events (Pipeline operations)"
    }
    "lake_spool" = @{
        path = "C:\miratv_ingest\lake_spool"
        db = "xpdgxfsp_lake_vector"
        table = "lake_signals"
        description = "LAKE Events (Knowledge signals)"
    }
    "igm_spool" = @{
        path = "C:\miratv_ingest\igm_spool"
        db = "xpdgxfsp_i_m_g_vector_context"
        table = "igm_raw_governance_events"
        description = "IGM Events (Governance attestations)"
    }
}

# File extensions to look for
$validExtensions = @("*.spool", "*.txt", "*.log")

# Function to upload a spool file
function Upload-SpoolFile {
    param(
        [string]$FilePath,
        [string]$TargetDb,
        [string]$TargetTable
    )
    
    Write-Host "    📄 Processing: $FilePath" -ForegroundColor Gray
    
    # Read the file content
    $content = Get-Content $FilePath -Raw
    $fileName = Split-Path $FilePath -Leaf
    
    # Parse each line (skip empty lines)
    $lines = $content -split "`n" | Where-Object { $_.Trim() -ne "" }
    $uploaded = 0
    $skipped = 0
    
    Write-Host "      📊 Found $($lines.Count) lines in $fileName" -ForegroundColor Gray
    
    foreach ($line in $lines) {
        # Escape single quotes for SQL
        $escapedLine = $line -replace "'", "''"
        
        # Determine which table to insert into based on content patterns
        # This helps route correctly even if files are in wrong directories
        $targetTable = $TargetTable
        
        # You can add smart routing based on content if needed
        if ($line -match "LOOP_START|SERIES_RUN|JOB_|PIPELINE") {
            # Ops event - force to ops table
            $targetTable = "ops_events"
        }
        elseif ($line -match "SERIES_LOCK|SUCCESS|FAILURE|EMBEDDING") {
            # Lake event - force to lake_signals
            $targetTable = "lake_signals"
        }
        elseif ($line -match "CANON|RULE|GOVERNANCE|ATTEST") {
            # IGM event - force to igm table
            $targetTable = "igm_raw_governance_events"
        }
        
        # Insert into appropriate database
        $sql = "INSERT INTO $targetTable (event_line, file_name, created_at) VALUES ('$escapedLine', '$fileName', NOW())"
        
        # Execute the insert
        $body = @{
            token = $token
            db = $TargetDb
            sql = $sql
            params = @()
        } | ConvertTo-Json
        
        try {
            Invoke-RestMethod -Uri $cviEndpoint -Method Post -Body $body -ContentType "application/json" -TimeoutSec 10 -ErrorAction Stop | Out-Null
            $uploaded++
        }
        catch {
            Write-Host "      ❌ Failed to upload line: $_" -ForegroundColor Red
            $skipped++
        }
    }
    
    Write-Host "      ✅ Uploaded: $uploaded lines | Skipped: $skipped" -ForegroundColor Green
    return $uploaded
}

# Function to get all spool files with valid extensions
function Get-SpoolFiles {
    param([string]$Directory)
    
    $allFiles = @()
    foreach ($ext in $validExtensions) {
        $files = Get-ChildItem -Path $Directory -Filter $ext -ErrorAction SilentlyContinue
        $allFiles += $files
    }
    return $allFiles | Sort-Object LastWriteTime
}

# Main script
Write-Host "`n" + "="*60 -ForegroundColor Cyan
Write-Host "📤 ENHANCED SPOOL UPLOADER" -ForegroundColor Cyan
Write-Host "="*60 -ForegroundColor Cyan
Write-Host "Looking for files: .spool, .txt, .log" -ForegroundColor Yellow
Write-Host ""

$totalUploaded = 0
$totalFiles = 0
$totalLines = 0

foreach ($dirName in $spoolDirs.Keys) {
    $dirInfo = $spoolDirs[$dirName]
    $dirPath = $dirInfo.path
    
    Write-Host "📂 $($dirInfo.description):" -ForegroundColor Yellow
    Write-Host "   Path: $dirPath" -ForegroundColor Gray
    Write-Host "   Target DB: $($dirInfo.db)" -ForegroundColor Gray
    
    # Check if directory exists
    if (-not (Test-Path $dirPath)) {
        Write-Host "   ⚠️ Directory does not exist. Creating it..." -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $dirPath -Force | Out-Null
        Write-Host "   ✅ Created directory" -ForegroundColor Green
        continue
    }
    
    # Get all spool files with valid extensions
    $files = Get-SpoolFiles -Directory $dirPath
    
    if ($files.Count -eq 0) {
        Write-Host "   ℹ️ No spool files found" -ForegroundColor Gray
        continue
    }
    
    Write-Host "   📊 Found $($files.Count) files:" -ForegroundColor Cyan
    foreach ($file in $files) {
        Write-Host "      • $($file.Name) ($($file.Length) bytes)" -ForegroundColor Gray
    }
    
    $dirUploaded = 0
    $dirLines = 0
    
    foreach ($file in $files) {
        $linesInFile = (Get-Content $file.FullName | Where-Object { $_.Trim() -ne "" }).Count
        $uploaded = Upload-SpoolFile -FilePath $file.FullName -TargetDb $dirInfo.db -TargetTable $dirInfo.table
        $dirUploaded += $uploaded
        $dirLines += $linesInFile
        
        # Create archive directory if it doesn't exist
        $archiveDir = Join-Path $dirPath "processed"
        if (-not (Test-Path $archiveDir)) {
            New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
        }
        
        # Move processed file to archive with timestamp
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $archivePath = Join-Path $archiveDir "$($file.BaseName)_$timestamp$($file.Extension)"
        Move-Item -Path $file.FullName -Destination $archivePath -Force
        Write-Host "   ✅ Archived: $($file.Name) → processed/" -ForegroundColor Green
    }
    
    Write-Host "   ✅ Uploaded $dirUploaded lines from $($files.Count) files" -ForegroundColor Green
    $totalUploaded += $dirUploaded
    $totalFiles += $files.Count
    $totalLines += $dirLines
}

# Summary
Write-Host "`n" + "="*60 -ForegroundColor Cyan
Write-Host "📊 UPLOAD SUMMARY" -ForegroundColor Cyan
Write-Host "="*60 -ForegroundColor Cyan
Write-Host "Files processed: $totalFiles" -ForegroundColor White
Write-Host "Total lines found: $totalLines" -ForegroundColor Yellow
Write-Host "Lines uploaded: $totalUploaded" -ForegroundColor Green
Write-Host ""
Write-Host "📁 Spool directories monitored:" -ForegroundColor Yellow
foreach ($dirName in $spoolDirs.Keys) {
    $dirInfo = $spoolDirs[$dirName]
    Write-Host "  • $($dirInfo.description)" -ForegroundColor Gray
    Write-Host "    Path: $($dirInfo.path)" -ForegroundColor Gray
    Write-Host "    DB: $($dirInfo.db)" -ForegroundColor Gray
}
Write-Host "="*60

# Optional: Create a watcher job for continuous monitoring
Write-Host ""
$choice = Read-Host "Run continuously as a watcher? (y/n)"
if ($choice -eq 'y') {
    Write-Host "Starting continuous watcher (Ctrl+C to stop)..." -ForegroundColor Cyan
    while ($true) {
        Clear-Host
        & $PSCommandPath
        Write-Host "`nWaiting 60 seconds before next scan..." -ForegroundColor Yellow
        Start-Sleep -Seconds 60
    }
}