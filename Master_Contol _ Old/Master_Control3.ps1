#!/usr/bin/env pwsh
# Master Control with FULL AI Integration

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$dashboardQuery = "$scriptPath\dashboard\Query.ps1"
$logDir = "$scriptPath\logs"

# Create log directory if it doesn't exist
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# Configuration
$config = @{
    LearningLoopInterval = 300
    AccessoryLoopInterval = 60
    RunnerLoopInterval = 120
    LogRetentionDays = 7
    # AI Settings
    AIProvider = "ollama"
    AIModel = "llama3.2:3b"
    OllamaUrl = "http://localhost:11434"
    MaxContextItems = 5
    MinConfidenceForMemory = 0.85
}

# Job tracking
$jobs = @{}
$aiSessionId = $null
$token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$cviEndpoint = "https://miratv.club/_workers/api/series/dog_open.php"

# Function to run SQL via CVI
function Invoke-SQL {
    param([string]$Sql, [string]$Db = "pcde_memory")
    
    $body = @{
        token = $token
        db = $Db
        sql = $Sql
        params = @()
    } | ConvertTo-Json
    
    try {
        return Invoke-RestMethod -Uri $cviEndpoint -Method Post -Body $body -ContentType "application/json"
    }
    catch {
        Write-Host "  ❌ SQL Error: $_" -ForegroundColor Red
        return $null
    }
}

function Show-Header {
    Clear-Host
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║     🎮 MIRATV MASTER CONTROL with LOCAL AI              ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Status {
    Write-Host "📊 SYSTEM STATUS" -ForegroundColor Yellow
    Write-Host "================"
    
    # Database connection test
    $test = & $dashboardQuery -Sql "SELECT 1 as test" 2>$null
    if ($test -match "rows") {
        Write-Host "✅ Database: Connected to pcde_memory" -ForegroundColor Green
    } else {
        Write-Host "❌ Database: Connection failed" -ForegroundColor Red
    }
    
    # Ollama connection test
    try {
        $ollamaTest = Invoke-RestMethod -Uri "$($config.OllamaUrl)/api/tags" -TimeoutSec 9
        if ($ollamaTest.models) {
            Write-Host "✅ Ollama: Connected ($($ollamaTest.models[0].name))" -ForegroundColor Green
        } else {
            Write-Host "⚠️ Ollama: Connected but no models" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "❌ Ollama: Not connected" -ForegroundColor Red
    }
    
    # Show running jobs
    $runningJobs = Get-Job | Where-Object { $_.State -eq 'Running' }
    Write-Host ""
    Write-Host "🔄 RUNNING PROCESSES:" -ForegroundColor Yellow
    if ($runningJobs.Count -eq 0) {
        Write-Host "  No processes running" -ForegroundColor Gray
    } else {
        foreach ($job in $runningJobs) {
            Write-Host "  ✅ $($job.Name)" -ForegroundColor Green
        }
    }
    
    # Show latest stats
    Write-Host ""
    Write-Host "📈 LATEST STATS:" -ForegroundColor Yellow
    $memCount = & $dashboardQuery -Sql "SELECT COUNT(*) as c FROM pcde_ai_memory" 2>$null
    if ($memCount -match '"c":\s*(\d+)') {
        Write-Host "  🧠 AI Memories: $($matches[1])" -ForegroundColor Cyan
    }
    if ($aiSessionId) {
        Write-Host "  💬 Active AI Session: $($aiSessionId.Substring(0,8))..." -ForegroundColor Cyan
    }
}

# ============= LOOP FUNCTIONS =============
function Start-LearningLoop {
    Write-Host "`n🚀 Starting AI Learning Loop..." -ForegroundColor Yellow
    
    $script = @"
while(`$true) {
    `$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[`$timestamp] 🔍 Running Knowledge Miner..." -ForegroundColor Cyan
    & 'C:\miratv_ingest\workers\KnowledgeMiner.ps1'
    
    Write-Host "[`$timestamp] 🔗 Running Relationship Finder..." -ForegroundColor Cyan
    & 'C:\miratv_ingest\Find-FileRelationships-Final.ps1'
    
    Write-Host "[`$timestamp] 😴 Sleeping for $($config.LearningLoopInterval) seconds..." -ForegroundColor Gray
    Start-Sleep -Seconds $($config.LearningLoopInterval)
}
"@
    
    $jobs['LearningLoop'] = Start-Job -Name "LearningLoop" -ScriptBlock ([scriptblock]::Create($script))
    Write-Host "✅ Learning Loop started" -ForegroundColor Green
}

function Start-AccessoryLoop {
    Write-Host "`n🚀 Starting Accessory Upload Loop..." -ForegroundColor Yellow
    
    $script = @"
while(`$true) {
    `$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[`$timestamp] 📤 Running Accessory Upload..." -ForegroundColor Cyan
    
    & 'C:\miratv_ingest\MASTER_ACCESSORY_UPLOAD_LOOP.bat'
    
    Write-Host "[`$timestamp] 😴 Sleeping for $($config.AccessoryLoopInterval) seconds..." -ForegroundColor Gray
    Start-Sleep -Seconds $($config.AccessoryLoopInterval)
}
"@
    
    $jobs['AccessoryLoop'] = Start-Job -Name "AccessoryLoop" -ScriptBlock ([scriptblock]::Create($script))
    Write-Host "✅ Accessory Upload Loop started" -ForegroundColor Green
}

function Start-RunnerLoop {
    Write-Host "`n🚀 Starting Master Runner Loop..." -ForegroundColor Yellow
    
    $script = @"
while(`$true) {
    `$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[`$timestamp] 🏃 Running Master Runner..." -ForegroundColor Cyan
    
    & 'C:\miratv_ingest\master_runner_loop.bat'
    
    Write-Host "[`$timestamp] 😴 Sleeping for $($config.RunnerLoopInterval) seconds..." -ForegroundColor Gray
    Start-Sleep -Seconds $($config.RunnerLoopInterval)
}
"@
    
    $jobs['RunnerLoop'] = Start-Job -Name "RunnerLoop" -ScriptBlock ([scriptblock]::Create($script))
    Write-Host "✅ Master Runner Loop started" -ForegroundColor Green
}

function Start-AllLoops {
    Write-Host "`n🚀 STARTING ALL LOOPS" -ForegroundColor Magenta
    Write-Host "===================="
    Start-LearningLoop
    Start-AccessoryLoop
    Start-RunnerLoop
    Write-Host "`n✅ All loops started" -ForegroundColor Green
}

function Stop-AllLoops {
    Write-Host "`n🛑 STOPPING ALL LOOPS" -ForegroundColor Red
    Write-Host "==================="
    foreach ($name in $jobs.Keys) {
        if ($jobs[$name]) {
            Stop-Job $jobs[$name]
            Remove-Job $jobs[$name]
            Write-Host "✅ Stopped: $name" -ForegroundColor Green
        }
    }
    $jobs.Clear()
}

# ============= AI FUNCTIONS =============
function Start-AISession {
    param([string]$SessionId = (New-Guid).ToString())
    
    Write-Host "`n🚀 Starting AI Session: $($SessionId.Substring(0,8))..." -ForegroundColor Yellow
    
    $sql = @"
INSERT INTO pcde_working_sessions (session_id, session_type, status, created_at)
VALUES ('$SessionId', 'ai_chat', 'active', NOW())
"@
    & $dashboardQuery -Sql $sql
    
    $script:aiSessionId = $SessionId
    Write-Host "✅ AI Session started" -ForegroundColor Green
    return $SessionId
}

function Ask-AI {
    param([string]$Question)
    
    if (-not $script:aiSessionId) {
        Start-AISession
    }
    
    Write-Host "`n🤔 Asking AI: $Question" -ForegroundColor Cyan
    
    # Escape quotes for SQL
    $escapedQuestion = $Question -replace "'", "''"
    
    # 1. Check AI memory first
    $memory = & $dashboardQuery -Sql @"
SELECT key_data, confidence 
FROM pcde_ai_memory 
WHERE key_data LIKE '%$escapedQuestion%'
ORDER BY confidence DESC 
LIMIT 1
"@
    
    if ($memory.rows -and $memory.rows[0].confidence -gt $config.MinConfidenceForMemory) {
        $answer = $memory.rows[0].key_data
        $escapedAnswer = $answer -replace "'", "''"
        
        & $dashboardQuery -Sql @"
INSERT INTO pcde_working_memory (session_id, slot_key, slot_value)
VALUES ('$script:aiSessionId', 'q_$(Get-Random)', '$escapedQuestion'),
       ('$script:aiSessionId', 'a_$(Get-Random)', '$escapedAnswer')
"@
        
        Write-Host "✅ Found in memory (confidence: $($memory.rows[0].confidence))" -ForegroundColor Green
        return @{
            answer = $answer
            source = "memory"
        }
    }
    
    # 2. Get context from declarative memory
    $context = & $dashboardQuery -Sql @"
SELECT key_data 
FROM pcde_declarative_memory 
WHERE key_data LIKE '%$escapedQuestion%'
LIMIT 3
"@
    
    $contextText = ""
    if ($context.rows) {
        $contextText = ($context.rows | ForEach-Object { $_.key_data }) -join "`n"
    }
    
    # 3. Ask Ollama
    $prompt = @"
You are MiraTV AI assistant with access to system knowledge.

Context:
$contextText

Question: $Question

Answer based on the context. If unsure, say so.
"@

    $body = @{
        model = $config.AIModel
        prompt = $prompt
        stream = $false
        options = @{
            temperature = 0.7
            num_predict = 500
        }
    } | ConvertTo-Json
    
    try {
        Write-Host "🤖 Asking Ollama..." -ForegroundColor Yellow
        $response = Invoke-RestMethod -Uri "$($config.OllamaUrl)/api/generate" `
            -Method Post `
            -Body $body `
            -ContentType "application/json" `
            -ErrorAction Stop
        
        $answer = $response.response
        $escapedAnswer = $answer -replace "'", "''"
        
        # Store in working memory
        & $dashboardQuery -Sql @"
INSERT INTO pcde_working_memory (session_id, slot_key, slot_value)
VALUES ('$script:aiSessionId', 'q_$(Get-Random)', '$escapedQuestion'),
       ('$script:aiSessionId', 'a_$(Get-Random)', '$escapedAnswer')
"@
        
        # Store in long-term memory if it's a good answer
        if ($answer.Length -gt 50 -and -not $answer.Contains("I don't know")) {
            $learnSql = @"
INSERT INTO pcde_ai_memory (agent_name, memory_type, key_data, confidence, created_at)
VALUES ('ollama', 'conversation', 'Q: $escapedQuestion`nA: $escapedAnswer', 0.85, NOW())
"@
            & $dashboardQuery -Sql $learnSql
            Write-Host "💾 Stored in long-term memory" -ForegroundColor Green
        }
        
        return @{
            answer = $answer
            source = "ollama"
        }
    } catch {
        Write-Host "❌ Ollama error: $_" -ForegroundColor Red
        return @{
            answer = "Error connecting to AI: $_"
            source = "error"
        }
    }
}

function Show-ChatHistory {
    if (-not $script:aiSessionId) {
        Write-Host "No active session" -ForegroundColor Yellow
        return
    }
    
    $history = & $dashboardQuery -Sql @"
SELECT slot_key, slot_value, created_at
FROM pcde_working_memory
WHERE session_id = '$script:aiSessionId'
ORDER BY created_at
"@
    
    if ($history.rows) {
        Write-Host "`n📝 Chat History:" -ForegroundColor Cyan
        Write-Host "================"
        foreach ($item in $history.rows) {
            $prefix = if ($item.slot_key -like 'q_*') { "🧑 " } else { "🤖 " }
            $color = if ($item.slot_key -like 'q_*') { "White" } else { "Green" }
            Write-Host "$prefix $($item.slot_value)" -ForegroundColor $color
        }
    } else {
        Write-Host "No chat history" -ForegroundColor Yellow
    }
}

function Show-AIStats {
    $stats = & $dashboardQuery -Sql @"
SELECT 'AI Memory' as type, COUNT(*) as count FROM pcde_ai_memory
UNION SELECT 'Declarative', COUNT(*) FROM pcde_declarative_memory
UNION SELECT 'Procedures', COUNT(*) FROM pcde_procedure_registry
UNION SELECT 'Relations', COUNT(*) FROM pcde_procedure_relations
"@
    
    Write-Host "`n📊 DATABASE STATS" -ForegroundColor Cyan
    Write-Host "================"
    if ($stats.rows) {
        $stats.rows | Format-Table -AutoSize
    }
}

function Show-AIMenu {
    Write-Host ""
    Write-Host "🤖 GENERATIVE AI" -ForegroundColor Magenta
    Write-Host "================"
    Write-Host "   20) Start AI Chat Session"
    Write-Host "   21) Ask AI a Question"
    Write-Host "   22) Show Chat History"
    Write-Host "   23) Clear Chat Session"
    Write-Host "   24) Show AI Memory Stats"
    Write-Host ""
}

function Show-Menu {
    Write-Host ""
    Write-Host "🎮 COMMANDS" -ForegroundColor Magenta
    Write-Host "==========="
    Write-Host ""
    Write-Host "  LOOP CONTROL:" -ForegroundColor White
    Write-Host "    1) Start All Loops"
    Write-Host "    2) Stop All Loops"
    Write-Host "    3) Show Running Loops"
    Write-Host ""
    Write-Host "  INDIVIDUAL LOOPS:" -ForegroundColor White
    Write-Host "    4) Start Learning Loop (AI pattern discovery)"
    Write-Host "    5) Start Accessory Upload Loop"
    Write-Host "    6) Start Master Runner Loop"
    Write-Host ""
    Show-AIMenu
    Write-Host "  MONITORING:" -ForegroundColor White
    Write-Host "   30) Show Database Stats"
    Write-Host "   31) Show Recent Relations"
    Write-Host "   32) Browse AI Memory"
    Write-Host "   33) Show Logs"
    Write-Host ""
    Write-Host "  99) Exit"
    Write-Host ""
}

# Main loop
do {
    Show-Header
    Show-Status
    Show-Menu
    
    $choice = Read-Host "Enter command"
    
    switch ($choice) {
        # Loop commands
        "1" { Start-AllLoops; Read-Host "Press Enter" }
        "2" { Stop-AllLoops; Read-Host "Press Enter" }
        "3" { Get-Job | Format-Table Name, State, PSBeginTime -AutoSize; Read-Host "Press Enter" }
        "4" { Start-LearningLoop; Read-Host "Press Enter" }
        "5" { Start-AccessoryLoop; Read-Host "Press Enter" }
        "6" { Start-RunnerLoop; Read-Host "Press Enter" }
        
        # AI commands
        "20" { 
            Start-AISession
            Read-Host "Press Enter"
        }
        "21" { 
            $question = Read-Host "`nYour question"
            $result = Ask-AI -Question $question
            if ($result) {
                Write-Host "`n🤖 [$($result.source)] $($result.answer)" -ForegroundColor Green
            }
            Read-Host "`nPress Enter"
        }
        "22" { 
            Show-ChatHistory
            Read-Host "`nPress Enter"
        }
        "23" { 
            $script:aiSessionId = $null
            Write-Host "✅ Chat session cleared" -ForegroundColor Green
            Read-Host "Press Enter"
        }
        "24" { 
            Show-AIStats
            Read-Host "Press Enter"
        }
        
        # Monitoring commands
        "30" { Show-AIStats; Read-Host "Press Enter" }
        "31" { & $dashboardQuery -Sql "SELECT * FROM pcde_procedure_relations ORDER BY relation_id DESC LIMIT 10"; Read-Host "Press Enter" }
        "32" { & $dashboardQuery -Sql "SELECT memory_id, LEFT(key_data,80) as preview, confidence FROM pcde_ai_memory ORDER BY confidence DESC LIMIT 15"; Read-Host "Press Enter" }
        "33" { 
            Get-ChildItem $logDir -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3 | ForEach-Object { 
                Write-Host "$($_.Name) - $($_.LastWriteTime)" 
                Get-Content $_.FullName -Tail 3 -ErrorAction SilentlyContinue
            }
            Read-Host "Press Enter" 
        }
        
        "99" { 
            $confirm = Read-Host "Stop all loops before exiting? (y/n)"
            if ($confirm -eq 'y') { Stop-AllLoops }
            Write-Host "Goodbye!" -ForegroundColor Green
            break
        }
        default { 
            Write-Host "Invalid option" -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
} while ($choice -ne "99")