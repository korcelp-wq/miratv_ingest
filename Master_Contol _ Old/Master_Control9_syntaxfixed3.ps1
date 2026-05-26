#!/usr/bin/env pwsh
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
    
    # Service mapping with all processes
    $serviceMap = @{
        # Core services
        'SpineScheduler' = @{ name = 'Spine Scheduler'; menu = '4' }
        'CVIWatcher' = @{ name = 'CVI Watcher'; menu = '5' }
        'TelemetryWatcher' = @{ name = 'Telemetry Watcher'; menu = '6' }
        'SpoolUploader' = @{ name = 'Spool Uploader'; menu = '7' }
        'AILearning' = @{ name = 'AI Learning Loop'; menu = '8' }
        
        # Learning Loops
        'LearningLoop' = @{ name = 'Learning Loop'; menu = '9' }
        'AccessoryLoop' = @{ name = 'Accessory Loop'; menu = '10' }
        'RunnerLoop' = @{ name = 'Runner Loop'; menu = '11' }
        
        # Additional Processes
        'MasteryAccessoryLoop' = @{ name = 'Mastery Accessory Loop'; menu = '12' }
        'MainSeriesLoop' = @{ name = 'Main Series Loop'; menu = '13' }
        'MasterUploadLoop' = @{ name = 'Master Upload Loop'; menu = '14' }
        'RelationshipFinder' = @{ name = 'Relationship Finder'; menu = '15' }
    }
    
    Write-Host ""
    Write-Host "🔄 ACTIVE SERVICES:" -ForegroundColor Yellow
    
    # Core Services (4-8)
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
    
    # Learning Loops (9-11)
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
    
    # Additional Processes (12-15)
    Write-Host ""
    Write-Host "  ADDITIONAL PROCESSES (12-15):" -ForegroundColor Cyan
    $additionalServices = @('MasteryAccessoryLoop', 'MainSeriesLoop', 'MasterUploadLoop', 'RelationshipFinder')
    
    foreach ($service in $additionalServices) {
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
    Write-Host "  ADDITIONAL PROCESSES:" -ForegroundColor White
    Write-Host "   12) Start Mastery Accessory Loop"
    Write-Host "   13) Start Main Series Loop"
    Write-Host "   14) Start Master Upload Loop"
    Write-Host "   15) Start Relationship Finder"
    Write-Host ""
    Write-Host "  AI COMMANDS (Display):" -ForegroundColor White
    Write-Host "   16) Show AI Learnings"
    Write-Host "   17) Show Working Memory"
    Write-Host "   18) Run Governance Learner Now"
    Write-Host ""
    Write-Host "  🤖 GENERATIVE AI:" -ForegroundColor Magenta
    Write-Host "   20) Start AI Chat Session (Interactive)"
    Write-Host "   21) Ask AI a Question (Single)"
    Write-Host "   22) Show Chat History"
    Write-Host "   23) Clear Chat Session"
    Write-Host "   24) Show Complete Memory Statistics"
    Write-Host ""
    Write-Host "  🖥️  SERVER MONITORING:" -ForegroundColor Cyan
    Write-Host "   30) Run Server Health Check"
    Write-Host "   31) Show Server Dashboard"
    Write-Host "   32) Add Server to Monitoring"
    Write-Host "   33) Remove Server from Monitoring"
    Write-Host "   34) Check Active Processes (sp_whoisactive)" [citation:3]
    Write-Host "   35) Test Single Server Connection"
    Write-Host ""
    Write-Host "  DATABASE:" -ForegroundColor White
    Write-Host "   40) Run Custom SQL"
    Write-Host "   41) Export AI Memory"
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

# Function to execute PowerShell commands safely
function Invoke-PowerShellCommand {
    param(
        [string]$Command,
        [string]$Description = ""
    )
    
    Write-Host "   ⚡ Executing PowerShell: $Description" -ForegroundColor Yellow
    
    try {
        # Execute the command
        $result = Invoke-Expression $Command 2>&1
        $output = $result | Out-String
        
        # Store in working memory
        $escapedCommand = $Command -replace "'", "''"
        $escapedOutput = $output -replace "'", "''"
        $escapedDescription = $Description -replace "'", "''"
        
        $psCommandInsertSql = @"
INSERT INTO pcde_working_memory (session_id, slot_key, slot_value)
VALUES ('$script:aiSessionId', 'ps_cmd_$(Get-Random -Maximum 9999)', '$escapedCommand'),
       ('$script:aiSessionId', 'ps_result_$(Get-Random -Maximum 9999)', '$escapedOutput')
"@
        & $queryScript -Sql $psCommandInsertSql 2>$null | Out-Null
        
        return @{
            success = $true
            output = $output
            command = $Command
        }
    }
    catch {
        return @{
            success = $false
            output = $_.Exception.Message
            command = $Command
        }
    }
}

# Function to get available PowerShell commands from the database
function Get-AvailablePowerShellCommands {
    param([string]$Question)
    
    $keywords = Get-Keywords -Text $Question
    
    # Search for procedures that might have PowerShell commands
    $procFields = @('procedure_name', 'description', 'why_it_exists')
    $procWhere = Build-WhereClause -Fields $procFields -Keywords $keywords
    
    $proceduralSql = @"
SELECT procedure_id, procedure_name, procedure_type, domain, description
FROM pcde_procedure_registry 
WHERE $procWhere
   OR procedure_type IN ('script', 'batch', 'pipeline')
   OR domain LIKE '%powershell%'
   OR description LIKE '%powershell%'
ORDER BY procedure_id DESC
LIMIT 5
"@
    
    $procedures = Safe-SqlQuery -Sql $proceduralSql -Context "Finding PowerShell Commands"
    
    if ($procedures) {
        return $procedures
    }
    
    # Check procedure_relations for file paths
    $relationsSql = @"
SELECT relation_id, procedure_id, relation_type, relation_target, notes
FROM pcde_procedure_relations 
WHERE relation_type IN ('script', 'batch', 'file')
   AND (relation_target LIKE '%.ps1%' OR relation_target LIKE '%.bat%')
   OR notes LIKE '%powershell%'
LIMIT 5
"@
    
    return Safe-SqlQuery -Sql $relationsSql -Context "Finding Script Files"
}

# Keyword extraction function
function Get-Keywords {
    param([string]$Text)
    
    # Split into words and clean
    $words = $Text -split '\s+' | ForEach-Object { 
        $_.Trim(" ?.,!;:()[]{}""'").ToLower() 
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
    )
    
    # Important technical terms to ALWAYS keep
    $technicalTerms = @(
        'ai', 'api', 'sql', 'db', 'csv', 'xml', 'json', 'html', 'css',
        'proc', 'sp', 'view', 'batch', 'script', 'pipeline',
        'cvi', 'spine', 'spool', 'telemetry',
        'capabilities', 'capability', 'ability',
        'procedure', 'procedures', 'stored', 'function',
        'mastery', 'accessory', 'runner', 'relationship'
    )
    
    $keywords = @()
    foreach ($word in $words) {
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
        return "1=0"
    }
    
    $conditions = @()
    foreach ($field in $Fields) {
        foreach ($keyword in $Keywords) {
            $conditions += "$field LIKE '%$keyword%'"
        }
    }
    
    if ($conditions.Count -gt 0) {
        return "(" + ($conditions -join " OR ") + ")"
    }
    
    return "1=0"
}

# Main AI function with keyword search and PowerShell execution
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
    
    # Check if this is a PowerShell execution request
    $isPowerShellRequest = $Question -match "run|execute|start|launch|invoke" -and 
                           ($Question -match "powershell|script|command|procedure|service")
    
    if ($isPowerShellRequest) {
        Write-Host "   ⚡ Detected PowerShell execution request!" -ForegroundColor Magenta
        
        $availableCommands = Get-AvailablePowerShellCommands -Question $Question
        
        if ($availableCommands) {
            $formattedResponse = @"
⚡ Found PowerShell-executable items in database:

$availableCommands

To run any of these, just ask me to "run [procedure name]" or "start [service name]"
"@
            
            $qId = "q_$(Get-Random -Maximum 9999)"
            $aId = "a_$(Get-Random -Maximum 9999)"
            $escapedResponse = $formattedResponse -replace "'", "''"
            
            $workingMemoryInsertSql = @"
INSERT INTO pcde_working_memory (session_id, slot_key, slot_value)
VALUES ('$script:aiSessionId', '$qId', '$escapedQuestion'),
       ('$script:aiSessionId', '$aId', '$escapedResponse')
"@
            & $queryScript -Sql $workingMemoryInsertSql 2>$null | Out-Null
            
            return @{
                answer = $formattedResponse
                source = "powershell_available"
                confidence = 0.9
            }
        }
    }
    
    # Check for specific "run X" commands
    if ($Question -match "run\s+(?:the\s+)?(.+)" -or $Question -match "start\s+(?:the\s+)?(.+)") {
        $serviceName = $matches[1].Trim()
        Write-Host "   ⚡ Attempting to run: $serviceName" -ForegroundColor Magenta
        
        # Comprehensive service mapping
        $serviceMap = @{
            # Core Services
            "spine scheduler" = "SpineScheduler"
            "spine" = "SpineScheduler"
            "cvi watcher" = "CVIWatcher"
            "cvi" = "CVIWatcher"
            "telemetry watcher" = "TelemetryWatcher"
            "telemetry" = "TelemetryWatcher"
            "spool uploader" = "SpoolUploader"
            "spool" = "SpoolUploader"
            "ai learning" = "AILearning"
            "governance learner" = "AILearning"
            
            # Learning Loops
            "learning loop" = "LearningLoop"
            "knowledge miner" = "LearningLoop"
            "accessory loop" = "AccessoryLoop"
            "accessory" = "AccessoryLoop"
            "runner loop" = "RunnerLoop"
            "runner" = "RunnerLoop"
            
            # Additional Processes
            "mastery accessory loop" = "MasteryAccessoryLoop"
            "mastery" = "MasteryAccessoryLoop"
            "main series loop" = "MainSeriesLoop"
            "main series" = "MainSeriesLoop"
            "series loop" = "MainSeriesLoop"
            "master upload loop" = "MasterUploadLoop"
            "upload loop" = "MasterUploadLoop"
            "relationship finder" = "RelationshipFinder"
            "find relationships" = "RelationshipFinder"
            "file relationships" = "RelationshipFinder"

        }
        
        $actualService = $null
        foreach ($key in $serviceMap.Keys) {
            if ($serviceName -like "*$key*") {
                $actualService = $serviceMap[$key]
                break
            }
        }
        
        if ($actualService) {
            # Check if already running
            $existingJob = Get-Job -Name $actualService -ErrorAction SilentlyContinue
            if ($existingJob -and $existingJob.State -eq 'Running') {
                $answer = "$actualService is already running."
            } else {
                # Script paths mapping
                $scriptPaths = @{
                    # Core Services
                    "SpineScheduler" = "C:\miratv_ingest\workers\spine\spine_scheduler_total.ps1"
                    "CVIWatcher" = "C:\miratv_ingest\watcher_cvi.ps1"
                    "TelemetryWatcher" = "C:\miratv_ingest\workers\telemetry_watcher.ps1"
                    "SpoolUploader" = "C:\miratv_ingest\spool_uploader.ps1"
                    "AILearning" = "C:\miratv_ingest\workers\GovernanceLearner.ps1"
                    
                    # Learning Loops - handled via scriptblocks
                    "LearningLoop" = $null
                    "AccessoryLoop" = $null
                    "RunnerLoop" = $null
                    
                    # Additional Processes 
                    "MasteryAccessoryLoop" = "C:\miratv_ingest\master_runner_loop_acc.bat"
                    "MainSeriesLoop" = "C:\miratv_ingest\master_runner_loop.bat"
                    "MasterUploadLoop" = "C:\miratv_ingest\MASTER_UPLOAD_LOOP.bat"
                    "RelationshipFinder" = "C:\miratv_ingest\Find-FileRelationships.ps1"
                }
                
                if ($scriptPaths.ContainsKey($actualService) -and $scriptPaths[$actualService]) {
                    if ($actualService -eq "RelationshipFinder") {
                        # Run once, not as a job
                        $result = Invoke-PowerShellCommand -Command "& '$($scriptPaths[$actualService])'" -Description "Running $actualService"
                        $answer = if ($result.success) { 
                            "✅ $actualService executed successfully!`n`n$($result.output)"
                        } else { 
                            "❌ Failed to execute $actualService`: $($result.output)"
                        }
                    } else {
                        # Start as background job
                        $result = Invoke-PowerShellCommand -Command "Start-Job -Name '$actualService' -FilePath '$($scriptPaths[$actualService])'" -Description "Starting $actualService"
                        $answer = if ($result.success) { 
                            "✅ Started $actualService successfully as a background job."
                        } else { 
                            "❌ Failed to start $actualService`: $($result.output)"
                        }
                    }
                } else {
                    # Handle services that need continuous scriptblocks
                    $scriptBlock = switch ($actualService) {
                        "AILearning" { 
@'
while($true) {
    & "C:\miratv_ingest\workers\GovernanceLearner.ps1"
    Start-Sleep -Seconds 300
}
'@
}
                        "LearningLoop" { 
@'
while($true) {
    & "C:\miratv_ingest\workers\KnowledgeMiner.ps1"
    Start-Sleep -Seconds 300
}
'@
}
                        "AccessoryLoop" { 
@'
while($true) {
    & "C:\miratv_ingest\MASTER_UPLOAD_LOOP.bat"
    Start-Sleep -Seconds 60
}
'@
}
                        "RunnerLoop" { 
@'
while($true) {
    & "C:\miratv_ingest\master_runner_loop.bat"
    Start-Sleep -Seconds 120
}
'@
}
                        "MasteryAccessoryLoop" { 
@'
while($true) {
    & "C:\miratv_ingest\master_runner_loop_acc.bat"
    Start-Sleep -Seconds 60
}
'@
}
                        "MainSeriesLoop" { 
@'
while($true) {
    & "C:\miratv_ingest\master_runner_loop.bat"
    Start-Sleep -Seconds 120
}
'@
}
                        "MasterUploadLoop" { 
@'
while($true) {
    & "C:\miratv_ingest\MASTER_UPLOAD_LOOP.bat"
    Start-Sleep -Seconds 60
}
'@
}
                    }
                    
                    if ($scriptBlock) {
                        try {
                            Start-Job -Name $actualService -ScriptBlock ([ScriptBlock]::Create($scriptBlock)) | Out-Null
                            $answer = "✅ Started $actualService successfully as a continuous background job."
                        } catch {
                            $answer = "❌ Failed to start $actualService: $($_.Exception.Message)"
                        }
                    } else {
                        $answer = "❌ Don't know how to start $actualService"
                    }
                }
            }
            
            # Store and return
            $qId = "q_$(Get-Random -Maximum 9999)"
            $aId = "a_$(Get-Random -Maximum 9999)"
            $escapedAnswer = $answer -replace "'", "''"
            
            $answerInsertSql = @"
INSERT INTO pcde_working_memory (session_id, slot_key, slot_value)
VALUES ('$script:aiSessionId', '$qId', '$escapedQuestion'),
       ('$script:aiSessionId', '$aId', '$escapedAnswer')
"@
            & $queryScript -Sql $answerInsertSql 2>$null | Out-Null
            
            return @{
                answer = $answer
                source = "powershell_execution"
                confidence = 0.95
            }
        }
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
SELECT procedure_id, procedure_name, procedure_type, domain, description
FROM pcde_procedure_registry 
WHERE $procWhere
ORDER BY procedure_id DESC
LIMIT 5
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
        
        $decFields = @('predicate', 'object_value', 'domain')
        $decWhere = Build-WhereClause -Fields $decFields -Keywords $keywords
        
        $declarativeSql = @"
SELECT fact_id, fact_type, domain, predicate, object_value, confidence
FROM pcde_declarative_memory 
WHERE $decWhere
ORDER BY confidence DESC, fact_id DESC
LIMIT 5
"@
        
        $declarative = Safe-SqlQuery -Sql $declarativeSql -Context "Declarative Memory"
        
        if ($declarative) {
            Write-Host "   ✅ Found in Declarative Memory" -ForegroundColor Green
            $memoryResult = $declarative
            $memorySource = "declarative"
            
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
SELECT relation_id, procedure_id, relation_type, relation_target, notes
FROM pcde_procedure_relations 
WHERE $assocWhere
ORDER BY relation_id DESC
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
SELECT memory_id, agent_name, memory_type, key_data, confidence, access_count
FROM pcde_ai_memory 
WHERE $aiWhere
ORDER BY confidence DESC, access_count DESC, memory_id DESC
LIMIT 5
"@
        
        $aiMemory = Safe-SqlQuery -Sql $aiMemorySql -Context "AI Memory"
        
        if ($aiMemory) {
            Write-Host "   ✅ Found in AI Memory" -ForegroundColor Green
            $memoryResult = $aiMemory
            $memorySource = "ai_memory"
            
            if ($aiMemory -match '"confidence":\s*([\d\.]+)') {
                $confidence = [double]$matches[1]
            } else {
                $confidence = 0.8
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
        
        $qId = "q_$(Get-Random -Maximum 9999)"
        $aId = "a_$(Get-Random -Maximum 9999)"
        $escapedAnswer = $formattedAnswer -replace "'", "''"
        
        $qaInsertSql = @"
INSERT INTO pcde_working_memory (session_id, slot_key, slot_value)
VALUES ('$script:aiSessionId', '$qId', '$escapedQuestion'),
       ('$script:aiSessionId', '$aId', '$escapedAnswer')
"@
        & $queryScript -Sql $qaInsertSql 2>$null | Out-Null
        
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
- Mastery Accessory Loop (specialized accessory processing)
- Main Series Loop (main series processing)
- Master Upload Loop (handles uploads)
- Relationship Finder (finds file relationships)

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
        
        $qId = "q_$(Get-Random -Maximum 9999)"
        $aId = "a_$(Get-Random -Maximum 9999)"
        $ollamaInsertSql = @"
INSERT INTO pcde_working_memory (session_id, slot_key, slot_value)
VALUES ('$script:aiSessionId', '$qId', '$escapedQuestion'),
       ('$script:aiSessionId', '$aId', '$escapedAnswer')
"@
        & $queryScript -Sql $ollamaInsertSql 2>$null | Out-Null
        
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
            
            # Learning Loops
            Start-Job -Name "LearningLoop" -ScriptBlock {
                while($true) {
                    & "C:\miratv_ingest\workers\KnowledgeMiner.ps1"
                    Start-Sleep -Seconds 300
                }
            }
            Start-Job -Name "AccessoryLoop" -ScriptBlock {
                while($true) {
                    & "C:\miratv_ingest\MASTER_UPLOAD_LOOP.bat"
                    Start-Sleep -Seconds 60
                }
            }
            Start-Job -Name "RunnerLoop" -ScriptBlock {
                while($true) {
                    & "C:\miratv_ingest\master_runner_loop.bat"
                    Start-Sleep -Seconds 120
                }
            }
            
            # Additional Processes
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
                    & "C:\miratv_ingest\MASTER_UPLOAD_LOOP.bat"
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
        
        # Additional Processes
        "12" { 
            Start-Job -Name "MasteryAccessoryLoop" -ScriptBlock {
                while($true) {
                    & "C:\miratv_ingest\master_runner_loop_acc.bat"
                    Start-Sleep -Seconds 60
                }
            }
            Write-Host "✅ Mastery Accessory Loop started" -ForegroundColor Green
            Read-Host "Press Enter to continue"
        }
        "13" { 
            Start-Job -Name "MainSeriesLoop" -ScriptBlock {
                while($true) {
                    & "C:\miratv_ingest\master_runner_loop.bat"
                    Start-Sleep -Seconds 120
                }
            }
            Write-Host "✅ Main Series Loop started" -ForegroundColor Green
            Read-Host "Press Enter to continue"
        }
        "14" { 
            Start-Job -Name "MasterUploadLoop" -ScriptBlock {
                while($true) {
                    & "C:\miratv_ingest\MASTER_UPLOAD_LOOP.bat"
                    Start-Sleep -Seconds 60
                }
            }
            Write-Host "✅ Master Upload Loop started" -ForegroundColor Green
            Read-Host "Press Enter to continue"
        }
        "15" { 
            & "C:\miratv_ingest\Find-FileRelationships.ps1"
            Write-Host "✅ Relationship Finder executed" -ForegroundColor Green
            Read-Host "Press Enter to continue"
        }
        
        # AI Display Commands
        "16" { Show-AILearnings; Read-Host "Press Enter to continue" }
        "17" { Show-WorkingMemory; Read-Host "Press Enter to continue" }
        "18" { 
            & "C:\miratv_ingest\workers\GovernanceLearner.ps1"
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
        
        # Database Commands
        "25" { 
            $sql = Read-Host "Enter SQL"
            & $queryScript -Sql $sql
            Read-Host "Press Enter to continue"
        }
        "26" { 
            $result = & $queryScript -Sql "SELECT * FROM pcde_ai_memory"
            $result | Out-File "ai_memory_export_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
            Write-Host "✅ Export complete" -ForegroundColor Green
            Read-Host "Press Enter to continue"
        }
        # Server Monitoring Commands
        "30" { 
            $detailed = Read-Host "Run detailed check? (Y/N)"
            $export = Read-Host "Export results to CVI? (Y/N)"
    
            $results = Invoke-ServerHealthCheck -Detailed:($detailed -eq "Y") -ExportToCVI:($export -eq "Y")
            Read-Host "Press Enter to continue"
        }
        "31" { 
            Show-ServerDashboard
            Read-Host "Press Enter to continue"
        }
        "32" { 
            $name = Read-Host "Enter server name (friendly name)"
            $instance = Read-Host "Enter SQL Server instance (e.g., SERVER\INSTANCE or SERVER,1433)"
            Add-MonitoredServer -Name $name -Instance $instance
            Read-Host "Press Enter to continue"
        }
        "33" { 
            $name = Read-Host "Enter server name to remove"
            Remove-MonitoredServer -Name $name
            Read-Host "Press Enter to continue"
        }
        "34" { 
            $server = Read-Host "Enter server instance (or press Enter for first server)"
            if ([string]::IsNullOrWhiteSpace($server)) {
            $server = $serverConfig.Servers[0].Instance
        }
            $processes = Get-ActiveProcesses -ServerInstance $server
            $processes | Format-Table -AutoSize
            Read-Host "Press Enter to continue"
        }
        "35" { 
            $server = Read-Host "Enter server instance to test"
            $result = Test-SQLConnection -ServerInstance $server
            if ($result.Success) {
                 Write-Host "✅ Connection successful to $server" -ForegroundColor Green
            } else {
                Write-Host "❌ Connection failed: $($result.Message)" -ForegroundColor Red
         }
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