﻿#!/usr/bin/env pwsh
# Master Control Console for PCDE - WITH AI CHAT

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$queryScript = "$scriptPath\dashboard\Query.ps1"
$logDir = "$scriptPath\logs"

# Create log directory if it doesn't exist
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# Configuration
$config = @{
    AIProvider = "ollama"
    AIModel = "llama3.2:latest"
    OllamaUrl = "http://localhost:11434"
    MaxContextItems = 5
    MinConfidenceForMemory = 0.85
    SQLTimeout = 30
}

$aiSessionId = $null
$token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$cviEndpoint = "https://miratv.club/_workers/api/series/dog_open.php"

# ============= AI FUNCTIONS =============

function Enter-AIChatLoop {
    if (-not $script:aiSessionId) { Start-AISession | Out-Null }

    Write-Host "`nAI Chat Session: $($script:aiSessionId)" -ForegroundColor Cyan
    Write-Host "Type /exit to return to menu.`n" -ForegroundColor DarkGray

    while ($true) {
        $msg = Read-Host "You"
        if ([string]::IsNullOrWhiteSpace($msg)) { continue }
        if ($msg -eq "/exit") { break }

        $result = Ask-AI -Question $msg
        if ($result) {
            Write-Host "`n🤖 [$($result.source)] $($result.answer)`n" -ForegroundColor Green
        }
    }
}

# ============= ORIGINAL FUNCTIONS =============
function Invoke-DBQuery {
    param([string]$Sql)
    

    $result = & $queryScript -Sql $Sql 2>&1 | Out-String
    return $result
}

function Show-Header {
    Clear-Host
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║     🧠 PCDE MASTER CONTROL CONSOLE                      ║" -ForegroundColor Cyan
    Write-Host "║     Cognitive Systems Command Center                    ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Status {
    Write-Host "📊 SYSTEM STATUS" -ForegroundColor Yellow
    Write-Host "================"
    
    # Check database connectivity
    $test = & $queryScript -Sql "SELECT 1 as test" 2>$null
    if ($test -match "rows") {
        Write-Host "✅ Database: Connected to pcde_memory" -ForegroundColor Green
    } else {
        Write-Host "❌ Database: Connection failed" -ForegroundColor Red
    }
    
    # Check Ollama
    try {
        $ollamaTest = Invoke-RestMethod -Uri "$($config.OllamaUrl)/api/tags" -TimeoutSec 5 -ErrorAction SilentlyContinue
        if ($ollamaTest.models) {
            $modelNames = $ollamaTest.models | ForEach-Object { $_.name }
            Write-Host "✅ Ollama: Connected (Models: $($modelNames -join ', '))" -ForegroundColor Green
        }
    } catch {
        Write-Host "⚠️ Ollama: Not connected (local AI unavailable)" -ForegroundColor Yellow
    }
    
    # Get all running jobs
    $jobs = Get-Job
    
    # Service mapping
    $serviceMap = @{
        'SpineScheduler' = @{ name = 'Spine Scheduler'; menu = '4' }
        'CVIWatcher' = @{ name = 'CVI Watcher'; menu = '5' }
        'TelemetryWatcher' = @{ name = 'Telemetry Watcher'; menu = '6' }
        'SpoolUploader' = @{ name = 'Spool Uploader'; menu = '7' }
        'AILearning' = @{ name = 'AI Learning Loop'; menu = '8' }
        'LearningLoop' = @{ name = 'Learning Loop'; menu = '9' }
        'AccessoryLoop' = @{ name = 'Accessory Loop'; menu = '10' }
        'RunnerLoop' = @{ name = 'Runner Loop'; menu = '11' }
    }
    
    Write-Host ""
    Write-Host "🔄 ACTIVE SERVICES:" -ForegroundColor Yellow
    
    # Core Services
    Write-Host "  CORE SERVICES (4-8):" -ForegroundColor Cyan
    $coreServices = @('SpineScheduler', 'CVIWatcher', 'TelemetryWatcher', 'SpoolUploader', 'AILearning')
    
    foreach ($service in $coreServices) {
        $job = $jobs | Where-Object { $_.Name -eq $service }
        $info = $serviceMap[$service]
        
        if ($job -and $job.State -eq 'Running') {
            Write-Host "    ✅ [$($info.menu)] $($info.name)" -ForegroundColor Green
        } else {
            Write-Host "    ⏸️ [$($info.menu)] $($info.name)" -ForegroundColor Gray
        }
    }
    
    # Learning Loops
    Write-Host ""
    Write-Host "  LEARNING LOOP SERVICES (9-11):" -ForegroundColor Cyan
    $loopServices = @('LearningLoop', 'AccessoryLoop', 'RunnerLoop')
    
    foreach ($service in $loopServices) {
        $job = $jobs | Where-Object { $_.Name -eq $service }
        $info = $serviceMap[$service]
        
        if ($job -and $job.State -eq 'Running') {
            Write-Host "    ✅ [$($info.menu)] $($info.name)" -ForegroundColor Green
        } else {
            Write-Host "    ⏸️ [$($info.menu)] $($info.name)" -ForegroundColor Gray
        }
    }
    
    # Show AI session if active
    if ($aiSessionId) {
        Write-Host ""
        Write-Host "💬 Active AI Session: $($aiSessionId.Substring(0,8))..." -ForegroundColor Cyan
    }
}

function Start-Service {
    param([string]$Name, [string]$Path, [array]$Args = @())
    
    if (Test-Path $Path) {
        Write-Host "Starting $Name..." -ForegroundColor Yellow
        Start-Job -Name $Name -FilePath $Path -ArgumentList $Args
        Write-Host "✅ $Name started" -ForegroundColor Green
    } else {
        Write-Host "❌ $Name not found at $Path" -ForegroundColor Red
    }
}

function Stop-ServiceByName {
    param([string]$Name)
    
    $job = Get-Job -Name $Name -ErrorAction SilentlyContinue
    if ($job) {
        Stop-Job $job
        Remove-Job $job
        Write-Host "✅ $Name stopped" -ForegroundColor Green
    } else {
        Write-Host "⚠️ $Name is not running" -ForegroundColor Yellow
    }
}

function Show-Menu {
    Write-Host ""
    Write-Host "🎮 COMMANDS" -ForegroundColor Magenta
    Write-Host "==========="
    Write-Host ""
    Write-Host "  SERVICE CONTROL:" -ForegroundColor White
    Write-Host "    1) Start All Services" 
    Write-Host "    2) Stop All Services"
    Write-Host "    3) Show Service Status"
    Write-Host ""
    Write-Host "  CORE SERVICES:" -ForegroundColor White
    Write-Host "    4) Start Spine Scheduler"
    Write-Host "    5) Start CVI Watcher"
    Write-Host "    6) Start Telemetry Watcher"
    Write-Host "    7) Start Spool Uploader"
    Write-Host "    8) Start AI Learning Loop"
    Write-Host ""
    Write-Host "  LEARNING LOOP SERVICES:" -ForegroundColor White
    Write-Host "    9) Start Learning Loop"
    Write-Host "   10) Start Accessory Loop"
    Write-Host "   11) Start Runner Loop"
    Write-Host ""
    Write-Host "  AI COMMANDS (Display):" -ForegroundColor White
    Write-Host "   12) Show AI Learnings"
    Write-Host "   13) Show Working Memory"
    Write-Host "   14) Run Governance Learner Now"
    Write-Host ""
    Write-Host "  🤖 GENERATIVE AI:" -ForegroundColor Magenta
    Write-Host "   20) Start AI Chat Session (Interactive)"
    Write-Host "   21) Ask AI a Question (Single)"
    Write-Host "   22) Show Chat History"
    Write-Host "   23) Clear Chat Session"
    Write-Host "   24) Show Complete Memory Statistics"
    Write-Host ""
    Write-Host "  DATABASE:" -ForegroundColor White
    Write-Host "   15) Run Custom SQL"
    Write-Host "   16) Export AI Memory"
    Write-Host ""
    Write-Host "  ADDITIONAL PROCESSES:" -ForegroundColor White
    Write-Host "   17) Start Mastery Accessory Loop"
    Write-Host "   18) Start Main Series Loop"
    Write-Host "   19) Start Master Upload Loop"
    Write-Host "   25) Run Relationship Finder"
    Write-Host ""
    Write-Host "  99) Exit"
    Write-Host ""
}

function Show-AILearnings {
    $result = & $queryScript -Sql "SELECT memory_id, agent_name, memory_type, LEFT(key_data,100) as preview, confidence, created_at FROM pcde_ai_memory ORDER BY confidence DESC, memory_id DESC LIMIT 10"
    
    if ($result) {
        Write-Host "`n🧠 RECENT AI LEARNINGS" -ForegroundColor Cyan
        Write-Host "====================="
        Write-Host $result
    }
}

function Show-WorkingMemory {
    $result = & $queryScript -Sql "SELECT * FROM pcde_working_memory WHERE expires_at > NOW() ORDER BY created_at DESC"
    
    if ($result) {
        Write-Host "`n🧠 ACTIVE WORKING MEMORY" -ForegroundColor Cyan
        Write-Host "========================"
        Write-Host $result
    } else {
        Write-Host "No active working memory" -ForegroundColor Yellow
    }
}

# ============= ENHANCED AI FUNCTIONS WITH KEYWORD SEARCH =============
function Invoke-SQLDirect {
    param([string]$Sql, [string]$Db = "pcde_memory")
    
    $body = @{
        token = $token
        db = $Db
        sql = $Sql
        params = @()
    } | ConvertTo-Json
    
    try {
        return Invoke-RestMethod -Uri $cviEndpoint -Method Post -Body $body -ContentType "application/json" -TimeoutSec $config.SQLTimeout
    }
    catch {
        return $null
    }
}

function Start-AISession {
    param([string]$SessionId = (New-Guid).ToString())
    
    Write-Host "`n🚀 Starting AI Session..." -ForegroundColor Yellow
    
    $script:aiSessionId = $SessionId
    Write-Host "✅ AI Session started (ID: $($SessionId.Substring(0,8))...)" -ForegroundColor Green
    
    return $SessionId
}

function Get-ChatHistory {
    if (-not $script:aiSessionId) { return $null }
    
    $sql = @"
SELECT slot_key, slot_value, created_at
FROM pcde_working_memory
WHERE session_id = '$script:aiSessionId'
  AND (slot_key LIKE 'q_%' OR slot_key LIKE 'a_%')
ORDER BY created_at
"@
    
    return & $queryScript -Sql $sql
}

# Keyword extraction function
function Get-Keywords {
    param([string]$Text)
    
    # Split into words and clean
    $words = $Text -split '\s+' | ForEach-Object { 
        $_.Trim('?.,!;:()[]{}"''').ToLower() 
    }
    
    # Common stop words to filter out
    $stopWords = @(
        'who', 'what', 'where', 'when', 'why', 'how', 'which', 'whose',
        'is', 'are', 'was', 'were', 'be', 'been', 'being',
        'do', 'does', 'did', 'done', 'doing',
        'can', 'could', 'will', 'would', 'shall', 'should', 'may', 'might', 'must',
        'the', 'a', 'an', 'and', 'or', 'but', 'if', 'then', 'else', 'when',
        'up', 'so', 'too', 'very', 'just', 'now', 'then',
        'you', 'your', 'yours', 'my', 'mine', 'me', 'we', 'us', 'our', 'ours',
        'their', 'theirs', 'them', 'they', 'he', 'him', 'his', 'she', 'her', 'hers',
        'it', 'its', 'this', 'that', 'these', 'those',
        'have', 'has', 'had', 'having',
        'get', 'gets', 'got', 'getting',
        'know', 'knows', 'knew', 'knowing',
        'tell', 'tells', 'told', 'telling'
        # Note: 'capabilities', 'procedure', 'procedures' are NOT stop words
    )
    
    # Important technical terms to ALWAYS keep
    $technicalTerms = @(
        'ai', 'api', 'sql', 'db', 'csv', 'xml', 'json', 'html', 'css',
        'proc', 'sp', 'view', 'batch', 'script', 'pipeline',
        'cvi', 'spine', 'spool', 'telemetry',
        'capabilities', 'capability', 'ability',
        'procedure', 'procedures', 'stored', 'function'
    )
    
    $keywords = @()
    foreach ($word in $words) {
        # Keep words that are:
        # 1. In technical terms list, OR
        # 2. Longer than 2 characters AND not in stop words
        if ($technicalTerms -contains $word -or 
            ($word.Length -gt 2 -and $stopWords -notcontains $word)) {
            $keywords += $word
        }
    }
    
    # Remove duplicates
    $keywords = $keywords | Select-Object -Unique
    
    return $keywords
}

# Safe SQL query execution
function Safe-SqlQuery {
    param([string]$Sql, [string]$Context)
    
    Write-Host "   🔍 $Context..." -ForegroundColor Gray
    try {
        $result = & $queryScript -Sql $Sql 2>&1
        
        # Check for errors
        if ($LASTEXITCODE -ne 0) {
            return $null
        }
        
        # Convert to string
        $resultString = $result | Out-String
        
        # Check for empty results
        if ([string]::IsNullOrWhiteSpace($resultString)) {
            return $null
        }
        
        # Check for empty rows
        if ($resultString -match '"rows":\s*\[\s*\]' -or 
            $resultString -match '\[\s*\]' -or
            $resultString.Trim() -eq '[]') {
            return $null
        }
        
        # Check for HTTP errors
        if ($resultString -match "500 Internal Server Error" -or 
            $resultString -match "HTTP Error") {
            return $null
        }
        
        return $resultString
        
    } catch {
        return $null
    }
}

# Build WHERE clause for keyword search
function Build-WhereClause {
    param(
        [string[]]$Fields,
        [string[]]$Keywords
    )
    
    if ($Keywords.Count -eq 0) {
        return "1=0" # Always false
    }
    
    $conditions = @()
    foreach ($field in $Fields) {
        foreach ($keyword in $Keywords) {
            $conditions += "$field LIKE '%$keyword%'"
        }
    }
    
    # Join with OR and wrap in parentheses for each keyword group
    if ($conditions.Count -gt 0) {
        return "(" + ($conditions -join " OR ") + ")"
    }
    
    return "1=0"
}

# Main AI function with keyword search
function Ask-AI {
    param([string]$Question)
    
    if (-not $script:aiSessionId) {
        Write-Host "⚠️ No active session. Starting new session..." -ForegroundColor Yellow
        Start-AISession
    }
    
    Write-Host "`n🤔 Asking AI: $Question" -ForegroundColor Cyan
    Write-Host "🔍 Extracting keywords and searching memory..." -ForegroundColor Yellow
    
    # Escape quotes for SQL
    $escapedQuestion = $Question -replace "'", "''"
    
    # Extract keywords
    $keywords = Get-Keywords -Text $Question
    
    if ($keywords.Count -eq 0) {
        Write-Host "   ⚠️ No keywords extracted, using full question" -ForegroundColor Yellow
        $keywords = @($escapedQuestion)
    } else {
        Write-Host "   🔑 Keywords: $($keywords -join ', ')" -ForegroundColor Green
    }
    
    # ============= HIERARCHICAL MEMORY SEARCH =============
    $memoryResult = $null
    $memorySource = ""
    $confidence = 0
    
    # 1. PROCEDURAL MEMORY
    Write-Host "   📋 Searching Procedural Memory..." -ForegroundColor Cyan
    
    $procFields = @('procedure_name', 'description', 'domain', 'why_it_exists')
$procWhere = Build-WhereClause -Fields $procFields -Keywords $keywords

$proceduralSql = @"
SELECT 
    procedure_id, 
    procedure_name, 
    procedure_type, 
    domain, 
    description,
    'procedure' as memory_type
FROM pcde_procedure_registry 
WHERE $procWhere
ORDER BY 
    CASE 
        WHEN procedure_name LIKE '%$($keywords[0])%' THEN 1
        WHEN domain LIKE '%$($keywords[0])%' THEN 2
        ELSE 3
    END,
    procedure_id DESC
LIMIT 8
"@
    
    $procedural = Safe-SqlQuery -Sql $proceduralSql -Context "Procedural Memory"
    
    if ($procedural) {
        Write-Host "   ✅ Found in Procedural Memory" -ForegroundColor Green
        $memoryResult = $procedural
        $memorySource = "procedural"
        $confidence = 0.9
    }
    
    # 2. DECLARATIVE MEMORY
    if (-not $memoryResult) {
        Write-Host "   📚 Searching Declarative Memory..." -ForegroundColor Cyan
        
        $decFields = @('predicate', 'object_value', 'domain', 'subject_type')
$decWhere = Build-WhereClause -Fields $decFields -Keywords $keywords

$declarativeSql = @"
SELECT 
    fact_id, 
    fact_type, 
    domain, 
    predicate, 
    object_value, 
    confidence,
    subject_type,
    subject_id,
    verified_at
FROM pcde_declarative_memory 
WHERE $decWhere
   AND confidence >= 0.75
ORDER BY 
    confidence DESC, 
    verified_at DESC
LIMIT 8
"@
        
        $declarative = Safe-SqlQuery -Sql $declarativeSql -Context "Declarative Memory"
        
        if ($declarative) {
            Write-Host "   ✅ Found in Declarative Memory" -ForegroundColor Green
            $memoryResult = $declarative
            $memorySource = "declarative"
            
            # Extract confidence if available
            if ($declarative -match '"confidence":\s*([\d\.]+)') {
                $confidence = [double]$matches[1]
            } else {
                $confidence = 0.85
            }
        }
    }
    
    # 3. ASSOCIATIVE MEMORY
    if (-not $memoryResult) {
        Write-Host "   🔗 Searching Associative Memory..." -ForegroundColor Cyan
        
        $assocFields = @('relation_type', 'relation_target', 'notes')
$assocWhere = Build-WhereClause -Fields $assocFields -Keywords $keywords

$associativeSql = @"
SELECT 
    relation_id, 
    procedure_id, 
    relation_type, 
    relation_target, 
    notes,
    CONCAT(relation_type, ' → ', relation_target) as relation_summary
FROM pcde_procedure_relations 
WHERE $assocWhere
ORDER BY 
    CASE 
        WHEN notes LIKE '%$($keywords[0])%' THEN 1
        ELSE 2
    END,
    relation_id DESC
LIMIT 10
"@
        
        $associative = Safe-SqlQuery -Sql $associativeSql -Context "Associative Memory"
        
        if ($associative) {
            Write-Host "   ✅ Found in Associative Memory" -ForegroundColor Green
            $memoryResult = $associative
            $memorySource = "associative"
            $confidence = 0.8
        }
    }
    
    # 4. WORKING MEMORY
    if (-not $memoryResult) {
        Write-Host "   💭 Searching Working Memory..." -ForegroundColor Cyan
        
        $workFields = @('slot_value')
        $workWhere = Build-WhereClause -Fields $workFields -Keywords $keywords
        
        $workingSql = @"
SELECT slot_key, slot_value, created_at
FROM pcde_working_memory
WHERE session_id = '$script:aiSessionId'
   AND $workWhere
   AND expires_at > NOW()
ORDER BY created_at DESC
LIMIT 5
"@
        
        $working = Safe-SqlQuery -Sql $workingSql -Context "Working Memory"
        
        if ($working) {
            Write-Host "   ✅ Found in Working Memory" -ForegroundColor Green
            $memoryResult = $working
            $memorySource = "working"
            $confidence = 0.75
        }
    }
    
    # 5. AI MEMORY
    if (-not $memoryResult) {
        Write-Host "   🧠 Searching AI Learning Memory..." -ForegroundColor Cyan
        
        $aiFields = @('key_data', 'memory_type', 'agent_name')
$aiWhere = Build-WhereClause -Fields $aiFields -Keywords $keywords

$aiMemorySql = @"
SELECT 
    memory_id, 
    agent_name, 
    memory_type, 
    key_data, 
    confidence, 
    access_count,
    created_at,
    DATE_FORMAT(created_at, '%Y-%m-%d') as learned_date
FROM pcde_ai_memory 
WHERE $aiWhere
   AND confidence >= 0.7
ORDER BY 
    confidence DESC, 
    access_count DESC, 
    created_at DESC
LIMIT 10
"@
        
        $aiMemory = Safe-SqlQuery -Sql $aiMemorySql -Context "AI Memory"
        
        if ($aiMemory) {
            Write-Host "   ✅ Found in AI Memory" -ForegroundColor Green
            $memoryResult = $aiMemory
            $memorySource = "ai_memory"
            
            # Extract confidence
            if ($aiMemory -match '"confidence":\s*([\d\.]+)') {
                $confidence = [double]$matches[1]
            } else {
                $confidence = 0.8
            }
        }
    }
    
    # Check if we should show procedures from database directly
    if (-not $memoryResult -and ($Question -match "procedures?" -or $Question -match "what (procedures|services) (do you have|are available)")) {
        Write-Host "   📋 Checking for available procedures in database..." -ForegroundColor Cyan
        
        $procedureCountSql = "SELECT COUNT(*) as count FROM pcde_procedure_registry WHERE active = 1 OR active IS NULL"
        $procedureCount = Safe-SqlQuery -Sql $procedureCountSql -Context "Procedure Count"
        
        if ($procedureCount -and $procedureCount -match '"count":\s*(\d+)') {
            $count = [int]$matches[1]
            if ($count -gt 0) {
                $procedureListSql = @"
SELECT procedure_name, procedure_type, description 
FROM pcde_procedure_registry 
WHERE active = 1 OR active IS NULL
ORDER BY procedure_name 
LIMIT 15
"@
                $procedureList = Safe-SqlQuery -Sql $procedureListSql -Context "Procedure List"
                
                if ($procedureList) {
                    $formattedAnswer = @"
📋 Available MiraTV System Procedures ($count total):

$procedureList

These are the procedures currently registered in your MiraTV system.
"@
                    
                    # Store in working memory
                    $qId = "q_$(Get-Random -Maximum 9999)"
                    $aId = "a_$(Get-Random -Maximum 9999)"
                    $escapedAnswer = $formattedAnswer -replace "'", "''"
                    
                    & $queryScript -Sql @"
INSERT INTO pcde_working_memory (session_id, slot_key, slot_value)
VALUES ('$script:aiSessionId', '$qId', '$escapedQuestion'),
       ('$script:aiSessionId', '$aId', '$escapedAnswer')
"@ 2>$null
                    
                    return @{
                        answer = $formattedAnswer
                        source = "database"
                        confidence = 0.95
                    }
                }
            }
        }
    }
    
    # If found in memory, format and return
    if ($memoryResult) {
        Write-Host "✅ Using $memorySource memory" -ForegroundColor Green
        
        $sourceIcons = @{
            "procedural" = "📋"
            "declarative" = "📚"
            "associative" = "🔗"
            "working" = "💭"
            "ai_memory" = "🧠"
        }
        $icon = $sourceIcons[$memorySource]
        
        $formattedAnswer = @"
$icon Found in $memorySource memory:

$memoryResult
"@
        
        # Store in working memory
        $qId = "q_$(Get-Random -Maximum 9999)"
        $aId = "a_$(Get-Random -Maximum 9999)"
        $escapedAnswer = $formattedAnswer -replace "'", "''"
        
        & $queryScript -Sql @"
INSERT INTO pcde_working_memory (session_id, slot_key, slot_value)
VALUES ('$script:aiSessionId', '$qId', '$escapedQuestion'),
       ('$script:aiSessionId', '$aId', '$escapedAnswer')
"@ 2>$null
        
        return @{
            answer = $formattedAnswer
            source = $memorySource
            confidence = $confidence
        }
    }
    
    # ============= NO MEMORY FOUND - ASK OLLAMA =============
    Write-Host "🤖 No memory matches. Asking Ollama..." -ForegroundColor Yellow
    
    # Check Ollama
    try {
        $models = Invoke-RestMethod -Uri "$($config.OllamaUrl)/api/tags" -TimeoutSec 5 -ErrorAction Stop
        $availableModels = $models.models | ForEach-Object { $_.name }
        
        if ($availableModels.Count -eq 0) {
            return @{
                answer = "I'm Mira, your AI assistant. I can help answer questions about the MiraTV system."
                source = "fallback"
                confidence = 0.5
            }
        }
        
        if ($availableModels -notcontains $config.AIModel -and $availableModels.Count -gt 0) {
            $config.AIModel = $availableModels[0]
        }
    } catch {
        return @{
            answer = "I'm Mira, your AI assistant. I can help you with questions about the MiraTV system."
            source = "fallback"
            confidence = 0.5
        }
    }
    
    # Ask Ollama with system-specific context
    $prompt = @"
You are MiraTV AI assistant, specialized in the MiraTV ingest system.

The MiraTV system has these types of procedures and services:
- Spine Scheduler (manages spine scheduling)
- CVI Watcher (monitors CVI files)
- Telemetry Watcher (tracks telemetry data)
- Spool Uploader (handles spool file uploads)
- AI Learning Loop (manages AI learning)
- Learning Loop (knowledge mining)
- Accessory Loop (accessory file processing)
- Runner Loop (main execution loop)

The user asks: $Question

If they're asking about procedures, services, or capabilities of the MiraTV system, list the actual MiraTV system components.
If they're asking about something else, answer normally but keep it concise.
"@

    $body = @{
        model = $config.AIModel
        prompt = $prompt
        stream = $false
        options = @{ temperature = 0.7 }
    } | ConvertTo-Json
    
    try {
        $response = Invoke-RestMethod -Uri "$($config.OllamaUrl)/api/generate" `
            -Method Post `
            -Body $body `
            -ContentType "application/json"
        
        $answer = $response.response
        $escapedAnswer = $answer -replace "'", "''"
        
        # Store in working memory
        $qId = "q_$(Get-Random -Maximum 9999)"
        $aId = "a_$(Get-Random -Maximum 9999)"
        & $queryScript -Sql @"
INSERT INTO pcde_working_memory (session_id, slot_key, slot_value)
VALUES ('$script:aiSessionId', '$qId', '$escapedQuestion'),
       ('$script:aiSessionId', '$aId', '$escapedAnswer')
"@ 2>$null
        
        return @{
            answer = $answer
            source = "ollama"
            confidence = 0.85
        }
    } catch {
        return @{
            answer = "I'm Mira, your AI assistant. I can help you with questions about the MiraTV system, including its procedures, services, and capabilities."
            source = "fallback"
            confidence = 0.5
        }
    }
}

function Show-ChatHistory {
    if (-not $script:aiSessionId) {
        Write-Host "No active session" -ForegroundColor Yellow
        return
    }
    
    $history = Get-ChatHistory
    
    if ($history) {
        Write-Host "`n📝 Chat History:" -ForegroundColor Cyan
        Write-Host "================"
        
        $lines = $history -split "`n"
        foreach ($line in $lines) {
            if ($line -match 'q_\d+.*?"([^"]+)"') {
                Write-Host "🧑 $($matches[1])" -ForegroundColor White
            }
            if ($line -match 'a_\d+.*?"([^"]+)"') {
                $answerText = $matches[1]
                # Truncate if too long
                if ($answerText.Length -gt 100) {
                    $answerText = $answerText.Substring(0, 100) + "..."
                }
                Write-Host "🤖 $answerText" -ForegroundColor Green
            }
        }
    } else {
        Write-Host "No chat history" -ForegroundColor Yellow
    }
}

function Show-MemoryStats {
    Write-Host "`n📊 MEMORY SYSTEM STATISTICS" -ForegroundColor Cyan
    Write-Host "==========================="
    
    $tables = @(
        @{ Name = "pcde_procedure_registry"; Display = "Procedural Memory" },
        @{ Name = "pcde_declarative_memory"; Display = "Declarative Memory" },
        @{ Name = "pcde_procedure_relations"; Display = "Associative Memory" },
        @{ Name = "pcde_working_memory"; Display = "Working Memory" },
        @{ Name = "pcde_ai_memory"; Display = "AI Learning Memory" },
        @{ Name = "pcde_cognitive_instructions"; Display = "Cognitive Instructions" },
        @{ Name = "pcde_instruction_registry"; Display = "Instruction Registry" },
        @{ Name = "pcde_procedure_execution"; Display = "Procedure Execution" },
        @{ Name = "pcde_procedure_failure"; Display = "Procedure Failure" },
        @{ Name = "pcde_procedure_state"; Display = "Procedure State" },
        @{ Name = "pcde_working_sessions"; Display = "Working Sessions" }
    )
    
    $total = 0
    
    foreach ($table in $tables) {
        $countResult = & $queryScript -Sql "SELECT COUNT(*) as count FROM $($table.Name)" 2>$null
        if ($countResult -match '"count":\s*(\d+)') {
            $count = [int]$matches[1]
            $total += $count
            Write-Host "  $($table.Display): $count entries" -ForegroundColor White
        } else {
            Write-Host "  $($table.Display): 0 entries" -ForegroundColor Gray
        }
    }
    
    Write-Host "`n  TOTAL MEMORY ENTRIES: $total" -ForegroundColor Green
}

# ============= MAIN LOOP =============
do {
    Show-Header
    Show-Status
    Show-Menu
    
    $choice = Read-Host "Enter command"
    
    switch ($choice) {
        # Service Control
        "1" { 
            Write-Host "`n🚀 STARTING ALL SERVICES" -ForegroundColor Cyan
            Start-Service -Name "SpineScheduler" -Path "C:\miratv_ingest\workers\spine\spine_scheduler_total.ps1"
            Start-Service -Name "CVIWatcher" -Path "C:\miratv_ingest\watcher_cvi.ps1"
            Start-Service -Name "TelemetryWatcher" -Path "C:\miratv_ingest\workers\telemetry_watcher.ps1"
            Start-Service -Name "SpoolUploader" -Path "C:\miratv_ingest\spool_uploader.ps1"
            Start-Service -Name "AILearning" -Path "C:\miratv_ingest\workers\GovernanceLearner.ps1"
            Start-Job -Name "LearningLoop" -ScriptBlock {
                while($true) {
                    & "C:\miratv_ingest\workers\KnowledgeMiner.ps1"
                    Start-Sleep -Seconds 300
                }
            }
            Start-Job -Name "AccessoryLoop" -ScriptBlock {
                while($true) {
                    & "C:\miratv_ingest\MASTER_ACCESSORY_UPLOAD_LOOP.bat"
                    Start-Sleep -Seconds 60
                }
            }
            Start-Job -Name "RunnerLoop" -ScriptBlock {
                while($true) {
                    & "C:\miratv_ingest\master_runner_loop.bat"
                    Start-Sleep -Seconds 120
                }
            }
            Start-Job -Name "MasteryAccessoryLoop" -ScriptBlock {
                while($true) {
                    & "C:\miratv_ingest\master_runner_loop_acc.bat"
                    Start-Sleep -Seconds 60
                }
            }
            Start-Job -Name "MainSeriesLoop" -ScriptBlock {
                while($true) {
                    & "C:\miratv_ingest\master_runner_loop.bat"
                    Start-Sleep -Seconds 120
                }
            }
            Start-Job -Name "MasterUploadLoop" -ScriptBlock {
                while($true) {
                    & "C:\miratv_ingest\MASTER_UPLOAD_LOOP.bat"
                    Start-Sleep -Seconds 60
                }
            }
            Write-Host "✅ All services started" -ForegroundColor Green
            Read-Host "Press Enter to continue"
        }
        "2" { 
            Get-Job | Stop-Job
            Get-Job | Remove-Job
            Write-Host "✅ All services stopped" -ForegroundColor Green
            Read-Host "Press Enter to continue"
        }
        "3" { 
            Get-Job | Format-Table Name, State, HasMoreData -AutoSize
            Read-Host "Press Enter to continue"
        }
        
        # Core Services
        "4" { Start-Service -Name "SpineScheduler" -Path "C:\miratv_ingest\workers\spine\spine_scheduler_total.ps1"; Read-Host "Press Enter" }
        "5" { Start-Service -Name "CVIWatcher" -Path "C:\miratv_ingest\watcher_cvi.ps1"; Read-Host "Press Enter" }
        "6" { Start-Service -Name "TelemetryWatcher" -Path "C:\miratv_ingest\workers\telemetry_watcher.ps1"; Read-Host "Press Enter" }
        "7" { Start-Service -Name "SpoolUploader" -Path "C:\miratv_ingest\spool_uploader.ps1"; Read-Host "Press Enter" }
        "8" { 
            Start-Job -Name "AILearning" -ScriptBlock {
                while($true) {
                    & "C:\miratv_ingest\workers\GovernanceLearner.ps1"
                    Start-Sleep -Seconds 300
                }
            }
            Write-Host "✅ AI Learning started" -ForegroundColor Green
            Read-Host "Press Enter to continue"
        }
        
        # Learning Loop Services
        "9" { 
            Start-Job -Name "LearningLoop" -ScriptBlock {
                while($true) {
                    & "C:\miratv_ingest\workers\KnowledgeMiner.ps1"
                    Start-Sleep -Seconds 300
                }
            }
            Write-Host "✅ Learning Loop started" -ForegroundColor Green
            Read-Host "Press Enter to continue"
        }
        "10" { 
            Start-Job -Name "AccessoryLoop" -ScriptBlock {
                while($true) {
                    & "C:\miratv_ingest\MASTER_ACCESSORY_UPLOAD_LOOP.bat"
                    Start-Sleep -Seconds 60
                }
            }
            Write-Host "✅ Accessory Loop started" -ForegroundColor Green
            Read-Host "Press Enter to continue"
        }
        "11" { 
            Start-Job -Name "RunnerLoop" -ScriptBlock {
                while($true) {
                    & "C:\miratv_ingest\master_runner_loop.bat"
                    Start-Sleep -Seconds 120
                }
            }
            Write-Host "✅ Runner Loop started" -ForegroundColor Green
            Read-Host "Press Enter to continue"
        }
        
        # AI Display Commands
        "12" { Show-AILearnings; Read-Host "Press Enter to continue" }
        "13" { Show-WorkingMemory; Read-Host "Press Enter to continue" }
        "14" { 
            & "C:\miratv_ingest\workers\GovernanceLearner.ps1"
            Read-Host "Press Enter to continue"
        }
        
        # Database Commands
        "15" { 
            $sql = Read-Host "Enter SQL"
            & $queryScript -Sql $sql
            Read-Host "Press Enter to continue"
        }
        "16" { 
            $result = & $queryScript -Sql "SELECT * FROM pcde_ai_memory"
            $result | Out-File "ai_memory_export_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
            Write-Host "✅ Export complete" -ForegroundColor Green
            Read-Host "Press Enter to continue"
        }
        
        # Additional Processes (ported safely from Master_Control9)
        "17" {
            Start-Job -Name "MasteryAccessoryLoop" -ScriptBlock {
                while($true) {
                    & "C:\miratv_ingest\master_runner_loop_acc.bat"
                    Start-Sleep -Seconds 60
                }
            }
            Write-Host "✅ Mastery Accessory Loop started" -ForegroundColor Green
            Read-Host "Press Enter to continue"
        }
        "18" {
            Start-Job -Name "MainSeriesLoop" -ScriptBlock {
                while($true) {
                    & "C:\miratv_ingest\master_runner_loop.bat"
                    Start-Sleep -Seconds 120
                }
            }
            Write-Host "✅ Main Series Loop started" -ForegroundColor Green
            Read-Host "Press Enter to continue"
        }
        "19" {
            Start-Job -Name "MasterUploadLoop" -ScriptBlock {
                while($true) {
                    & "C:\miratv_ingest\MASTER_UPLOAD_LOOP.bat"
                    Start-Sleep -Seconds 60
                }
            }
            Write-Host "✅ Master Upload Loop started" -ForegroundColor Green
            Read-Host "Press Enter to continue"
        }
        "25" {
            if (Test-Path "C:\miratv_ingest\Find-FileRelationships.ps1") {
                & "C:\miratv_ingest\Find-FileRelationships.ps1"
                Write-Host "✅ Relationship Finder executed" -ForegroundColor Green
            } else {
                Write-Host "⚠️ Relationship Finder script not found: C:\miratv_ingest\Find-FileRelationships.ps1" -ForegroundColor Yellow
            }
            Read-Host "Press Enter to continue"
        }
        
        # AI Chat Commands
        "20" { 
            Enter-AIChatLoop
        }
        "21" { 
            $question = Read-Host "`nYour question"
            $result = Ask-AI -Question $question
            if ($result) {
                Write-Host "`n🤖 [$($result.source)] $($result.answer)" -ForegroundColor Green
            }
            Read-Host "`nPress Enter to continue"
        }
        "22" { 
            Show-ChatHistory
            Read-Host "Press Enter to continue"
        }
        "23" { 
            $script:aiSessionId = $null
            Write-Host "✅ Chat session cleared" -ForegroundColor Green
            Read-Host "Press Enter to continue"
        }
        "24" { 
            Show-MemoryStats
            Read-Host "Press Enter to continue"
        }
        
        "99" { 
            Write-Host "Shutting down..." -ForegroundColor Red
            break
        }
        default { 
            Write-Host "Invalid option" -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
} while ($choice -ne "99")