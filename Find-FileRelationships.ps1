#!/usr/bin/env pwsh
# Find-FileRelationships-URL.ps1 - Detects connections using URLs (no file checks)

$token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$endpoint = "https://miratv.club/_workers/api/series/dog_open.php"

Write-Host "🔍 Finding URL Relationships..." -ForegroundColor Cyan
Write-Host "==============================" -ForegroundColor Cyan

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

# Get all registered procedures
Write-Host "`n📂 Getting registered procedures..." -ForegroundColor Yellow
$procs = Invoke-SQL -Sql "SELECT procedure_id, procedure_name, source_path, source_system, procedure_type FROM pcde_procedure_registry WHERE source_path IS NOT NULL"

if (-not $procs -or -not $procs.rows) {
    Write-Host "No procedures found in registry" -ForegroundColor Red
    exit
}

$procList = $procs.rows
Write-Host "Found $($procList.Count) procedures to analyze" -ForegroundColor Green

$relationsFound = 0
$nameGroups = @{}

# ------------------------------------------------------------
# PASS 1: Group by naming patterns
# ------------------------------------------------------------
Write-Host "`n🔗 Grouping related procedures by name..." -ForegroundColor Yellow

foreach ($proc in $procList) {
    $name = $proc.procedure_name
    $id = $proc.procedure_id
    
    # Extract base name (remove version numbers, step indicators)
    $baseName = $name -replace '_\d+$', '' -replace 'v\d+$', '' -replace '\.\w+$', ''
    
    if (-not $nameGroups[$baseName]) {
        $nameGroups[$baseName] = @()
    }
    $nameGroups[$baseName] += @{
        id = $id
        name = $name
        path = $proc.source_path
    }
}

# Link files with same base name
foreach ($group in $nameGroups.Keys) {
    $files = $nameGroups[$group]
    if ($files.Count -gt 1) {
        Write-Host "  Group: $group ($($files.Count) files)" -ForegroundColor Gray
        
        for ($i = 0; $i -lt $files.Count; $i++) {
            for ($j = $i + 1; $j -lt $files.Count; $j++) {
                $relSql = @"
INSERT INTO pcde_procedure_relations (procedure_id, relation_type, relation_target, notes)
VALUES ($($files[$i].id), 'related_name', 'procedure:$($files[$j].id)', 'Related by naming convention: $group')
ON DUPLICATE KEY UPDATE notes = notes
"@
                $result = Invoke-SQL -Sql $relSql
                if ($result -and $result.affected) { $relationsFound++ }
            }
        }
    }
}

# ------------------------------------------------------------
# PASS 2: Link by domain
# ------------------------------------------------------------
Write-Host "`n🌐 Grouping by domain patterns..." -ForegroundColor Yellow

$domainGroups = @{
    "ingest" = @()
    "api" = @()
    "governance" = @()
    "telemetry" = @()
    "cvi" = @()
}

foreach ($proc in $procList) {
    $path = $proc.source_path
    $id = $proc.procedure_id
    
    if ($path -match '_ingest|import_|series_|vod_|live_') {
        $domainGroups["ingest"] += $id
    }
    elseif ($path -match 'api|endpoint|gateway|player') {
        $domainGroups["api"] += $id
    }
    elseif ($path -match 'governance|rule|igm|policy') {
        $domainGroups["governance"] += $id
    }
    elseif ($path -match 'telemetry|log|monitor') {
        $domainGroups["telemetry"] += $id
    }
    elseif ($path -match 'cvi|dog_open|carousel') {
        $domainGroups["cvi"] += $id
    }
}

foreach ($domain in $domainGroups.Keys) {
    $ids = $domainGroups[$domain]
    if ($ids.Count -gt 1) {
        Write-Host "  Domain: $domain ($($ids.Count) procedures)" -ForegroundColor Gray
        
        # Create a "parent" relation to represent the domain
        foreach ($id in $ids) {
            $relSql = @"
INSERT INTO pcde_procedure_relations (procedure_id, relation_type, relation_target, notes)
VALUES ($id, 'belongs_to_domain', '$domain', 'Part of $domain domain')
ON DUPLICATE KEY UPDATE notes = notes
"@
            $result = Invoke-SQL -Sql $relSql
            if ($result -and $result.affected) { $relationsFound++ }
        }
    }
}

# ------------------------------------------------------------
# PASS 3: Find potential document hubs
# ------------------------------------------------------------
Write-Host "`n📊 Finding document hubs..." -ForegroundColor Yellow

$hubSql = @"
SELECT 
    r.procedure_name,
    COUNT(DISTINCT rel.relation_target) as outgoing_links,
    COUNT(DISTINCT rel2.procedure_id) as incoming_links,
    (COUNT(DISTINCT rel.relation_target) + COUNT(DISTINCT rel2.procedure_id)) as total_connections
FROM pcde_procedure_registry r
LEFT JOIN pcde_procedure_relations rel ON r.procedure_id = rel.procedure_id
LEFT JOIN pcde_procedure_relations rel2 ON CONCAT('procedure:', r.procedure_id) = rel2.relation_target
GROUP BY r.procedure_id
ORDER BY total_connections DESC
LIMIT 15
"@

$hubs = Invoke-SQL -Sql $hubSql
if ($hubs -and $hubs.rows) {
    Write-Host "`n📈 Most Connected Files (Orchestration Hubs):" -ForegroundColor Cyan
    $hubs.rows | Format-Table -AutoSize
}

# Summary
Write-Host "`n" + "="*60 -ForegroundColor Cyan
Write-Host "📋 RELATIONSHIP ANALYSIS COMPLETE" -ForegroundColor Cyan
Write-Host "="*60 -ForegroundColor Cyan
Write-Host "New relations created: $relationsFound" -ForegroundColor Green
$total = Invoke-SQL -Sql "SELECT COUNT(*) as c FROM pcde_procedure_relations"
if ($total -and $total.rows) {
    Write-Host "Total relations in database: $($total.rows[0].c)" -ForegroundColor White
}
Write-Host "="*60