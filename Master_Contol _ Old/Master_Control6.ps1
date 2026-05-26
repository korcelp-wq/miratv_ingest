﻿#!/usr/bin/env pwsh
# Master Control Console for PCDE - WITH AI CHAT

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$queryScript = "$scriptPath\dashboard\Query.ps1"
$logDir = "$scriptPath\logs"

# Create log directory if it doesn't exist
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# Configuration - FIXED: Using correct model name from your Ollama list
$config = @{
    AIProvider = "ollama"
    AIModel = "llama3.2:latest"  # Changed from 'llama3.2:3b' to match your installed model
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
    
    # Check Ollama with better diagnostics
    try {
        $ollamaTest = Invoke-RestMethod -Uri "$($config.OllamaUrl)/api/tags" -TimeoutSec 5 -ErrorAction Stop
        if ($ollamaTest.models) {
            $modelNames = $ollamaTest.models | ForEach-Object { $_.name }
            Write-Host "✅ Ollama: Connected (Models: $($modelNames -join ', '))" -ForegroundColor Green
            
            # Check if configured model exists
            if ($modelNames -notcontains $config.AIModel) {
                Write-Host "⚠️  Model '$($config.AIModel)' not found. Available: $($modelNames -join ', ')" -ForegroundColor Yellow
                Write-Host "   Run 'ollama pull $($config.AIModel)' to download it" -ForegroundColor Yellow
            }
        }
    } catch {
        Write-Host "❌ Ollama: Connection failed" -ForegroundColor Red
        Write-Host "   Check if:" -ForegroundColor Yellow
        Write-Host "   • Ollama is installed (run 'ollama list' in PowerShell)" -ForegroundColor Yellow
        Write-Host "   • Ollama service is running (check task manager)" -ForegroundColor Yellow
        Write-Host "   • Port 11434 is not blocked" -ForegroundColor Yellow
    }
    
    # Get all running jobs
    $jobs = Get-Job
    
    # Service mapping with menu options - ALL SERVICES ARE CONTROLLABLE
    $serviceMap = @{
        # Core services (menu options 4-8)
        'SpineScheduler' = @{ name = 'Spine Scheduler'; menu = '4' }
        'CVIWatcher' = @{ name = 'CVI Watcher'; menu = '5' }
        'TelemetryWatcher' = @{ name = 'Telemetry Watcher'; menu = '6' }
        'SpoolUploader' = @{ name = 'Spool Uploader'; menu = '7' }
        'AILearning' = @{ name = 'AI Learning Loop'; menu = '8' }
        
        # Learning Loops (menu options 9-11) - THESE ARE SERVICES NOW
        'LearningLoop' = @{ name = 'Learning Loop'; menu = '9' }
        'AccessoryLoop' = @{ name = 'Accessory Loop'; menu = '10' }
        'RunnerLoop' = @{ name = 'Runner Loop'; menu = '11' }
    }
    
    Write-Host ""
    Write-Host "🔄 ACTIVE SERVICES:" -ForegroundColor Yellow
    
    # Core Services (menu options 4-8)
    Write-Host "  CORE SERVICES (4-8):" -ForegroundColor Cyan
    
    $coreServices = @('SpineScheduler', 'CVIWatcher', 'TelemetryWatcher', 'SpoolUploader', 'AILearning')
    $coreRunning = $false
    
    foreach ($service in $coreServices) {
        $job = $jobs | Where-Object { $_.Name -eq $service }
        $info = $serviceMap[$service]
        
        if ($job -and $job.State -eq 'Running') {
            Write-Host "    ✅ [$($info.menu)] $($info.name)" -ForegroundColor Green
            $coreRunning = $true
        } else {
            Write-Host "    ⏸️ [$($info.menu)] $($info.name)" -ForegroundColor Gray
        }
    }
    
    if (-not $coreRunning) {
        Write-Host "    (none running)" -ForegroundColor Gray
    }
    
    # Learning Loops (menu options 9-11) - NOW SHOWN AS SERVICES
    Write-Host ""
    Write-Host "  LEARNING LOOP SERVICES (9-11):" -ForegroundColor Cyan
    
    $loopServices = @('LearningLoop', 'AccessoryLoop', 'RunnerLoop')
    $loopRunning = $false
    
    foreach ($service in $loopServices) {
        $job = $jobs | Where-Object { $_.Name -eq $service }
        $info = $serviceMap[$service]
        
        if ($job -and $job.State -eq 'Running') {
            Write-Host "    ✅ [$($info.menu)] $($info.name)" -ForegroundColor Green
            $loopRunning = $true
        } else {
            Write-Host "    ⏸️ [$($info.menu)] $($info.name)" -ForegroundColor Gray
        }
    }
    
    if (-not $loopRunning) {
        Write-Host "    (none running)" -ForegroundColor Gray
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
    Write-Host "  99) Exit"
    Write-Host ""
}

function Show-AILearnings {
    $result = & $queryScript -Sql "SELECT memory_id, confidence, LEFT(key_data,100) as preview, created_at FROM pcde_ai_memory ORDER BY confidence DESC LIMIT 10"
    
    if ($result) {
        Write-Host "`n🧠 TOP AI LEARNINGS" -ForegroundColor Cyan
        Write-Host "=================="
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

# ============= ENHANCED AI FUNCTIONS =============
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
        if ($_.Exception.Message -match "timeout") {
            Write-Host "  ⏱️ SQL Timeout after $($config.SQLTimeout) seconds" -ForegroundColor Yellow
        } else {
            Write-Host "  ❌ SQL Error: $_" -ForegroundColor Red
        }
        return $null
    }
}

function Start-AISession {
    param([string]$SessionId = (New-Guid).ToString())
    
    Write-Host "`n🚀 Starting AI Session..." -ForegroundColor Yellow
    
    # First, let's try to create the table if it doesn't exist
    $createTable = @"
CREATE TABLE IF NOT EXISTS pcde_working_sessions (
    session_id VARCHAR(64) PRIMARY KEY,
    session_type VARCHAR(32) DEFAULT 'ai_chat',
    status VARCHAR(20) DEFAULT 'active',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_activity TIMESTAMP NULL
)
"@
    Invoke-SQLDirect -Sql $createTable | Out-Null
    
    # Now try to insert with minimal fields
    $sql = "INSERT INTO pcde_working_sessions (session_id) VALUES ('$SessionId')"
    
    try {
        $result = Invoke-SQLDirect -Sql $sql
        Write-Host "✅ AI Session started (ID: $($SessionId.Substring(0,8))...)" -ForegroundColor Green
        $script:aiSessionId = $SessionId
    }
    catch {
        Write-Host "⚠️ Could not record session in database, but continuing..." -ForegroundColor Yellow
        $script:aiSessionId = $SessionId
    }
    
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

# Helper function to test memory confidence
function Test-MemoryConfidence {
    param([string]$Result, [double]$MinConfidence = 0.6)
    
    if (-not $Result) { return $false }
    
    # Try to extract confidence if present
    if ($Result -match '"confidence":\s*([\d\.]+)') {
        return [double]$matches[1] -ge $MinConfidence
    }
    
    # If no confidence field but we have data, assume moderate confidence
    return $Result -match '"key_data"' -or $Result -match '"procedure_name"' -or $Result -match '"fact"'
}

# Helper function to format memory results nicely
function Format-MemoryResult {
    param(
        [string]$Result,
        [string]$Source,
        [string]$Question
    )
    
    $sourceIcons = @{
        "procedural" = "📋"
        "declarative" = "📚"
        "associative" = "🔗"
        "working" = "💭"
        "ai_memory" = "🧠"
        "ollama" = "🤖"
        "error" = "⚠️"
    }
    
    $icon = if ($sourceIcons.ContainsKey($Source)) { $sourceIcons[$Source] } else { "📌" }
    
    # Check if result is empty JSON
    if ($Result -match '"rows":\s*\[\s*\]' -or $Result -match '^\s*$') {
        return "$icon No relevant information found in $Source memory."
    }
    
    # Try to parse and format the result nicely
    $output = @"
$icon Found in $Source memory:

$Result
"@
    
    return $output
}

function Ask-AI {
    param([string]$Question)
    
    if (-not $script:aiSessionId) {
        Write-Host "⚠️ No active session. Starting new session..." -ForegroundColor Yellow
        Start-AISession
    }
    
    Write-Host "`n🤔 Asking AI: $Question" -ForegroundColor Cyan
    Write-Host "🔍 Searching memory hierarchy..." -ForegroundColor Yellow
    
    # Escape quotes for SQL
    $escapedQuestion = $Question -replace "'", "''"
    
    # Extract keywords for better searching (remove common words)
    $keywords = $Question -split '\s+' | Where-Object { 
        $_.Length -gt 3 -and $_ -notmatch '^(who|what|where|when|why|how|are|you|your|and|the|for|with|that)$' 
    } | ForEach-Object { $_.Trim('?.,!;:') }
    
    $keywordPattern = if ($keywords.Count -gt 0) {
        ($keywords | ForEach-Object { "%$_%" }) -join "' OR description LIKE '"
    } else {
        "%$escapedQuestion%"
    }
    
    # Helper function for safe SQL execution
    function Safe-SqlQuery {
        param([string]$Sql, [string]$Context)
        
        Write-Host "   Executing: $Context..." -ForegroundColor Gray
        try {
            $result = & $queryScript -Sql $Sql 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $result) {
                return $null
            }
            # Check if result has actual data (not just empty JSON)
            if ($result -match '"rows":\s*\[\s*\]' -or $result -match 'rows":\[\]') {
                return $null
            }
            return $result
        } catch {
            Write-Host "   ⚠️ Query failed (continuing search...)" -ForegroundColor DarkYellow
            return $null
        }
    }
    
    # ============= HIERARCHICAL MEMORY SEARCH =============
    $memoryResult = $null
    $memorySource = ""
    $confidence = 0
    
    # 1. PROCEDURAL MEMORY - First priority (how-to knowledge)
    Write-Host "   📋 Checking Procedural Memory..." -ForegroundColor Gray
    $proceduralSql = @"
SELECT procedure_id, procedure_name, description, parameters, confidence_score, usage_count
FROM pcde_procedure_registry 
WHERE procedure_name LIKE '%$escapedQuestion%' 
   OR description LIKE '%$escapedQuestion%'
   OR tags LIKE '%$escapedQuestion%'
   OR parameters LIKE '%$escapedQuestion%'
ORDER BY confidence_score DESC, usage_count DESC
LIMIT 3
"@
    
    $procedural = Safe-SqlQuery -Sql $proceduralSql -Context "Procedural Memory"
    
    if ($procedural) {
        Write-Host "   ✅ Found in Procedural Memory" -ForegroundColor Green
        $memoryResult = $procedural
        $memorySource = "procedural"
        $confidence = 0.9
    }
    
    # 2. DECLARATIVE MEMORY - Facts and knowledge
    if (-not $memoryResult) {
        Write-Host "   📚 Checking Declarative Memory..." -ForegroundColor Gray
        $declarativeSql = @"
SELECT memory_id, fact, category, confidence, source, created_at, access_count
FROM pcde_declarative_memory 
WHERE fact LIKE '%$escapedQuestion%' 
   OR keywords LIKE '%$escapedQuestion%'
   OR category LIKE '%$escapedQuestion%'
   OR source LIKE '%$escapedQuestion%'
ORDER BY confidence DESC, access_count DESC
LIMIT 3
"@
        
        $declarative = Safe-SqlQuery -Sql $declarativeSql -Context "Declarative Memory"
        
        if ($declarative) {
            Write-Host "   ✅ Found in Declarative Memory" -ForegroundColor Green
            $memoryResult = $declarative
            $memorySource = "declarative"
            $confidence = 0.85
        }
    }
    
    # 3. ASSOCIATIVE MEMORY - Relationships and patterns
    if (-not $memoryResult) {
        Write-Host "   🔗 Checking Associative Memory..." -ForegroundColor Gray
        $associativeSql = @"
SELECT relation_id, procedure_id, related_procedure_id, relation_type, strength, pattern, notes
FROM pcde_procedure_relations 
WHERE relation_type LIKE '%$escapedQuestion%'
   OR pattern LIKE '%$escapedQuestion%'
   OR notes LIKE '%$escapedQuestion%'
ORDER BY strength DESC
LIMIT 5
"@
        
        $associative = Safe-SqlQuery -Sql $associativeSql -Context "Associative Memory"
        
        if ($associative) {
            Write-Host "   ✅ Found in Associative Memory" -ForegroundColor Green
            $memoryResult = $associative
            $memorySource = "associative"
            $confidence = 0.8
        }
    }
    
    # 4. WORKING MEMORY - Recent context
    if (-not $memoryResult) {
        Write-Host "   💭 Checking Working Memory..." -ForegroundColor Gray
        $workingSql = @"
SELECT wm.slot_key, wm.slot_value, wm.created_at
FROM pcde_working_memory wm
WHERE wm.session_id = '$script:aiSessionId'
   AND wm.slot_value LIKE '%$escapedQuestion%'
   AND wm.expires_at > NOW()
ORDER BY wm.created_at DESC
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
    
    # 5. AI MEMORY - Previously learned patterns
    if (-not $memoryResult) {
        Write-Host "   🧠 Checking AI Learning Memory..." -ForegroundColor Gray
        $aiMemorySql = @"
SELECT memory_id, key_data, confidence, created_at, context
FROM pcde_ai_memory 
WHERE key_data LIKE '%$escapedQuestion%'
   OR context LIKE '%$escapedQuestion%'
ORDER BY confidence DESC, access_count DESC
LIMIT 3
"@
        
        $aiMemory = Safe-SqlQuery -Sql $aiMemorySql -Context "AI Memory"
        
        if ($aiMemory) {
            Write-Host "   ✅ Found in AI Memory" -ForegroundColor Green
            $memoryResult = $aiMemory
            $memorySource = "ai_memory"
            # Extract confidence if available
            if ($aiMemory -match '"confidence":\s*([\d\.]+)') {
                $confidence = [double]$matches[1]
            } else {
                $confidence = 0.8
            }
        }
    }
    
    # If we found something in memory, format and return it
    if ($memoryResult) {
        Write-Host "✅ Using $memorySource memory (confidence: $confidence)" -ForegroundColor Green
        
        # Format the response
        $formattedAnswer = Format-MemoryResult -Result $memoryResult -Source $memorySource -Question $Question
        
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
    Write-Host "🤖 No relevant memory found. Asking Ollama..." -ForegroundColor Yellow
    
    # Check Ollama connection
    try {
        $models = Invoke-RestMethod -Uri "$($config.OllamaUrl)/api/tags" -TimeoutSec 5 -ErrorAction Stop
        $availableModels = $models.models | ForEach-Object { $_.name }
        
        if ($availableModels.Count -eq 0) {
            return @{
                answer = "No models found in Ollama. Please pull a model first using: ollama pull $($config.AIModel)"
                source = "error"
                confidence = 0
            }
        }
        
        if ($availableModels -notcontains $config.AIModel) {
            Write-Host "⚠️ Model '$($config.AIModel)' not found. Using: $($availableModels[0])" -ForegroundColor Yellow
            $config.AIModel = $availableModels[0]
        }
    } catch {
        return @{
            answer = "I am MiraTV AI Assistant, but I'm currently having trouble connecting to my language model. Please ensure Ollama is running with: ollama serve"
            source = "error"
            confidence = 0
        }
    }
    
    # System prompt for Ollama
    $prompt = @"
You are MiraTV AI assistant, a helpful cognitive systems expert. Respond conversationally and concisely.

Question: $Question
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
            answer = "I am MiraTV AI Assistant. I can help you with questions about the system, but I'm having trouble connecting to my language model right now. Please check that Ollama is running."
            source = "error"
            confidence = 0
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
        
        # Parse and display history
        $lines = $history -split "`n"
        foreach ($line in $lines) {
            if ($line -match 'q_\d+.*?"([^"]+)"') {
                Write-Host "🧑 $($matches[1])" -ForegroundColor White
            }
            if ($line -match 'a_\d+.*?"([^"]+)"') {
                # Try to extract just the answer part without the formatting
                $answerText = $matches[1]
                if ($answerText -match "Found in .*? memory:.*?---(.*?)---") {
                    $answerText = $matches[1].Trim()
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
    
    $stats = @()
    $total = 0
    
    # Get table list from your screenshot
    $tables = @(
        @{ Name = "pcde_procedure_registry"; Display = "Procedural Memory"; Priority = 1 },
        @{ Name = "pcde_declarative_memory"; Display = "Declarative Memory"; Priority = 2 },
        @{ Name = "pcde_procedure_relations"; Display = "Associative Memory (Relations)"; Priority = 3 },
        @{ Name = "pcde_working_memory"; Display = "Working Memory (Active)"; Priority = 4; Where = "WHERE expires_at > NOW()" },
        @{ Name = "pcde_working_sessions"; Display = "Working Sessions"; Priority = 5 },
        @{ Name = "pcde_ai_memory"; Display = "AI Learning Memory"; Priority = 6 },
        @{ Name = "pcde_cognitive_instructions"; Display = "Cognitive Instructions"; Priority = 7 },
        @{ Name = "pcde_declarative_procedure_links"; Display = "Declarative-Procedure Links"; Priority = 8 },
        @{ Name = "pcde_id_mapping"; Display = "ID Mapping"; Priority = 9 },
        @{ Name = "pcde_ingest_stage_docs"; Display = "Ingest Stage Docs"; Priority = 10 },
        @{ Name = "pcde_instruction_registry"; Display = "Instruction Registry"; Priority = 11 },
        @{ Name = "pcde_mentor_escalation_queue"; Display = "Mentor Escalation Queue"; Priority = 12 },
        @{ Name = "pcde_procedure_execution"; Display = "Procedure Execution"; Priority = 13 },
        @{ Name = "pcde_procedure_failure"; Display = "Procedure Failure"; Priority = 14 },
        @{ Name = "pcde_procedure_igm_ref"; Display = "Procedure IGM References"; Priority = 15 },
        @{ Name = "pcde_procedure_state"; Display = "Procedure State"; Priority = 16 },
        @{ Name = "pcde_registry_meta"; Display = "Registry Metadata"; Priority = 17 }
    )
    
    # Check for lake_knowledge
    $tableCheck = & $queryScript -Sql "SHOW TABLES LIKE 'lake_knowledge'"
    if ($tableCheck) {
        $tables += @{ Name = "lake_knowledge"; Display = "Long-term Memory (Lake)"; Priority = 4.5 }
    }
    
    foreach ($table in $tables | Sort-Object Priority) {
        $whereClause = if ($table.Where) { $table.Where } else { "" }
        $countResult = & $queryScript -Sql "SELECT COUNT(*) as count FROM $($table.Name) $whereClause"
        
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
        
        # Core Services (4-8)
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
        
        # Learning Loop Services (9-11) - NOW CONTROLLABLE
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
        
        # AI Display Commands (12-14)
        "12" { Show-AILearnings; Read-Host "Press Enter to continue" }
        "13" { Show-WorkingMemory; Read-Host "Press Enter to continue" }
        "14" { 
            & "C:\miratv_ingest\workers\GovernanceLearner.ps1"
            Read-Host "Press Enter to continue"
        }
        
        # Database Commands (15-16)
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
        
        # NEW AI Commands (20-24)
        "20" { 
            Enter-AIChatLoop
            # No Read-Host needed here since Enter-AIChatLoop has its own loop
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