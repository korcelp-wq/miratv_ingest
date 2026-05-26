#!/usr/bin/env pwsh
# Auto Ingester - Finds and registers all script files (PS1, BAT, PHP) - FIXED VERSION

$token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$endpoint = "https://miratv.club/_workers/api/series/dog_open.php"

# Directories to scan
$directories = @(
    "C:\miratv_ingest",
    "C:\Android_Projects\MiraTV_project_PHASES_1_8",
    "C:\MiraTV_infrastructure",
    "C:\Users\Korce\Downloads\public_html (2)",
    "C:\MIRATV"
)

# File types to process
$fileTypes = @{
    ".ps1" = @{ type = "powershell"; system = "powershell" }
    ".bat" = @{ type = "batch"; system = "batch" }
    ".php" = @{ type = "php"; system = "php" }
    ".kt" = @{ type = "kotlin"; application = "kotlin" }
    ".xml" = @{ type = "xml"; application = "xml" }
}

Write-Host "🔍 Universal File Ingester Starting..." -ForegroundColor Cyan
Write-Host "=======================================" -ForegroundColor Cyan

# Function to run SQL
function Invoke-SQL {
    param([string]$Sql, [string]$Db = "pcde_memory")
    
    $body = @{
        token = $token
        db = $Db
        sql = $Sql
        params = @()
    } | ConvertTo-Json
    
    try {
        return Invoke-RestMethod -Uri $endpoint -Method Post -Body $body -ContentType "application/json"
    }
    catch {
        Write-Host "  ❌ SQL Error: $_" -ForegroundColor Red
        return $null
    }
}

# Function to escape text for SQL
function Escape-SQL {
    param([string]$Text)
    if (-not $Text) { return "" }
    return ($Text -replace "'", "''" -replace "`r", " " -replace "`n", " ").Trim()
}

# Function to safely read file content (FIXED - removed incompatible parameters)
function Get-FileContentSafely {
    param([string]$Path)
    
    try {
        # Just read the first 50 lines without using -TotalCount with -Raw
        $lines = Get-Content -Path $Path -TotalCount 50 -ErrorAction Stop
        return $lines -join "`n"
    }
    catch {
        return ""
    }
}

# Function to determine script type from path and content
function Get-ScriptType {
    param([string]$Path, [string]$Content, [string]$Extension)
    
    $fileName = Split-Path $Path -Leaf
    
    # By path
    if ($Path -match "\\workers\\") { return "worker" }
    if ($Path -match "\\triggers\\") { return "trigger" }
    if ($Path -match "\\modules\\") { return "module" }
    if ($Path -match "\\spine\\") { return "orchestrator" }
    if ($Path -match "\\api\\") { return "api" }
    if ($Path -match "\\ingest\\") { return "ingest" }
    
    # By filename
    if ($fileName -match "test") { return "test" }
    if ($fileName -match "install|setup") { return "setup" }
    if ($fileName -match "config") { return "config" }
    
    # By extension
    if ($Extension -eq ".php") {
        if ($Content -match "class\s+\w+") { return "class" }
        if ($Content -match "function\s+\w+") { return "library" }
        return "web"
    }
    
    return "utility"
}

# Function to determine domain
function Get-Domain {
    param([string]$Path, [string]$Content)
    
    if ($Content -match "series|grinder|episode|season|normalize|vod|live") { return "ingest" }
    if ($Content -match "governance|rule|igm|attest|policy") { return "governance" }
    if ($Content -match "telemetry|log|monitor|metric|watch") { return "telemetry" }
    if ($Content -match "api|endpoint|gateway|router|request") { return "api" }
    if ($Path -match "cvi|dog_open|callosum") { return "cvi" }
    if ($Content -match "activation|auth|login|session|user") { return "auth" }
    if ($Content -match "database|db|sql|query") { return "database" }
    if ($Content -match "html|css|javascript|ui|display") { return "ui" }
    
    return "unknown"
}

# Function to extract description based on file type
function Get-Description {
    param([string]$Content, [string]$Extension)
    
    switch ($Extension) {
        ".ps1" {
            if ($Content -match "<#(.*?)#>") {
                return $matches[1].Trim()
            }
        }
        ".php" {
            # Look for PHP docblocks
            if ($Content -match "/\*\*(.*?)\*/") {
                return $matches[1] -replace "\*", "" -replace "\s+", " " -replace "^\s+|\s+$", ""
            }
            # Look for single line comments at top
            if ($Content -match "^<\?php\s*//(.*?)[\r\n]") {
                return $matches[1].Trim()
            }
        }
        ".bat" {
            # Look for REM comments at top
            if ($Content -match "^@echo off\s*REM(.*?)[\r\n]") {
                return $matches[1].Trim()
            }
            if ($Content -match "^::(.*?)[\r\n]") {
                return $matches[1].Trim()
            }
        }
    }
    
    return ""
}

# Find all files by type
Write-Host "`n📂 Scanning directories..." -ForegroundColor Yellow

$allFiles = @{}
foreach ($ext in $fileTypes.Keys) {
    $allFiles[$ext] = @()
}

foreach ($dir in $directories) {
    if (Test-Path $dir) {
        foreach ($ext in $fileTypes.Keys) {
            $files = Get-ChildItem -Path $dir -Recurse -Filter "*$ext" -ErrorAction SilentlyContinue
            $allFiles[$ext] += $files
        }
    }
}

# Summary counts
Write-Host "`n📊 FILE COUNTS:" -ForegroundColor Green
foreach ($ext in $fileTypes.Keys) {
    $type = $fileTypes[$ext].type
    Write-Host "  $type ($ext): $($allFiles[$ext].Count)" -ForegroundColor Cyan
}
$totalFiles = ($allFiles.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
Write-Host "  TOTAL: $totalFiles files" -ForegroundColor Magenta

# Process each file type
$processed = 0
$skipped = 0
$errors = 0
$fileGroups = @{}

foreach ($ext in $fileTypes.Keys) {
    $typeInfo = $fileTypes[$ext]
    $files = $allFiles[$ext]
    
    Write-Host "`n🔧 Processing $($typeInfo.type) files ($ext)..." -ForegroundColor Yellow
    
    $counter = 0
    foreach ($file in $files) {
        $fileName = $file.Name
        $filePath = $file.FullName
        $fileBase = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
        
        $counter++
        Write-Progress -Activity "Processing $($typeInfo.type) Files" -Status "$fileName ($counter of $($files.Count))" -PercentComplete (($counter / $files.Count) * 100)
        
        try {
            # Read file content safely
            $content = Get-FileContentSafely -Path $filePath
            
            # Extract description
            $description = Get-Description -Content $content -Extension $ext
            
            # Determine script type and domain
            $scriptType = Get-ScriptType -Path $filePath -Content $content -Extension $ext
            $domain = Get-Domain -Path $filePath -Content $content
            
            # Check if already exists
            $escapedPath = Escape-SQL -Text $filePath
            $checkSql = "SELECT COUNT(*) as count FROM pcde_procedure_registry WHERE source_path = '$escapedPath'"
            $check = Invoke-SQL -Sql $checkSql
            
            if ($check -and $check.rows -and $check.rows[0].count -gt 0) {
                Write-Host "  ⏭️ Already exists: $fileName" -ForegroundColor Gray
                $skipped++
                continue
            }
            
            # Prepare SQL
            $escapedName = Escape-SQL -Text $fileBase
            $escapedDesc = Escape-SQL -Text $description
            
            $descText = if ($escapedDesc) { $escapedDesc } else { "No description" }
            
            $sql = @"
INSERT INTO pcde_procedure_registry 
(procedure_name, domain, procedure_type, source_system, source_path, description, why_it_exists, active, created_at)
VALUES 
('$escapedName', '$domain', '$scriptType', '$($typeInfo.system)', '$escapedPath', '$descText', 'Auto-discovered during file scan', 1, NOW())
"@
            
            $result = Invoke-SQL -Sql $sql
            if ($result -and $result.affected -and $result.affected -gt 0) {
                Write-Host "  ✅ Added: $fileName [$domain/$scriptType]" -ForegroundColor Green
                
                # Group by base name for relation tracking
                $baseGroup = $fileBase -replace "_\d+$", ""  # Remove version/step numbers
                if (-not $fileGroups[$baseGroup]) {
                    $fileGroups[$baseGroup] = @()
                }
                $fileGroups[$baseGroup] += @{
                    Path = $filePath
                    Type = $typeInfo.type
                    Name = $fileName
                }
                
                $processed++
            } else {
                Write-Host "  ❌ Failed: $fileName" -ForegroundColor Red
                $errors++
            }
        }
        catch {
            Write-Host "  ❌ Error processing $fileName : $_" -ForegroundColor Red
            $errors++
        }
    }
}

# Create relations between grouped files
Write-Host "`n🔗 Creating relations between related scripts..." -ForegroundColor Yellow

$relationsAdded = 0
foreach ($group in $fileGroups.Keys) {
    $files = $fileGroups[$group]
    if ($files.Count -gt 1) {
        Write-Host "  Group: $group ($($files.Count) files)" -ForegroundColor Gray
        
        # Get procedure IDs for this group
        $procIds = @{}
        foreach ($fileInfo in $files) {
            $escapedPath = Escape-SQL -Text $fileInfo.Path
            $getIdSql = "SELECT procedure_id FROM pcde_procedure_registry WHERE source_path = '$escapedPath'"
            $idResult = Invoke-SQL -Sql $getIdSql
            
            if ($idResult -and $idResult.rows -and $idResult.rows.Count -gt 0) {
                $procId = $idResult.rows[0].procedure_id
                $procIds[$fileInfo.Path] = $procId
            }
        }
        
        # Link files in the group
        $pathList = $procIds.Keys | ForEach-Object { $_ }
        for ($i = 0; $i -lt $pathList.Count; $i++) {
            for ($j = $i + 1; $j -lt $pathList.Count; $j++) {
                $id1 = $procIds[$pathList[$i]]
                $id2 = $procIds[$pathList[$j]]
                
                if ($id1 -and $id2) {
                    $relSql = @"
INSERT INTO pcde_procedure_relations (procedure_id, relation_type, relation_target, notes)
VALUES ($id1, 'related_script', 'procedure:$id2', 'Part of $group script family')
ON DUPLICATE KEY UPDATE notes = notes
"@
                    $relResult = Invoke-SQL -Sql $relSql
                    if ($relResult -and $relResult.affected) { $relationsAdded++ }
                }
            }
        }
    }
}

# Summary
Write-Host "`n" + "="*60 -ForegroundColor Cyan
Write-Host "📋 INGESTION COMPLETE" -ForegroundColor Cyan
Write-Host "="*60 -ForegroundColor Cyan
Write-Host "Total files found: $totalFiles" -ForegroundColor White
Write-Host "Successfully added: $processed" -ForegroundColor Green
Write-Host "Already existed: $skipped" -ForegroundColor Yellow
Write-Host "Errors: $errors" -ForegroundColor Red
Write-Host "Relations created: $relationsAdded" -ForegroundColor Magenta
Write-Host "="*60

# Show recent additions
Write-Host "`n🔍 Most recent additions:" -ForegroundColor Cyan
$recentSql = "SELECT procedure_id, procedure_name, domain, procedure_type, source_system, created_at FROM pcde_procedure_registry ORDER BY procedure_id DESC LIMIT 10"
$recent = Invoke-SQL -Sql $recentSql
if ($recent -and $recent.rows) {
    $recent.rows | Format-Table -AutoSize
}