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

    $rows = Invoke-SqlQueryObjects -Sql $Sql
    if (-not $rows -or @($rows).Count -eq 0) {
        return "No rows returned."
    }

    return (($rows | Format-Table -AutoSize | Out-String).Trim())
}

function Show-Header {
    Clear-Host
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║              🧠 'CSA-PCDE' (Patents Pending)             ║" -ForegroundColor Cyan
    Write-Host "║                MASTER CONTROL CONSOLE                    ║" -ForegroundColor Cyan
    Write-Host "║             Cognitive Substrate Architecture             ║" -ForegroundColor Cyan
    Write-Host "║      Persistent Cognitive Development Environment        ║" -ForegroundColor Cyan
    Write-Host "║                     Command Center                       ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Status {
    Write-Host "📊 SYSTEM STATUS" -ForegroundColor Yellow
    Write-Host "================"
    
    # Check database connectivity
    try {
        $test = Invoke-SqlQueryObjects -Sql "SELECT 1 as test"
        if ($test -and @($test).Count -gt 0) {
            Write-Host "✅ Database: Connected to pcde_memory" -ForegroundColor Green
        } else {
            Write-Host "❌ Database: Connection failed" -ForegroundColor Red
        }
    } catch {
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
    try {
        $result = Invoke-SqlQueryObjects -Sql "SELECT memory_id, agent_name, memory_type, LEFT(key_data,100) as preview, confidence, created_at FROM pcde_ai_memory ORDER BY confidence DESC, memory_id DESC LIMIT 10"

        if ($result -and @($result).Count -gt 0) {
            Write-Host "`n🧠 RECENT AI LEARNINGS" -ForegroundColor Cyan
            Write-Host "======================" -ForegroundColor Cyan
            @($result) | Format-Table memory_id, agent_name, memory_type, preview, confidence, created_at -AutoSize
        } else {
            Write-Host "No AI learnings found" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "Failed to load AI learnings: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Show-WorkingMemory {
    try {
        $result = Invoke-SqlQueryObjects -Sql "SELECT slot_key, slot_value, created_at, expires_at FROM pcde_working_memory WHERE expires_at > NOW() ORDER BY created_at DESC"

        if ($result -and @($result).Count -gt 0) {
            Write-Host "`n🧠 ACTIVE WORKING MEMORY" -ForegroundColor Cyan
            Write-Host "========================" -ForegroundColor Cyan
            @($result) | Format-Table slot_key, slot_value, created_at, expires_at -AutoSize -Wrap
        } else {
            Write-Host "No active working memory" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "Failed to load working memory: $($_.Exception.Message)" -ForegroundColor Red
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
    
    return Invoke-SqlQueryObjects -Sql $sql
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
function Normalize-ResponseRows {
    param([object]$Response)

    if ($null -eq $Response) { return @() }

    if ($Response.PSObject.Properties.Name -contains 'rows') {
        if ($null -eq $Response.rows) { return @() }
        return @($Response.rows)
    }

    if ($Response.PSObject.Properties.Name -contains 'data') {
        if ($null -eq $Response.data) { return @() }
        return @($Response.data)
    }

    if ($Response -is [System.Collections.IEnumerable] -and -not ($Response -is [string])) {
        return @($Response)
    }

    return @($Response)
}

function Invoke-SqlQueryObjects {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sql,

        [string]$DatabaseName = "pcde_memory"
    )

    $body = @{
        token = $token
        db = $DatabaseName
        sql = $Sql
        params = @()
    } | ConvertTo-Json -Depth 6 -Compress

    try {
        $response = Invoke-RestMethod -Uri $cviEndpoint -Method Post -Body $body -ContentType "application/json" -TimeoutSec $config.SQLTimeout -ErrorAction Stop
        return @(Normalize-ResponseRows -Response $response)
    }
    catch {
        return @()
    }
}

function Invoke-SilentSqlNonQuery {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sql,

        [string]$DatabaseName = "pcde_memory"
    )

    $body = @{
        token = $token
        db = $DatabaseName
        sql = $Sql
        params = @()
    } | ConvertTo-Json -Depth 6 -Compress

    try {
        [void](Invoke-RestMethod -Uri $cviEndpoint -Method Post -Body $body -ContentType "application/json" -TimeoutSec $config.SQLTimeout -ErrorAction Stop)
        return $true
    }
    catch {
        return $false
    }
}

function Format-MemoryRows {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Rows,

        [string]$Kind = "rows"
    )

    if (-not $Rows -or @($Rows).Count -eq 0) {
        return "No $Kind found."
    }

    $lines = foreach ($row in @($Rows) | Select-Object -First 5) {
        $props = $row.PSObject.Properties.Name

        if ($props -contains 'procedure_name') {
            $desc = if ($props -contains 'description' -and $row.description) { $row.description } else { "" }
            "- $($row.procedure_name) | domain=$($row.domain) | type=$($row.procedure_type) | desc=$desc"
        }
        elseif ($props -contains 'predicate') {
            "- $($row.predicate) -> $($row.object_value) | domain=$($row.domain) | confidence=$($row.confidence)"
        }
        elseif ($props -contains 'relation_type') {
            "- relation=$($row.relation_type) | target=$($row.relation_target) | notes=$($row.notes)"
        }
        elseif ($props -contains 'slot_key') {
            "- $($row.slot_key) = $($row.slot_value)"
        }
        elseif ($props -contains 'memory_type') {
            "- $($row.memory_type) | key=$($row.key_data) | confidence=$($row.confidence)"
        }
        elseif ($props -contains 'count') {
            "- count=$($row.count)"
        }
        else {
            "- " + (($row | Out-String).Trim() -replace '\s+', ' ')
        }
    }

    return ($lines -join "`n")
}

function Safe-SqlQuery {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sql,

        [string]$Context = "SQL Query",

        [string]$DatabaseName = "pcde_memory"
    )

    Write-Host "   🔍 $Context..." -ForegroundColor Gray
    try {
        $rows = Invoke-SqlQueryObjects -Sql $Sql -DatabaseName $DatabaseName

        if ($null -eq $rows) {
            return $null
        }

        $rows = @($rows)

        if ($rows.Count -eq 0) {
            return $null
        }

        Write-Host "   ✅ Success! ($($rows.Count) rows)" -ForegroundColor DarkGreen
        return $rows
    }
    catch {
        Write-Host "   ❌ $Context failed: $($_.Exception.Message)" -ForegroundColor DarkRed
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


function Get-MemoryConfidenceValue {
    param(
        [object[]]$Rows,
        [double]$DefaultConfidence = 0.70
    )

    if (-not $Rows -or @($Rows).Count -eq 0) {
        return $DefaultConfidence
    }

    $firstRow = @($Rows)[0]
    if ($firstRow -and $firstRow.PSObject.Properties.Name -contains 'confidence' -and $null -ne $firstRow.confidence -and "$($firstRow.confidence)" -ne '') {
        try {
            return [double]$firstRow.confidence
        }
        catch {
            return $DefaultConfidence
        }
    }

    return $DefaultConfidence
}

function Get-MemoryCandidateScore {
    param(
        [string]$Source,
        [object[]]$Rows,
        [double]$Confidence
    )

    $baseScore = switch ($Source) {
        'procedural'  { 0.92 }
        'declarative' { 0.88 }
        'associative' { 0.82 }
        'working'     { 0.78 }
        'ai_memory'   { 0.80 }
        default       { 0.70 }
    }

    $rowCount = if ($Rows) { [Math]::Min(@($Rows).Count, 5) } else { 0 }
    $rowBonus = $rowCount * 0.01

    return [Math]::Round((($baseScore * 0.65) + ($Confidence * 0.30) + $rowBonus), 4)
}

function New-MemoryCandidate {
    param(
        [string]$Source,
        [string]$Label,
        [object[]]$Rows,
        [double]$DefaultConfidence
    )

    if (-not $Rows -or @($Rows).Count -eq 0) {
        return $null
    }

    $confidence = Get-MemoryConfidenceValue -Rows $Rows -DefaultConfidence $DefaultConfidence
    $score = Get-MemoryCandidateScore -Source $Source -Rows $Rows -Confidence $confidence

    return [pscustomobject]@{
        Source = $Source
        Label = $Label
        Rows = @($Rows)
        Confidence = $confidence
        Score = $score
        Count = @($Rows).Count
    }
}

function Convert-CandidatesToOllamaPayload {
    param(
        [object[]]$Candidates = @()
    )

    $payload = @()

    foreach ($candidate in @($Candidates | Sort-Object -Property Score, Confidence, Count -Descending | Select-Object -First 5)) {
        $rows = @()
        foreach ($row in @($candidate.Rows) | Select-Object -First 5) {
            $rowMap = [ordered]@{}
            foreach ($prop in $row.PSObject.Properties) {
                $rowMap[$prop.Name] = if ($null -eq $prop.Value) { $null } else { [string]$prop.Value }
            }
            $rows += [pscustomobject]$rowMap
        }

        $payload += [pscustomobject]@{
            source = $candidate.Source
            label = $candidate.Label
            score = $candidate.Score
            confidence = $candidate.Confidence
            row_count = $candidate.Count
            rows = $rows
        }
    }

    if ($payload.Count -eq 0) {
        return '[]'
    }

    return ($payload | ConvertTo-Json -Depth 8 -Compress)
}

function Get-OllamaModel {
    try {
        $models = Invoke-RestMethod -Uri "$($config.OllamaUrl)/api/tags" -TimeoutSec 5 -ErrorAction Stop
        $availableModels = @($models.models | ForEach-Object { $_.name })

        if ($availableModels.Count -eq 0) {
            return $null
        }

        if ($availableModels -notcontains $config.AIModel) {
            $config.AIModel = $availableModels[0]
        }

        return $config.AIModel
    }
    catch {
        return $null
    }
}

function Get-CandidateEvidenceSummary {
    param(
        [object[]]$Candidates = @()
    )

    $lines = foreach ($candidate in @($Candidates | Sort-Object -Property Score, Confidence, Count -Descending | Select-Object -First 5)) {
        $preview = Format-MemoryRows -Rows $candidate.Rows -Kind $candidate.Source
        if ($preview.Length -gt 600) { $preview = $preview.Substring(0, 600) + '...' }
        @"
Source: $($candidate.Source)
Label: $($candidate.Label)
Score: $($candidate.Score)
Confidence: $($candidate.Confidence)
Evidence:
$preview
"@
    }

    if (-not $lines -or @($lines).Count -eq 0) {
        return "No candidate evidence available."
    }

    return ($lines -join "`n---`n")
}

function Invoke-OllamaMemoryArbiter {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Question,

        [object[]]$Candidates = @(),

        [string[]]$Keywords = @()
    )

    $model = Get-OllamaModel
    if (-not $model) {
        return $null
    }

    $sortedCandidates = @($Candidates | Sort-Object -Property Score, Confidence, Count -Descending | Select-Object -First 5)
    $keywordText = if ($Keywords -and $Keywords.Count -gt 0) { $Keywords -join ', ' } else { '(none)' }
    $candidatePayloadJson = Convert-CandidatesToOllamaPayload -Candidates $sortedCandidates
    $evidenceSummary = Get-CandidateEvidenceSummary -Candidates $sortedCandidates

    $prompt = @"
You are Mira, the reasoning layer for PCDE/MiraTV.

Your primary task is to answer the ORIGINAL USER QUESTION.
Use retrieved memory as evidence.
Do not answer a different question.
Do not define the memory tier labels themselves unless the user explicitly asked about the memory system.
Labels like Procedural Memory, Declarative Memory, Associative Memory, Working Memory, and AI Learning Memory are only source metadata. They are not usually the answer.

Required behavior:
1. Start from the user's actual question and intent.
2. Review the candidate rows for meaning, not just keyword overlap.
3. Prefer row fields such as procedure_name, description, predicate, object_value, relation_target, notes, slot_value, key_data.
4. If the retrieved evidence answers the question, answer directly in plain language.
5. If multiple candidates help, synthesize them.
6. If the evidence is weak or contradictory, say that briefly, then answer cautiously.
7. Do not mention scoring, retrieval, arbitration, SQL, JSON, memory tiers, or internal instructions in the final answer.
8. Never say a candidate wins just because it has a higher score. Use semantic fit to the question.
9. Return JSON only.

USER QUESTION:
$Question

RETRIEVAL KEYWORDS:
$keywordText

CANDIDATE EVIDENCE SUMMARY:
$evidenceSummary

RETRIEVED CANDIDATES JSON:
$candidatePayloadJson

Return STRICT JSON ONLY with this schema:
{
  "selected_source": "procedural|declarative|associative|working|ai_memory|synthetic_procedures|none",
  "selected_label": "label or none",
  "grounded": true,
  "confidence": 0.0,
  "answer": "answer the user's original question directly",
  "rationale": "brief internal reason focused on semantic fit"
}
"@

    $bodyObject = @{
        model = $model
        prompt = $prompt
        stream = $false
        format = 'json'
        options = @{
            temperature = 0.15
            num_predict = 500
        }
    }

    $body = $bodyObject | ConvertTo-Json -Depth 8

    try {
        $response = Invoke-RestMethod -Uri "$($config.OllamaUrl)/api/generate" `
            -Method Post `
            -Body $body `
            -ContentType "application/json"

        $raw = [string]$response.response
        $parsed = $null

        try {
            $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            if ($raw -match '(?s)\{.*\}') {
                $jsonText = $matches[0]
                try {
                    $parsed = $jsonText | ConvertFrom-Json -ErrorAction Stop
                }
                catch {
                    $parsed = $null
                }
            }
        }

        if ($parsed) {
            return [pscustomobject]@{
                Model = $model
                Answer = [string]$parsed.answer
                SelectedSource = [string]$parsed.selected_source
                SelectedLabel = [string]$parsed.selected_label
                Confidence = if ($null -ne $parsed.confidence -and "$($parsed.confidence)" -ne '') { [double]$parsed.confidence } else { 0.80 }
                Grounded = if ($null -ne $parsed.grounded) { [bool]$parsed.grounded } else { ($sortedCandidates.Count -gt 0) }
                Rationale = [string]$parsed.rationale
                RawResponse = $raw
            }
        }

        return [pscustomobject]@{
            Model = $model
            Answer = if ($sortedCandidates.Count -gt 0) { "I found retrieved memory candidates, but Ollama did not return valid JSON. Falling back to the top retrieved candidate." } else { $raw }
            SelectedSource = if ($sortedCandidates.Count -gt 0) { [string]$sortedCandidates[0].Source } else { 'none' }
            SelectedLabel = if ($sortedCandidates.Count -gt 0) { [string]$sortedCandidates[0].Label } else { 'none' }
            Confidence = 0.70
            Grounded = ($sortedCandidates.Count -gt 0)
            Rationale = 'Ollama returned malformed output; using safe fallback behavior.'
            RawResponse = $raw
        }
    }
    catch {
        return $null
    }
}


# Main AI function with keyword search
function Ask-AI {
    param([string]$Question)

    if (-not $script:aiSessionId) {
        Write-Host "⚠️ No active session. Starting new session..." -ForegroundColor Yellow
        Start-AISession | Out-Null
    }

    Write-Host "`n🤔 Asking AI: $Question" -ForegroundColor Cyan
    Write-Host "🔍 Extracting keywords and searching memory..." -ForegroundColor Yellow

    $escapedQuestion = $Question -replace "'", "''"

    $keywords = Get-Keywords -Text $Question

    if ($keywords.Count -eq 0) {
        Write-Host "   ⚠️ No keywords extracted, using full question" -ForegroundColor Yellow
        $keywords = @($escapedQuestion)
    } else {
        Write-Host "   🔑 Keywords: $($keywords -join ', ')" -ForegroundColor Green
    }

    $memoryResult = $null
    $memorySource = ""
    $confidence = 0
    $memoryCandidates = @()
    $bestCandidate = $null

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
        $candidate = New-MemoryCandidate -Source 'procedural' -Label 'Procedural Memory' -Rows $procedural -DefaultConfidence 0.90
        if ($candidate) { $memoryCandidates += $candidate }
    }

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
        $candidate = New-MemoryCandidate -Source 'declarative' -Label 'Declarative Memory' -Rows $declarative -DefaultConfidence 0.85
        if ($candidate) { $memoryCandidates += $candidate }
    }

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
        $candidate = New-MemoryCandidate -Source 'associative' -Label 'Associative Memory' -Rows $associative -DefaultConfidence 0.80
        if ($candidate) { $memoryCandidates += $candidate }
    }

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
        $candidate = New-MemoryCandidate -Source 'working' -Label 'Working Memory' -Rows $working -DefaultConfidence 0.75
        if ($candidate) { $memoryCandidates += $candidate }
    }

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
        $candidate = New-MemoryCandidate -Source 'ai_memory' -Label 'AI Learning Memory' -Rows $aiMemory -DefaultConfidence 0.80
        if ($candidate) { $memoryCandidates += $candidate }
    }

    if ($memoryCandidates.Count -gt 0) {
        $bestCandidate = $memoryCandidates | Sort-Object -Property Score, Confidence, Count -Descending | Select-Object -First 1
        $memoryResult = @($bestCandidate.Rows)
        $memorySource = $bestCandidate.Source
        $confidence = $bestCandidate.Confidence

        Write-Host "   🏆 Selected evidence set: $($bestCandidate.Label)" -ForegroundColor Magenta
    }

    if (-not $memoryResult -and ($Question -match "procedures?" -or $Question -match "what (procedures|services) (do you have|are available)")) {
        Write-Host "   📋 Checking for available procedures in database..." -ForegroundColor Cyan

        $procedureCountSql = "SELECT COUNT(*) as count FROM pcde_procedure_registry WHERE active = 1 OR active IS NULL"
        $procedureCount = Safe-SqlQuery -Sql $procedureCountSql -Context "Procedure Count"

        if ($procedureCount -and $procedureCount[0].count -gt 0) {
            $procedureListSql = @"
SELECT procedure_name, procedure_type, domain, description
FROM pcde_procedure_registry
WHERE active = 1 OR active IS NULL
ORDER BY procedure_name
LIMIT 15
"@
            $procedureList = Safe-SqlQuery -Sql $procedureListSql -Context "Procedure List"

            if ($procedureList) {
                Write-Host "   ✅ Built synthetic procedure candidate" -ForegroundColor Green
                $memoryCandidates += [pscustomobject]@{
                    Source = 'synthetic_procedures'
                    Label = 'Available Procedure List'
                    Rows = @($procedureList)
                    Confidence = 0.95
                    Score = 0.93
                    Count = @($procedureList).Count
                }

                $bestCandidate = $memoryCandidates | Sort-Object -Property Score, Confidence, Count -Descending | Select-Object -First 1
                $memoryResult = @($bestCandidate.Rows)
                $memorySource = $bestCandidate.Source
                $confidence = $bestCandidate.Confidence
            }
        }
    }

    Write-Host "🤖 Asking Ollama to evaluate the question against retrieved memory..." -ForegroundColor Yellow
    $arbiterResult = Invoke-OllamaMemoryArbiter -Question $Question -Candidates $memoryCandidates -Keywords $keywords
    if ($arbiterResult) {
        $finalAnswer = [string]$arbiterResult.Answer
        if ([string]::IsNullOrWhiteSpace($finalAnswer) -and $bestCandidate) {
            $finalAnswer = Format-MemoryRows -Rows $bestCandidate.Rows -Kind $bestCandidate.Source
        }

        $qId = "q_$(Get-Random -Maximum 9999)"
        $aId = "a_$(Get-Random -Maximum 9999)"
        $escapedAnswer = $finalAnswer -replace "'", "''"

        Invoke-SilentSqlNonQuery -Sql @"
INSERT INTO pcde_working_memory (session_id, slot_key, slot_value)
VALUES ('$script:aiSessionId', '$qId', '$escapedQuestion'),
       ('$script:aiSessionId', '$aId', '$escapedAnswer')
"@ | Out-Null

        $sourceTag = if ([string]::IsNullOrWhiteSpace($arbiterResult.SelectedSource)) { 'ollama' } else { "ollama:$($arbiterResult.SelectedSource)" }

        return @{
            answer = $finalAnswer
            source = $sourceTag
            confidence = $arbiterResult.Confidence
        }
    }

    if ($memoryResult) {
        Write-Host "⚠️ Ollama unavailable. Falling back to highest-scoring retrieved memory." -ForegroundColor Yellow

        $sourceIcons = @{
            "procedural" = "📋"
            "declarative" = "📚"
            "associative" = "🔗"
            "working" = "💭"
            "ai_memory" = "🧠"
            "synthetic_procedures" = "📋"
        }
        $icon = $sourceIcons[$memorySource]
        $formattedRows = Format-MemoryRows -Rows $memoryResult -Kind $memorySource
        $evaluationSummary = if ($memoryCandidates -and $memoryCandidates.Count -gt 0) {
            (($memoryCandidates | Sort-Object -Property Score -Descending | ForEach-Object {
                "- $($_.Label): rows=$($_.Count), confidence=$($_.Confidence), score=$($_.Score)"
            }) -join "`n")
        } else {
            "- No retrieved memory candidates matched."
        }

        $formattedAnswer = $formattedRows

        $qId = "q_$(Get-Random -Maximum 9999)"
        $aId = "a_$(Get-Random -Maximum 9999)"
        $escapedAnswer = $formattedAnswer -replace "'", "''"

        Invoke-SilentSqlNonQuery -Sql @"
INSERT INTO pcde_working_memory (session_id, slot_key, slot_value)
VALUES ('$script:aiSessionId', '$qId', '$escapedQuestion'),
       ('$script:aiSessionId', '$aId', '$escapedAnswer')
"@ | Out-Null

        return @{
            answer = $formattedAnswer
            source = $memorySource
            confidence = $confidence
        }
    }

    Write-Host "🤖 No memory matches and Ollama arbitration unavailable. Using plain Ollama fallback if possible..." -ForegroundColor Yellow

    $model = Get-OllamaModel
    if (-not $model) {
        return @{
            answer = "I'm Mira, your AI assistant. I can help you with questions about the MiraTV system, but no stored memory matched and Ollama was not reachable."
            source = "fallback"
            confidence = 0.5
        }
    }

    $prompt = @"
You are MiraTV AI assistant, specialized in the MiraTV ingest system.

No stored memory candidates matched this question.
Answer the user's question as helpfully as you can, but clearly acknowledge that no stored memory matched.

User question:
$Question
"@

    $body = @{
        model = $model
        prompt = $prompt
        stream = $false
        options = @{ temperature = 0.4 }
    } | ConvertTo-Json

    try {
        $response = Invoke-RestMethod -Uri "$($config.OllamaUrl)/api/generate" `
            -Method Post `
            -Body $body `
            -ContentType "application/json"

        $answer = [string]$response.response
        $escapedAnswer = $answer -replace "'", "''"

        $qId = "q_$(Get-Random -Maximum 9999)"
        $aId = "a_$(Get-Random -Maximum 9999)"
        Invoke-SilentSqlNonQuery -Sql @"
INSERT INTO pcde_working_memory (session_id, slot_key, slot_value)
VALUES ('$script:aiSessionId', '$qId', '$escapedQuestion'),
       ('$script:aiSessionId', '$aId', '$escapedAnswer')
"@ | Out-Null

        return @{
            answer = $answer
            source = "ollama"
            confidence = 0.7
        }
    }
    catch {
        return @{
            answer = "I'm Mira, your AI assistant. I can help you with questions about the MiraTV system, but no stored memory matched and Ollama was unavailable."
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

    if ($history -and @($history).Count -gt 0) {
        Write-Host "`n📝 Chat History:" -ForegroundColor Cyan
        Write-Host "================" -ForegroundColor Cyan

        foreach ($row in @($history)) {
            $text = [string]$row.slot_value
            if ($row.slot_key -like 'q_*') {
                Write-Host "🧑 $text" -ForegroundColor White
            }
            elseif ($row.slot_key -like 'a_*') {
                if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + "..." }
                Write-Host "🤖 $text" -ForegroundColor Green
            }
        }
    } else {
        Write-Host "No chat history" -ForegroundColor Yellow
    }
}

function Show-MemoryStats {
    Write-Host "`n📊 MEMORY SYSTEM STATISTICS" -ForegroundColor Cyan
    Write-Host "===========================" -ForegroundColor Cyan

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
        $countResult = Safe-SqlQuery -Sql "SELECT COUNT(*) as count FROM $($table.Name)" -Context $table.Display
        if ($countResult -and $countResult[0].count -ne $null) {
            $count = [int]$countResult[0].count
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
            $result = Invoke-SqlQueryObjects -Sql $sql
            if ($result -and @($result).Count -gt 0) {
                @($result) | Format-Table -AutoSize -Wrap
            } else {
                Write-Host "No rows returned" -ForegroundColor Yellow
            }
            Read-Host "Press Enter to continue"
        }
        "16" { 
            $result = Invoke-SqlQueryObjects -Sql "SELECT * FROM pcde_ai_memory"
            $exportFile = "ai_memory_export_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss')
            if ($result -and @($result).Count -gt 0) {
                @($result) | Format-Table -AutoSize -Wrap | Out-File $exportFile
                Write-Host "✅ Export complete: $exportFile" -ForegroundColor Green
            } else {
                Write-Host "No AI memory rows returned" -ForegroundColor Yellow
            }
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