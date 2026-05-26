#!/usr/bin/env pwsh
# Simple File Organizer - Moves files to correct spool directories

# Source directory where your files are currently located
$sourceDir = "C:\miratv_ingest\downloads"  # CHANGE THIS to where your files are

# Target spool directories
$spoolDirs = @{
    "ops" = "C:\miratv_ingest\ops_spool"
    "lake" = "C:\miratv_ingest\lake_spool" 
    "igm" = "C:\miratv_ingest\igm_spool"
}

Write-Host "`n" + "="*50 -ForegroundColor Cyan
Write-Host "📁 SPOOL FILE ORGANIZER" -ForegroundColor Cyan
Write-Host "="*50 -ForegroundColor Cyan
Write-Host "Source: $sourceDir" -ForegroundColor Yellow
Write-Host ""

# Create spool directories if they don't exist
foreach ($dir in $spoolDirs.Values) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "✅ Created: $dir" -ForegroundColor Green
    }
}

# Check if source directory exists
if (-not (Test-Path $sourceDir)) {
    Write-Host "❌ Source directory not found: $sourceDir" -ForegroundColor Red
    Write-Host "Please edit the script and change `$sourceDir to your files location" -ForegroundColor Yellow
    exit
}

# Get all files from source directory
$allFiles = Get-ChildItem -Path $sourceDir -File

if ($allFiles.Count -eq 0) {
    Write-Host "ℹ️ No files found in source directory" -ForegroundColor Yellow
    exit
}

Write-Host "📊 Found $($allFiles.Count) files in source directory" -ForegroundColor Cyan
Write-Host ""

$moved = 0
$skipped = 0

# Simple pattern matching - you can adjust these rules
foreach ($file in $allFiles) {
    $fileName = $file.Name.ToLower()
    $destination = $null
    
    # Rule 1: Check filename for keywords
    if ($fileName -match "ops|loop|series|pipeline|runner|master") {
        $destination = $spoolDirs["ops"]
        $type = "OPS"
    }
    elseif ($fileName -match "lake|knowledge|signal|embedding|vector") {
        $destination = $spoolDirs["lake"]
        $type = "LAKE"
    }
    elseif ($fileName -match "igm|governance|rule|attest|canon") {
        $destination = $spoolDirs["igm"]
        $type = "IGM"
    }
    # Rule 2: Check file extension
    elseif ($fileName -match "\.ops$|\.opspool$") {
        $destination = $spoolDirs["ops"]
        $type = "OPS"
    }
    elseif ($fileName -match "\.lake$|\.lakespool$") {
        $destination = $spoolDirs["lake"]
        $type = "LAKE"
    }
    elseif ($fileName -match "\.igm$|\.igmspool$") {
        $destination = $spoolDirs["igm"]
        $type = "IGM"
    }
    # Rule 3: Default to OPS if no match
    else {
        $destination = $spoolDirs["ops"]
        $type = "OPS (default)"
    }
    
    if ($destination) {
        $destPath = Join-Path $destination $file.Name
        
        # Check if file already exists in destination
        if (Test-Path $destPath) {
            Write-Host "⚠️ Skipping $($file.Name) - already exists in $type" -ForegroundColor Yellow
            $skipped++
        }
        else {
            Copy-Item -Path $file.FullName -Destination $destPath
            Write-Host "✅ Copied $($file.Name) → $type spool" -ForegroundColor Green
            $moved++
        }
    }
}

Write-Host ""
Write-Host "="*50 -ForegroundColor Cyan
Write-Host "📊 SUMMARY" -ForegroundColor Cyan
Write-Host "="*50 -ForegroundColor Cyan
Write-Host "Files copied: $moved" -ForegroundColor Green
Write-Host "Files skipped: $skipped" -ForegroundColor Yellow
Write-Host ""
Write-Host "📍 Destination directories:" -ForegroundColor White
Write-Host "  OPS:  $($spoolDirs["ops"])"
Write-Host "  LAKE: $($spoolDirs["lake"])"
Write-Host "  IGM:  $($spoolDirs["igm"])"
Write-Host "="*50