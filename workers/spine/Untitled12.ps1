#!/usr/bin/env pwsh
# Auto Ingest PS1 Files - Finds and registers all PowerShell scripts

$token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$endpoint = "https://miratv.club/_workers/api/series/dog_open.php"

# Directories to scan
$directories = @(
    "C:\miratv_ingest",
    "C:\Android_Projects\MiraTV_project_PHASES_1_8",
    "C:\MiraTV_infrastructure"
)

Write-Host "🔍 Auto PS1 Ingester Starting..." -ForegroundColor Cyan
Write-Host "=================================" -ForegroundColor Cyan

# Function to run SQL
function Invoke-SQL {
    param([string]$Sql)
    
    $body = @{
        token = $token
        db = "pcde_memory"
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

# Find all PS1 files
Write-Host "`n📂 Scanning directories..." -ForegroundColor Yellow
$allFiles = @()

foreach ($dir in $directories) {
    if (Test-Path $dir) {
        $files = Get-ChildItem -Path $dir -Recurse -Filter "*.ps1" -ErrorAction SilentlyContinue
        $allFiles += $files
        Write-Host "  Found $($files.Count) in $dir" -ForegroundColor Gray
    }
}

Write-Host "`n📊 TOTAL PS1 FILES FOUND: $($allFiles.Count)" -ForegroundColor Green

# Process each file
$processed = 0
$skipped = 0
$errors = 0
$fileGroups = @{}

foreach ($file in $allFiles) {
    $fileName = $file.Name
    $filePath = $file.FullName
    $fileBase = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    
    Write-Progress -Activity "Processing PS1 Files" -Status $fileName -PercentComplete (($processed / $allFiles.Count) * 100)
    
    try {
        # Read file content
        $content = Get-Content $filePath -Raw -ErrorAction Stop
        
        # Extract description from comment block
        $description = ""
        if ($content -match "<#(.*?)#>") {
            $description = $matches[1].Trim()
        }
        
        # Determine script type based on path
        $scriptType = "utility"
        if ($filePath -match "\\workers\\") { $scriptType = "worker" }
        elseif ($filePath -match "\\triggers\\") { $scriptType = "trigger" }
        elseif ($filePath -match "\\modules\\") { $scriptType = "module" }
        elseif ($filePath -match "\\spine\\") { $scriptType = "orchestrator" }
        elseif ($fileName -match "test") { $scriptType = "test" }
        
        # Determine domain based on content/path
        $domain = "unknown"
        if ($content -match "series|grinder|episode|season|normalize") { $domain = "ingest" }
        elseif ($content -match "governance|rule|igm|attest") { $domain = "governance" }
        elseif ($content -match "telemetry|log|monitor") { $domain = "telemetry" }
        elseif ($content -match "api|endpoint|gateway") { $domain = "api" }
        elseif ($filePath -match "cvi|dog_open") { $domain = "cvi" }
        
        # Check if already exists
        $checkSql = "SELECT COUNT(*) as count FROM pcde_procedure_registry WHERE source_path = '$filePath'"
        $check = Invoke-SQL -Sql $checkSql
        
        if ($check.rows[0].count -gt 0) {
            Write-Host "⏭️ Already exists: $fileName" -ForegroundColor Gray
            $skipped++
            continue
        }
        
        # Prepare SQL
        $escapedName = Escape-SQL -Text $fileBase
        $escapedDesc = Escape-SQL -Text $description
        $escapedPath = Escape-SQL -Text $filePath
        
        $sql = @"
INSERT INTO pcde_procedure_registry 
(procedure_name, domain, procedure_type, source_system, source_path, description, why_it_exists, active, created_at)
VALUES 
('$escapedName', '$domain', '$scriptType', 'powershell', '$escapedPath', '$(if ($escapedDesc) { $escapedDesc } else { "No description" })', 'Auto-discovered during PS1 scan', 1, NOW())
"@
        
        $result = Invoke-SQL -Sql $sql
        if ($result.affected -and $result.affected -gt 0) {
            Write-Host "✅ Added: $fileName [$domain/$scriptType]" -ForegroundColor Green
            
            # Group by base name for relation tracking
            $baseGroup = $fileBase -replace "_\d+$", ""  # Remove step numbers
            if (-not $fileGroups[$baseGroup]) {
                $fileGroups[$baseGroup] = @()
            }
            $fileGroups[$baseGroup] += $filePath
            
            $processed++
        } else {
            Write-Host "❌ Failed: $fileName" -ForegroundColor Red
            $errors++
        }
    }
    catch {
        Write-Host "❌ Error processing $fileName : $_" -ForegroundColor Red
        $errors++
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
        foreach ($filePath in $files) {
            $getIdSql = "SELECT procedure_id FROM pcde_procedure_registry WHERE source_path = '$filePath'"
            $idResult = Invoke-SQL -Sql $getIdSql
            
            if ($idResult.rows -and $idResult.rows.Count -gt 0) {
                $procId = $idResult.rows[0].procedure_id
                
                # Link to other files in group
                foreach ($otherPath in $files) {
                    if ($otherPath -ne $filePath) {
                        $getOtherId = "SELECT procedure_id FROM pcde_procedure_registry WHERE source_path = '$otherPath'"
                        $otherResult = Invoke-SQL -Sql $getOtherId
                        
                        if ($otherResult.rows -and $otherResult.rows.Count -gt 0) {
                            $otherId = $otherResult.rows[0].procedure_id
                            
                            $relSql = @"
INSERT INTO pcde_procedure_relations (procedure_id, relation_type, relation_target, notes)
VALUES ($procId, 'related_script', 'procedure:$otherId', 'Part of $group script family')
ON DUPLICATE KEY UPDATE notes = notes
"@
                            $relResult = Invoke-SQL -Sql $relSql
                            if ($relResult.affected) { $relationsAdded++ }
                        }
                    }
                }
            }
        }
    }
}

# Summary
Write-Host "`n" + "="*50 -ForegroundColor Cyan
Write-Host "📋 INGESTION COMPLETE" -ForegroundColor Cyan
Write-Host "="*50 -ForegroundColor Cyan
Write-Host "Total PS1 files found: $($allFiles.Count)" -ForegroundColor White
Write-Host "Successfully added: $processed" -ForegroundColor Green
Write-Host "Already existed: $skipped" -ForegroundColor Yellow
Write-Host "Errors: $errors" -ForegroundColor Red
Write-Host "Relations created: $relationsAdded" -ForegroundColor Magenta
Write-Host "="*50

# Show recent additions
Write-Host "`n🔍 Most recent additions:" -ForegroundColor Cyan
$recentSql = "SELECT procedure_id, procedure_name, domain, procedure_type, created_at FROM pcde_procedure_registry ORDER BY procedure_id DESC LIMIT 5"
$recent = Invoke-SQL -Sql $recentSql
if ($recent.rows) {
    $recent.rows | Format-Table -AutoSize
}