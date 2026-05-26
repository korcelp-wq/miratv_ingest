# Knowledge Miner - Extracts procedures from lake_knowledge
$token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$endpoint = "https://miratv.club/_workers/api/series/dog_open.php"

# Function to run SQL
function Run-SQL {
    param([string]$Sql, [string]$Db = "lake_knowledge")
    $body = @{ token = $token; db = $Db; sql = $Sql; params = @() } | ConvertTo-Json
    try { 
        return Invoke-RestMethod -Uri $endpoint -Method Post -Body $body -ContentType "application/json"
    }
    catch { 
        Write-Host "❌ SQL Error: $_" -ForegroundColor Red
        return $null 
    }
}

# Function to safely escape text for SQL
function Escape-ForSQL {
    param([string]$Text)
    
    # Replace single quotes with two single quotes (SQL escape)
    $escaped = $Text -replace "'", "''"
    
    # Remove or replace other problematic characters
    $escaped = $escaped -replace "`r", " "
    $escaped = $escaped -replace "`n", " "
    $escaped = $escaped -replace '"', '\"'
    
    # Truncate if too long
    if ($escaped.Length -gt 500) {
        $escaped = $escaped.Substring(0, 500) + "..."
    }
    
    return $escaped
}

# Function to check if a similar insight already exists
function Test-InsightExists {
    param([string]$Insight, [float]$Confidence)
    
    # Create a search key from the first 50 chars
    $searchKey = $Insight.Substring(0, [Math]::Min(50, $Insight.Length))
    $searchKey = Escape-ForSQL -Text $searchKey
    
    $checkSql = @"
SELECT COUNT(*) as exists_count 
FROM pcde_ai_memory 
WHERE key_data LIKE '$searchKey%'
  AND confidence > $($Confidence - 0.2)
  AND ABS(confidence - $Confidence) < 0.3
"@
    
    $result = Run-SQL -Db "pcde_memory" $checkSql
    if ($result -and $result.rows -and $result.rows.Count -gt 0) {
        return [int]$result.rows[0].exists_count -gt 0
    }
    return $false
}

# Function to add to AI memory (with duplicate check)
function Add-ToMemory {
    param([string]$Discovery, [float]$Confidence, [string]$Type = "discovery")
    
    # Check if this insight already exists
    if (Test-InsightExists -Insight $Discovery -Confidence $Confidence) {
        Write-Host "  ⏭️ Skipping duplicate: $(if ($Discovery.Length -gt 50) { $Discovery.Substring(0,50) + '...' } else { $Discovery })" -ForegroundColor Gray
        return $false
    }
    
    # Escape the discovery text for SQL
    $escaped = Escape-ForSQL -Text $Discovery
    
    $sql = @"
INSERT INTO pcde_ai_memory (agent_name, memory_type, key_data, confidence, created_at)
VALUES ('knowledge_miner', '$Type', '$escaped', $Confidence, NOW())
"@
    
    $body = @{ token = $token; db = "pcde_memory"; sql = $sql; params = @() } | ConvertTo-Json
    
    try {
        Invoke-RestMethod -Uri $endpoint -Method Post -Body $body -ContentType "application/json" -ErrorAction Stop | Out-Null
        Write-Host "  ✅ Added: $(if ($Discovery.Length -gt 50) { $Discovery.Substring(0,50) + '...' } else { $Discovery })" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "  ❌ Failed to add: $($Discovery.Substring(0, [Math]::Min(50, $Discovery.Length)))..." -ForegroundColor Red
        return $false
    }
}

Write-Host "`n🌊 Knowledge Miner Starting..." -ForegroundColor Cyan
Write-Host "===============================" -ForegroundColor Cyan

# Track counts
$totalAdded = 0
$totalSkipped = 0

# ------------------------------------------------------------
# MINING PASS 1: Extract from raw_conversations
# ------------------------------------------------------------
Write-Host "`n📚 Mining conversations..." -ForegroundColor Yellow

$conversations = Run-Sql @"
SELECT id, content, role, created_at
FROM raw_conversations
WHERE LENGTH(content) > 100
  AND content NOT LIKE '%```%'
ORDER BY created_at DESC
LIMIT 20
"@

if ($conversations.rows -and $conversations.rows.Count -gt 0) {
    foreach ($conv in $conversations.rows) {
        $summary = $conv.content
        if ($summary.Length -gt 150) {
            $summary = $summary.Substring(0, 150) + "..."
        }
        $discovery = "Conversation from $($conv.role): $summary"
        if (Add-ToMemory -Discovery $discovery -Confidence 0.85 -Type "conversation") {
            $totalAdded++
        } else {
            $totalSkipped++
        }
    }
}

# ------------------------------------------------------------
# MINING PASS 2: Extract from knowledge_units (summaries)
# ------------------------------------------------------------
Write-Host "`n🧠 Mining knowledge summaries..." -ForegroundColor Yellow

$units = Run-Sql @"
SELECT id, unit_type, summary, confidence, topic, intent
FROM knowledge_units
WHERE summary IS NOT NULL
  AND LENGTH(summary) > 20
LIMIT 30
"@

if ($units.rows -and $units.rows.Count -gt 0) {
    foreach ($unit in $units.rows) {
        $unitType = if ($unit.unit_type) { $unit.unit_type } else { "knowledge" }
        $topicInfo = if ($unit.topic) { " [Topic: $($unit.topic)]" } else { "" }
        $intentInfo = if ($unit.intent) { " ($($unit.intent))" } else { "" }
        $conf = if ($unit.confidence) { [float]$unit.confidence } else { 0.75 }
        $discovery = "$topicInfo$intentInfo $unitType - $($unit.summary)"
        if (Add-ToMemory -Discovery $discovery -Confidence $conf -Type $unitType) {
            $totalAdded++
        } else {
            $totalSkipped++
        }
    }
}

# ------------------------------------------------------------
# MINING PASS 3: Extract from extracted_docs
# ------------------------------------------------------------
Write-Host "`n📄 Mining documents..." -ForegroundColor Yellow

$docs = Run-Sql @"
SELECT id, title, content, doc_type
FROM extracted_docs
WHERE title IS NOT NULL
  AND LENGTH(content) > 100
LIMIT 15
"@

if ($docs.rows -and $docs.rows.Count -gt 0) {
    foreach ($doc in $docs.rows) {
        $summary = $doc.content
        if ($summary.Length -gt 200) {
            $summary = $summary.Substring(0, 200) + "..."
        }
        $docType = if ($doc.doc_type) { "[$($doc.doc_type)]" } else { "[document]" }
        $discovery = "$docType $($doc.title) - $summary"
        if (Add-ToMemory -Discovery $discovery -Confidence 0.9 -Type "document") {
            $totalAdded++
        } else {
            $totalSkipped++
        }
    }
}

# ------------------------------------------------------------
# MINING PASS 4: Extract procedure candidates from content
# ------------------------------------------------------------
Write-Host "`n🔧 Mining procedure candidates..." -ForegroundColor Yellow

$procFromConv = Run-Sql @"
SELECT id, content
FROM raw_conversations
WHERE content LIKE '%procedure%'
   OR content LIKE '%step%'
   OR content LIKE '%how to%'
   OR content LIKE '%workflow%'
   OR content LIKE '%pipeline%'
   OR content LIKE '%function%'
   OR content LIKE '%method%'
LIMIT 20
"@

if ($procFromConv.rows -and $procFromConv.rows.Count -gt 0) {
    foreach ($proc in $procFromConv.rows) {
        $summary = $proc.content
        if ($summary.Length -gt 150) {
            $summary = $summary.Substring(0, 150) + "..."
        }
        $discovery = "Procedure Candidate: $summary"
        if (Add-ToMemory -Discovery $discovery -Confidence 0.82 -Type "candidate") {
            $totalAdded++
        } else {
            $totalSkipped++
        }
    }
}

# ------------------------------------------------------------
# MINING PASS 5: Look for governance/rule content
# ------------------------------------------------------------
Write-Host "`n⚖️ Mining governance content..." -ForegroundColor Yellow

$governance = Run-Sql @"
SELECT id, content
FROM raw_conversations
WHERE content LIKE '%rule%'
   OR content LIKE '%govern%'
   OR content LIKE '%policy%'
   OR content LIKE '%must%'
   OR content LIKE '%required%'
   OR content LIKE '%shall%'
LIMIT 15
"@

if ($governance.rows -and $governance.rows.Count -gt 0) {
    foreach ($gov in $governance.rows) {
        $summary = $gov.content
        if ($summary.Length -gt 150) {
            $summary = $summary.Substring(0, 150) + "..."
        }
        $discovery = "Governance Insight: $summary"
        if (Add-ToMemory -Discovery $discovery -Confidence 0.88 -Type "governance") {
            $totalAdded++
        } else {
            $totalSkipped++
        }
    }
}

# ------------------------------------------------------------
# MINING PASS 6: Extract from knowledge_units with high confidence
# ------------------------------------------------------------
Write-Host "`n⭐ Mining high-confidence insights..." -ForegroundColor Yellow

$highConf = Run-Sql @"
SELECT id, unit_type, summary, confidence
FROM knowledge_units
WHERE confidence > 0.8
  AND summary IS NOT NULL
LIMIT 10
"@

if ($highConf.rows -and $highConf.rows.Count -gt 0) {
    foreach ($hc in $highConf.rows) {
        $conf = [float]$hc.confidence
        $discovery = "High Confidence $($hc.unit_type) - $($hc.summary)"
        if (Add-ToMemory -Discovery $discovery -Confidence $conf -Type "high_confidence") {
            $totalAdded++
        } else {
            $totalSkipped++
        }
    }
}

# ------------------------------------------------------------
# MINING PASS 7: Create summary statistics
# ------------------------------------------------------------
Write-Host "`n📊 Creating mining summary..." -ForegroundColor Yellow

# Get counts
$convCount = (Run-Sql "SELECT COUNT(*) as count FROM raw_conversations").rows[0].count
$unitCount = (Run-Sql "SELECT COUNT(*) as count FROM knowledge_units").rows[0].count
$docCount = (Run-Sql "SELECT COUNT(*) as count FROM extracted_docs").rows[0].count

$stats = @"
Lake Knowledge Summary:
- $convCount raw conversations
- $unitCount knowledge units
- $docCount extracted documents
- Added $totalAdded new insights
- Skipped $totalSkipped duplicates
"@

Add-ToMemory -Discovery $stats -Confidence 1.0 -Type "summary"

Write-Host "`n✅ Knowledge Mining Complete!" -ForegroundColor Green
Write-Host $stats -ForegroundColor Cyan
Write-Host "Total new insights added: $totalAdded" -ForegroundColor Magenta
Write-Host "Total duplicates skipped: $totalSkipped" -ForegroundColor Yellow