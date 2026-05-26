#!/usr/bin/env pwsh
# =====================================================================
# OPS DATABASE DIRECT UPLOADER
# Standalone script for uploading files directly to Ops database
# =====================================================================

param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigFile = "upload_config.json",
    
    [Parameter(Mandatory=$false)]
    [string]$Mode = "menu",  # menu, single, batch, directory, watch
    
    [Parameter(Mandatory=$false)]
    [string]$FilePath = "",
    
    [Parameter(Mandatory=$false)]
    [string]$DirectoryPath = "",
    
    [Parameter(Mandatory=$false)]
    [string]$DocumentType = "general",
    
    [Parameter(Mandatory=$false)]
    [string]$Component = "upload_system",
    
    [Parameter(Mandatory=$false)]
    [string]$Tags = "",
    
    [Parameter(Mandatory=$false)]
    [switch]$Recurse
)

# ============= CONFIGURATION =============
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path

# Default configuration
$script:config = @{
    # API Settings
    Token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
    Endpoint = "https://miratv.club/_workers/api/series/dog_open.php"
    Database = "ops"
    Timeout = 30
    
    # Upload Settings
    UploadDir = "$scriptPath\uploads"
    ProcessedDir = "$scriptPath\uploads\processed"
    FailedDir = "$scriptPath\uploads\failed"
    AllowedExtensions = @('.txt', '.csv', '.json', '.xml', '.log', '.md', '.sql', '.ps1', '.bat', '.yml', '.yaml', '.conf', '.ini')
    MaxFileSize = 50MB  # 50MB max
    
    # Logging
    LogFile = "$scriptPath\upload_log.txt"
    VerboseLogging = $true
    
    # Auto-retry
    MaxRetries = 3
    RetryDelaySeconds = 5
}

# Load config if exists
if (Test-Path $ConfigFile) {
    try {
        $loaded = Get-Content $ConfigFile | ConvertFrom-Json
        foreach ($prop in $loaded.PSObject.Properties) {
            $script:config[$prop.Name] = $prop.Value
        }
        Write-Host "✅ Loaded configuration from $ConfigFile" -ForegroundColor Green
    } catch {
        Write-Host "⚠️ Could not load config file, using defaults" -ForegroundColor Yellow
    }
} else {
    # Save default config
    $script:config | ConvertTo-Json -Depth 3 | Out-File $ConfigFile
    Write-Host "✅ Created default configuration file: $ConfigFile" -ForegroundColor Green
}

# Create upload directories
foreach ($dir in @($script:config.UploadDir, $script:config.ProcessedDir, $script:config.FailedDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "📁 Created directory: $dir" -ForegroundColor Gray
    }
}

# ============= LOGGING FUNCTION =============
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [ConsoleColor]$Color = [ConsoleColor]::White
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Write to console with color
    Write-Host $logMessage -ForegroundColor $Color
    
    # Write to log file
    if ($script:config.VerboseLogging) {
        Add-Content -Path $script:config.LogFile -Value $logMessage
    }
}

# ============= SQL EXECUTION FUNCTION =============
function Invoke-SqlQuery {
    param(
        [string]$Sql,
        [string]$Database = $script:config.Database,
        [int]$RetryCount = 0
    )
    
    $body = @{
        token = $script:config.Token
        db = $Database
        sql = $Sql
        params = @()
    } | ConvertTo-Json
    
    try {
        $response = Invoke-RestMethod -Uri $script:config.Endpoint `
            -Method Post `
            -Body $body `
            -ContentType "application/json" `
            -TimeoutSec $script:config.Timeout
        
        return $response
    }
    catch {
        if ($RetryCount -lt $script:config.MaxRetries) {
            Write-Log "⚠️ SQL failed, retrying ($($RetryCount+1)/$($script:config.MaxRetries))..." -Level "WARN" -Color Yellow
            Start-Sleep -Seconds $script:config.RetryDelaySeconds
            return Invoke-SqlQuery -Sql $Sql -Database $Database -RetryCount ($RetryCount + 1)
        } else {
            Write-Log "❌ SQL error after $script:config.MaxRetries retries: $_" -Level "ERROR" -Color Red
            return $null
        }
    }
}

# ============= CORE UPLOAD FUNCTION =============
function Add-DocumentToOpsDatabase {
    param(
        [string]$FilePath,
        [string]$DocumentType = "general",
        [string]$Tags = "",
        [string]$Source = "direct_upload",
        [string]$Component = "upload_system",
        [string]$Domain = "document_upload"
    )
    
    Write-Log "📄 Processing: $FilePath" -Level "INFO" -Color Cyan
    
    # Validate file
    if (-not (Test-Path $FilePath)) {
        Write-Log "❌ File not found: $FilePath" -Level "ERROR" -Color Red
        return $null
    }
    
    $fileInfo = Get-Item $FilePath
    if ($fileInfo.Length -gt $script:config.MaxFileSize) {
        Write-Log "❌ File too large: $($fileInfo.Length) bytes (Max: $($script:config.MaxFileSize/1MB)MB)" -Level "ERROR" -Color Red
        return $null
    }
    
    $extension = [System.IO.Path]::GetExtension($FilePath).ToLower()
    if ($extension -notin $script:config.AllowedExtensions) {
        Write-Log "⚠️ File type $extension not in allowed list, but continuing..." -Level "WARN" -Color Yellow
    }
    
    try {
        # Read file content
        $content = Get-Content -Path $FilePath -Raw -ErrorAction Stop
        $fileName = [System.IO.Path]::GetFileName($FilePath)
        $fileSize = $fileInfo.Length
        $fileHash = Get-FileHash -Path $FilePath -Algorithm MD5 | Select-Object -ExpandProperty Hash
        
        # Escape for SQL
        $escapedContent = $content -replace "'", "''"
        $escapedFileName = $fileName -replace "'", "''"
        $escapedTags = $Tags -replace "'", "''"
        $escapedHash = $fileHash -replace "'", "''"
        
        Write-Log "   📝 Storing in ai_memory_index..." -Level "INFO" -Color Gray
        
        # 1. Store in ai_memory_index
        $memorySql = @"
INSERT INTO ai_memory_index (
    unit_type,
    domain,
    source_db,
    source_table,
    summary,
    content_ref,
    confidence,
    priority_weight,
    active,
    created_at
) VALUES (
    'document',
    '$Domain',
    'ops',
    'direct_upload',
    'File: $escapedFileName | Type: $DocumentType | Tags: $escapedTags | Hash: $escapedHash',
    '$escapedContent',
    0.95,
    1.0,
    1,
    NOW()
)
"@
        $memoryResult = Invoke-SqlQuery -Sql $memorySql
        
        if (-not $memoryResult) {
            throw "Failed to insert into ai_memory_index"
        }
        
        # 2. Log to ai_component_learning_log
        $learningSql = @"
INSERT INTO ai_component_learning_log (
    component_name,
    learning_phase,
    milestone,
    confidence,
    learned_at
) VALUES (
    '$Component',
    'document_ingestion',
    'Uploaded: $escapedFileName ($fileSize bytes)',
    0.95,
    NOW()
)
"@
        Invoke-SqlQuery -Sql $learningSql | Out-Null
        
        # 3. Log to ai_context_access_log
        $accessSql = @"
INSERT INTO ai_context_access_log (
    accessing_component,
    accessed_component,
    accessed_from_db,
    query_type,
    record_count,
    accessed_at
) VALUES (
    '$Component',
    'document_upload',
    'ops',
    'INSERT',
    1,
    NOW()
)
"@
        Invoke-SqlQuery -Sql $accessSql | Out-Null
        
        # 4. Store in ai_telemetry
        $telemetrySql = @"
INSERT INTO ai_telemetry (
    job_name,
    task,
    provider,
    route,
    confidence,
    latency_ms,
    created_at
) VALUES (
    'document_upload',
    'ingest',
    'file_system',
    '$DocumentType',
    0.95,
    0,
    NOW()
)
"@
        Invoke-SqlQuery -Sql $telemetrySql | Out-Null
        
        # 5. Log to ops_events
        $eventSql = @"
INSERT INTO ops_events (
    event_type,
    stage,
    worker,
    payload,
    event_ts,
    created_at
) VALUES (
    'document_upload',
    'ingestion',
    '$Component',
    'File: $escapedFileName | Size: $fileSize | Hash: $escapedHash',
    NOW(),
    NOW()
)
"@
        Invoke-SqlQuery -Sql $eventSql | Out-Null
        
        # 6. If script file, store in sp_intent_routing
        if ($extension -in @('.ps1', '.bat', '.sql', '.sh')) {
            $intentName = "script_$([System.IO.Path]::GetFileNameWithoutExtension($fileName))" -replace '[^a-zA-Z0-9_]', '_'
            $routingSql = @"
INSERT INTO sp_intent_routing (
    intent,
    intent_description,
    required_sp_1,
    created_at
) VALUES (
    '$intentName',
    'Auto-registered from: $escapedFileName',
    LEFT('$escapedContent', 1000),
    NOW()
)
ON DUPLICATE KEY UPDATE
    intent_description = VALUES(intent_description),
    required_sp_1 = VALUES(required_sp_1)
"@
            Invoke-SqlQuery -Sql $routingSql | Out-Null
            Write-Log "   📜 Registered as intent: $intentName" -Level "INFO" -Color Green
        }
        
        Write-Log "✅ Upload successful: $fileName" -Level "SUCCESS" -Color Green
        
        # Move file to processed folder
        $processedPath = Join-Path $script:config.ProcessedDir $fileName
        if (Test-Path $processedPath) {
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $processedPath = Join-Path $script:config.ProcessedDir "$([System.IO.Path]::GetFileNameWithoutExtension($fileName))_$timestamp$extension"
        }
        Move-Item -Path $FilePath -Destination $processedPath -Force
        Write-Log "   📦 Moved to: $processedPath" -Level "INFO" -Color Gray
        
        return @{
            FileName = $fileName
            Size = $fileSize
            Hash = $fileHash
            Success = $true
            Path = $processedPath
            Tables = @("ai_memory_index", "ai_component_learning_log", "ai_context_access_log", "ai_telemetry", "ops_events")
        }
    }
    catch {
        Write-Log "❌ Upload failed: $_" -Level "ERROR" -Color Red
        
        # Move file to failed folder
        $failedPath = Join-Path $script:config.FailedDir $fileName
        if (Test-Path $failedPath) {
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $failedPath = Join-Path $script:config.FailedDir "$([System.IO.Path]::GetFileNameWithoutExtension($fileName))_$timestamp$extension"
        }
        Move-Item -Path $FilePath -Destination $failedPath -Force
        Write-Log "   📦 Moved to: $failedPath" -Level "INFO" -Color Gray
        
        return @{
            Success = $false
            Error = $_.Exception.Message
            Path = $failedPath
        }
    }
}

# ============= BATCH UPLOAD FUNCTION =============
function Add-DocumentsToOpsDatabase {
    param(
        [string[]]$FilePaths,
        [string]$DocumentType = "general",
        [string]$Tags = "",
        [string]$Component = "upload_system"
    )
    
    Write-Log "📚 Batch uploading $($FilePaths.Count) documents..." -Level "INFO" -Color Cyan
    
    $results = @()
    $success = 0
    $failed = 0
    $startTime = Get-Date
    
    foreach ($file in $FilePaths) {
        $result = Add-DocumentToOpsDatabase -FilePath $file -DocumentType $DocumentType -Tags $Tags -Component $Component
        if ($result.Success) {
            $success++
        } else {
            $failed++
        }
        $results += $result
    }
    
    $endTime = Get-Date
    $duration = ($endTime - $startTime).TotalSeconds
    
    Write-Log "`n📊 BATCH UPLOAD SUMMARY" -Level "INFO" -Color Cyan
    Write-Log "   Duration: $([math]::Round($duration,2)) seconds" -Level "INFO" -Color White
    Write-Log "   Successful: $success" -Level "INFO" -Color Green
    Write-Log "   Failed: $failed" -Level "INFO" -Color $(if ($failed -eq 0) { "Green" } else { "Red" })
    
    # Log batch completion
    $batchSql = @"
INSERT INTO published_context_reports (
    component_name,
    report_type,
    report_content,
    report_status,
    report_version,
    published_at
) VALUES (
    '$Component',
    'batch_upload',
    'Uploaded $success files, $failed failed in $([math]::Round($duration,2))s',
    'COMPLETED',
    1,
    NOW()
)
"@
    Invoke-SqlQuery -Sql $batchSql | Out-Null
    
    return $results
}

# ============= DIRECTORY UPLOAD FUNCTION =============
function Add-DirectoryToOpsDatabase {
    param(
        [string]$DirectoryPath,
        [string]$DocumentType = "general",
        [string]$Tags = "",
        [string]$Component = "upload_system",
        [switch]$Recurse
    )
    
    Write-Log "📁 Scanning directory: $DirectoryPath" -Level "INFO" -Color Cyan
    
    if (-not (Test-Path $DirectoryPath)) {
        Write-Log "❌ Directory not found: $DirectoryPath" -Level "ERROR" -Color Red
        return $null
    }
    
    $getParams = @{
        Path = $DirectoryPath
        File = $true
        Include = $script:config.AllowedExtensions
    }
    
    if ($Recurse) {
        $getParams.Recurse = $true
        Write-Log "   Including subdirectories" -Level "INFO" -Color Gray
    }
    
    $files = Get-ChildItem @getParams
    $fileCount = ($files | Measure-Object).Count
    
    Write-Log "   Found $fileCount files to upload" -Level "INFO" -Color Gray
    
    if ($fileCount -eq 0) {
        Write-Log "⚠️ No matching files found" -Level "WARN" -Color Yellow
        return $null
    }
    
    $results = Add-DocumentsToOpsDatabase -FilePaths $files.FullName -DocumentType $DocumentType -Tags $Tags -Component $Component
    
    return $results
}

# ============= SEARCH FUNCTION =============
function Search-OpsDocuments {
    param(
        [string]$Keyword,
        [string]$Domain = $null
    )
    
    Write-Log "🔍 Searching for: $Keyword" -Level "INFO" -Color Cyan
    
    $escapedKeyword = $Keyword -replace "'", "''"
    
    # Search in ai_memory_index
    $searchSql = @"
SELECT 
    id,
    unit_type,
    domain,
    summary,
    LEFT(content_ref, 200) as content_preview,
    confidence,
    created_at
FROM ai_memory_index
WHERE content_ref LIKE '%$escapedKeyword%'
   OR summary LIKE '%$escapedKeyword%'
ORDER BY created_at DESC
LIMIT 20
"@
    
    if ($Domain) {
        $searchSql = @"
SELECT 
    id,
    unit_type,
    domain,
    summary,
    LEFT(content_ref, 200) as content_preview,
    confidence,
    created_at
FROM ai_memory_index
WHERE domain = '$Domain'
  AND (content_ref LIKE '%$escapedKeyword%' OR summary LIKE '%$escapedKeyword%')
ORDER BY created_at DESC
LIMIT 20
"@
    }
    
    $results = Invoke-SqlQuery -Sql $searchSql
    
    if ($results -and $results.PSObject.Properties.Name -contains "rows" -and $results.rows.Count -gt 0) {
        Write-Log "📋 Found $($results.rows.Count) matches:" -Level "INFO" -Color Green
        
        $index = 1
        foreach ($row in $results.rows) {
            Write-Host "   $index. [$($row.created_at)] $($row.summary)" -ForegroundColor White
            $index++
        }
        
        return $results.rows
    } else {
        Write-Log "No documents found matching '$Keyword'" -Level "INFO" -Color Yellow
        return $null
    }
}

# ============= STATISTICS FUNCTION =============
function Get-OpsUploadStats {
    Write-Log "📊 Generating upload statistics..." -Level "INFO" -Color Cyan
    
    # Count documents
    $countSql = @"
SELECT 
    COUNT(*) as total_documents,
    COUNT(DISTINCT domain) as unique_domains,
    AVG(LENGTH(content_ref)) as avg_size_bytes,
    MIN(created_at) as oldest_document,
    MAX(created_at) as newest_document
FROM ai_memory_index
WHERE unit_type = 'document'
"@
    $stats = Invoke-SqlQuery -Sql $countSql
    
    # Recent uploads
    $recentSql = @"
SELECT 
    id,
    domain,
    summary,
    created_at
FROM ai_memory_index
WHERE unit_type = 'document'
ORDER BY created_at DESC
LIMIT 10
"@
    $recent = Invoke-SqlQuery -Sql $recentSql
    
    # Daily stats
    $dailySql = @"
SELECT 
    DATE(created_at) as upload_date,
    COUNT(*) as upload_count,
    SUM(LENGTH(content_ref)) as total_bytes
FROM ai_memory_index
WHERE unit_type = 'document'
  AND created_at > DATE_SUB(NOW(), INTERVAL 7 DAY)
GROUP BY DATE(created_at)
ORDER BY upload_date DESC
"@
    $daily = Invoke-SqlQuery -Sql $dailySql
    
    Write-Host "`n📈 DOCUMENT STATISTICS" -ForegroundColor Cyan
    Write-Host "====================="
    
    if ($stats -and $stats.PSObject.Properties.Name -contains "rows" -and $stats.rows.Count -gt 0) {
        $row = $stats.rows[0]
        Write-Host "Total Documents: $($row.total_documents)" -ForegroundColor White
        Write-Host "Unique Domains: $($row.unique_domains)" -ForegroundColor White
        Write-Host "Average Size: $([math]::Round($row.avg_size_bytes / 1KB, 2)) KB" -ForegroundColor White
        Write-Host "Date Range: $($row.oldest_document) to $($row.newest_document)" -ForegroundColor White
    }
    
    Write-Host "`n📋 RECENT UPLOADS" -ForegroundColor Yellow
    if ($recent -and $recent.PSObject.Properties.Name -contains "rows" -and $recent.rows.Count -gt 0) {
        foreach ($row in $recent.rows) {
            Write-Host "   [$($row.created_at)] $($row.domain): $($row.summary)" -ForegroundColor Gray
        }
    }
    
    Write-Host "`n📊 LAST 7 DAYS" -ForegroundColor Yellow
    if ($daily -and $daily.PSObject.Properties.Name -contains "rows" -and $daily.rows.Count -gt 0) {
        foreach ($row in $daily.rows) {
            Write-Host "   $($row.upload_date): $($row.upload_count) files, $([math]::Round($row.total_bytes / 1KB, 2)) KB" -ForegroundColor Gray
        }
    }
}

# ============= FOLDER WATCHER =============
function Start-FolderWatcher {
    param(
        [string]$WatchPath,
        [string]$DocumentType = "watched",
        [string]$Tags = "",
        [string]$Component = "watcher"
    )
    
    Write-Log "👁️ Starting folder watcher for: $WatchPath" -Level "INFO" -Color Cyan
    Write-Log "   Press Ctrl+C to stop watching" -Level "INFO" -Color Yellow
    
    if (-not (Test-Path $WatchPath)) {
        New-Item -ItemType Directory -Path $WatchPath -Force | Out-Null
        Write-Log "   Created watch directory: $WatchPath" -Level "INFO" -Color Gray
    }
    
    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $WatchPath
    $watcher.Filter = "*.*"
    $watcher.IncludeSubdirectories = $false
    $watcher.EnableRaisingEvents = $true
    
    $action = {
        $path = $Event.SourceEventArgs.FullPath
        $changeType = $Event.SourceEventArgs.ChangeType
        
        if ($changeType -eq 'Created') {
            # Wait a moment for file to be fully written
            Start-Sleep -Seconds 2
            
            $extension = [System.IO.Path]::GetExtension($path).ToLower()
            if ($extension -in $script:config.AllowedExtensions) {
                Write-Log "📥 New file detected: $path" -Level "INFO" -Color Magenta
                Add-DocumentToOpsDatabase -FilePath $path -DocumentType $using:DocumentType -Tags $using:Tags -Component $using:Component
            }
        }
    }
    
    Register-ObjectEvent -InputObject $watcher -EventName "Created" -Action $action | Out-Null
    
    try {
        Write-Log "Watcher active. Monitoring for new files..." -Level "INFO" -Color Green
        while ($true) {
            Start-Sleep -Seconds 5
        }
    }
    finally {
        $watcher.EnableRaisingEvents = $false
        $watcher.Dispose()
        Get-EventSubscriber | Unregister-Event
        Write-Log "Folder watcher stopped" -Level "INFO" -Color Yellow
    }
}

# ============= MENU SYSTEM =============
function Show-Menu {
    Clear-Host
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║     📤 OPS DATABASE DIRECT UPLOADER                      ║" -ForegroundColor Cyan
    Write-Host "║     Standalone Upload Tool                               ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "📁 Upload Directory: $($script:config.UploadDir)" -ForegroundColor Yellow
    Write-Host "📁 Processed: $($script:config.ProcessedDir)" -ForegroundColor Gray
    Write-Host "📁 Failed: $($script:config.FailedDir)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "🎮 COMMANDS" -ForegroundColor Magenta
    Write-Host "==========="
    Write-Host ""
    Write-Host "  1) Upload Single Document"
    Write-Host "  2) Upload Multiple Documents"
    Write-Host "  3) Upload Entire Directory"
    Write-Host "  4) Upload Directory with Subdirectories"
    Write-Host "  5) Search Uploaded Documents"
    Write-Host "  6) View Upload Statistics"
    Write-Host "  7) Start Folder Watcher (Auto-Upload)"
    Write-Host "  8) View Configuration"
    Write-Host "  9) Edit Configuration"
    Write-Host ""
    Write-Host "  Q) Quit"
    Write-Host ""
}

# ============= MAIN EXECUTION =============
function Main {
    # Check mode parameter
    switch ($Mode.ToLower()) {
        "single" {
            if ($FilePath) {
                Add-DocumentToOpsDatabase -FilePath $FilePath -DocumentType $DocumentType -Tags $Tags -Component $Component
            } else {
                Write-Host "❌ FilePath required for single mode" -ForegroundColor Red
            }
            return
        }
        "batch" {
            if ($FilePath -and (Test-Path $FilePath)) {
                $files = Get-Content $FilePath
                Add-DocumentsToOpsDatabase -FilePaths $files -DocumentType $DocumentType -Tags $Tags -Component $Component
            } else {
                Write-Host "❌ Valid file list required for batch mode" -ForegroundColor Red
            }
            return
        }
        "directory" {
            if ($DirectoryPath) {
                Add-DirectoryToOpsDatabase -DirectoryPath $DirectoryPath -DocumentType $DocumentType -Tags $Tags -Component $Component -Recurse:$Recurse
            } else {
                Write-Host "❌ DirectoryPath required for directory mode" -ForegroundColor Red
            }
            return
        }
        "watch" {
            if ($DirectoryPath) {
                Start-FolderWatcher -WatchPath $DirectoryPath -DocumentType $DocumentType -Tags $Tags -Component $Component
            } else {
                Write-Host "❌ DirectoryPath required for watch mode" -ForegroundColor Red
            }
            return
        }
    }
    
    # Interactive menu mode
    do {
        Show-Menu
        $choice = Read-Host "Enter choice"
        
        switch ($choice) {
            "1" {
                $file = Read-Host "Enter file path"
                if (Test-Path $file) {
                    $type = Read-Host "Document type [general]"
                    if ([string]::IsNullOrWhiteSpace($type)) { $type = "general" }
                    $tags = Read-Host "Tags (comma-separated) [optional]"
                    Add-DocumentToOpsDatabase -FilePath $file -DocumentType $type -Tags $tags
                } else {
                    Write-Host "❌ File not found" -ForegroundColor Red
                }
                Read-Host "`nPress Enter to continue"
            }
            "2" {
                Write-Host "Enter file paths (one per line, empty line to finish):" -ForegroundColor Yellow
                $files = @()
                while ($true) {
                    $file = Read-Host "File path"
                    if ([string]::IsNullOrWhiteSpace($file)) { break }
                    if (Test-Path $file) {
                        $files += $file
                    } else {
                        Write-Host "⚠️ File not found, skipping: $file" -ForegroundColor Yellow
                    }
                }
                if ($files.Count -gt 0) {
                    $type = Read-Host "Document type [general]"
                    if ([string]::IsNullOrWhiteSpace($type)) { $type = "general" }
                    $tags = Read-Host "Tags (comma-separated) [optional]"
                    Add-DocumentsToOpsDatabase -FilePaths $files -DocumentType $type -Tags $tags
                }
                Read-Host "`nPress Enter to continue"
            }
            "3" {
                $dir = Read-Host "Enter directory path"
                if (Test-Path $dir) {
                    $type = Read-Host "Document type [general]"
                    if ([string]::IsNullOrWhiteSpace($type)) { $type = "general" }
                    $tags = Read-Host "Tags (comma-separated) [optional]"
                    Add-DirectoryToOpsDatabase -DirectoryPath $dir -DocumentType $type -Tags $tags
                } else {
                    Write-Host "❌ Directory not found" -ForegroundColor Red
                }
                Read-Host "`nPress Enter to continue"
            }
            "4" {
                $dir = Read-Host "Enter directory path"
                if (Test-Path $dir) {
                    $type = Read-Host "Document type [general]"
                    if ([string]::IsNullOrWhiteSpace($type)) { $type = "general" }
                    $tags = Read-Host "Tags (comma-separated) [optional]"
                    Add-DirectoryToOpsDatabase -DirectoryPath $dir -DocumentType $type -Tags $tags -Recurse
                } else {
                    Write-Host "❌ Directory not found" -ForegroundColor Red
                }
                Read-Host "`nPress Enter to continue"
            }
            "5" {
                $keyword = Read-Host "Enter search keyword"
                $domain = Read-Host "Filter by domain [optional]"
                if ([string]::IsNullOrWhiteSpace($domain)) {
                    Search-OpsDocuments -Keyword $keyword
                } else {
                    Search-OpsDocuments -Keyword $keyword -Domain $domain
                }
                Read-Host "`nPress Enter to continue"
            }
            "6" {
                Get-OpsUploadStats
                Read-Host "`nPress Enter to continue"
            }
            "7" {
                $dir = Read-Host "Enter directory to watch"
                $type = Read-Host "Document type for watched files [watched]"
                if ([string]::IsNullOrWhiteSpace($type)) { $type = "watched" }
                $tags = Read-Host "Tags (comma-separated) [optional]"
                Start-FolderWatcher -WatchPath $dir -DocumentType $type -Tags $tags
            }
            "8" {
                Write-Host "`n⚙️ CURRENT CONFIGURATION" -ForegroundColor Cyan
                $script:config | ConvertTo-Json | Write-Host
                Read-Host "`nPress Enter to continue"
            }
            "9" {
                $newConfig = Read-Host "Edit config file? (Y/N)"
                if ($newConfig -eq "Y") {
                    notepad $ConfigFile
                }
            }
        }
    } while ($choice -ne "Q" -and $choice -ne "q")
}

# Run main function
Main