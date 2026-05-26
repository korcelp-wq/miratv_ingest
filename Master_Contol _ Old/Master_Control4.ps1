#!/usr/bin/env pwsh
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
        $ollamaTest = Invoke-RestMethod -Uri "$($config.OllamaUrl)/api/tags" -TimeoutSec 9 -ErrorAction SilentlyContinue
        if ($ollamaTest.models) {
            $modelNames = $ollamaTest.models | ForEach-Object { $_.name }
            Write-Host "✅ Ollama: Connected (Models: $($modelNames -join ', '))" -ForegroundColor Green
        } else {
            Write-Host "⚠️ Ollama: Connected but no models" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "⚠️ Ollama: Not connected (local AI unavailable)" -ForegroundColor Yellow
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
    Write-Host "  🤖 GENERATIVE AI (NEW):" -ForegroundColor Magenta
    Write-Host "   20) Start AI Chat Session"
    Write-Host "   21) Ask AI a Question"
    Write-Host "   22) Show Chat History"
    Write-Host "   23) Clear Chat Session"
    Write-Host "   24) Show AI Memory Stats"
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

# ============= NEW AI FUNCTIONS =============
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

function Ask-AI {
    param([string]$Question)
    
    if (-not $script:aiSessionId) {
        Write-Host "⚠️ No active session. Starting new session..." -ForegroundColor Yellow
        Start-AISession
    }
    
    Write-Host "`n🤔 Asking AI: $Question" -ForegroundColor Cyan
    
    # Escape quotes for SQL
    $escapedQuestion = $Question -replace "'", "''"
    
    # 1. Check AI memory first
    $memory = & $queryScript -Sql @"
SELECT key_data, confidence 
FROM pcde_ai_memory 
WHERE key_data LIKE '%$escapedQuestion%'
ORDER BY confidence DESC 
LIMIT 1
"@
    
    if ($memory -and $memory -match '"confidence":\s*([\d\.]+)') {
        $conf = [double]$matches[1]
        if ($conf -gt $config.MinConfidenceForMemory) {
            Write-Host "✅ Found in memory (confidence: $conf)" -ForegroundColor Green
            
            # Extract answer
            if ($memory -match '"key_data":\s*"([^"]+)"') {
                $answer = $matches[1]
                
                # Store in working memory
                $qId = "q_$(Get-Random -Maximum 9999)"
                $aId = "a_$(Get-Random -Maximum 9999)"
                & $queryScript -Sql @"
INSERT INTO pcde_working_memory (session_id, slot_key, slot_value)
VALUES ('$script:aiSessionId', '$qId', '$escapedQuestion'),
       ('$script:aiSessionId', '$aId', '$answer')
"@
                
                return @{
                    answer = $answer
                    source = "memory"
                    confidence = $conf
                }
            }
        }
    }
    
    # 2. Ask Ollama
    Write-Host "🤖 Asking Ollama..." -ForegroundColor Yellow
    
    # Verify model exists
    try {
        $models = Invoke-RestMethod -Uri "$($config.OllamaUrl)/api/tags" -TimeoutSec 5
        $availableModels = $models.models | ForEach-Object { $_.name }
        
        if ($availableModels -notcontains $config.AIModel) {
            Write-Host "⚠️ Model '$($config.AIModel)' not found. Available: $($availableModels -join ', ')" -ForegroundColor Yellow
            Write-Host "   Using first available model: $($availableModels[0])" -ForegroundColor Cyan
            $config.AIModel = $availableModels[0]
        }
    } catch {
        Write-Host "❌ Cannot connect to Ollama. Is it running?" -ForegroundColor Red
        return @{
            answer = "Ollama not connected. Please start Ollama first."
            source = "error"
            confidence = 0
        }
    }
    
    $prompt = @"
You are MiraTV AI assistant. Answer the question concisely.

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
"@
        
        return @{
            answer = $answer
            source = "ollama"
            confidence = 0.85
        }
    } catch {
        return @{
            answer = "Error connecting to AI: $_"
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
                Write-Host "🤖 $($matches[1])" -ForegroundColor Green
            }
        }
    } else {
        Write-Host "No chat history" -ForegroundColor Yellow
    }
}

function Show-AIStats {
    $memCount = & $queryScript -Sql "SELECT COUNT(*) as count FROM pcde_ai_memory"
    $decCount = & $queryScript -Sql "SELECT COUNT(*) as count FROM pcde_declarative_memory"
    $procCount = & $queryScript -Sql "SELECT COUNT(*) as count FROM pcde_procedure_registry"
    $relCount = & $queryScript -Sql "SELECT COUNT(*) as count FROM pcde_procedure_relations"
    
    Write-Host "`n📊 DATABASE STATS" -ForegroundColor Cyan
    Write-Host "================"
    if ($memCount -match '"count":\s*(\d+)') { Write-Host "AI Memory: $($matches[1]) entries" -ForegroundColor White }
    if ($decCount -match '"count":\s*(\d+)') { Write-Host "Declarative: $($matches[1]) entries" -ForegroundColor White }
    if ($procCount -match '"count":\s*(\d+)') { Write-Host "Procedures: $($matches[1]) entries" -ForegroundColor White }
    if ($relCount -match '"count":\s*(\d+)') { Write-Host "Relations: $($matches[1]) entries" -ForegroundColor White }
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
            Start-AISession
            Read-Host "Press Enter to continue"
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
            Show-AIStats
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