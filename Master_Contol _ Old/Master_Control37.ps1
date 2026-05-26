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
    SQLTimeout = 240
    DebugLogging = $true
}



function Write-DebugLog {
    param(
        [string]$Message,
        [string]$Category = "GENERAL"
    )

    try {
        if (-not $config.DebugLogging) { return }
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $logFile = Join-Path $logDir ("master_control_debug_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
        $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Category, $Message
        Add-Content -Path $logFile -Value $line -Encoding UTF8
    }
    catch { }
}

# ============================================================
# PCDE REASONING RULES - YAML LOADER + ROUTING
# ============================================================

function Get-PCDEYamlModuleAvailable {
    return [bool](Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)
}

function Import-PCDEReasoningRules {
    param(
        [string]$YamlPath = "C:\miratv_ingest\pcde_reasoning_rules.yaml"
    )

    if (-not (Test-Path $YamlPath)) {
        throw "Reasoning rules YAML not found: $YamlPath"
    }

    $yamlText = Get-Content -Path $YamlPath -Raw -Encoding UTF8

    if (Get-PCDEYamlModuleAvailable) {
        return ($yamlText | ConvertFrom-Yaml)
    }

    $psYaml = Get-Module -ListAvailable -Name powershell-yaml
    if ($psYaml) {
        Import-Module powershell-yaml -ErrorAction Stop | Out-Null
        return ConvertFrom-Yaml -Yaml $yamlText
    }

    throw "No YAML parser available. Install module with: Install-Module powershell-yaml -Scope CurrentUser"
}

function Get-PCDENormalizedQuestion {
    param([string]$Question)

    if ([string]::IsNullOrWhiteSpace($Question)) { return "" }

    $q = $Question.Trim().ToLowerInvariant()
    $q = [regex]::Replace($q, "\s+", " ")
    return $q
}

function Get-PCDEQuestionTermCount {
    param([string]$Question)

    if ([string]::IsNullOrWhiteSpace($Question)) { return 0 }

    return (($Question -split "\s+") | Where-Object { $_.Trim() -ne "" }).Count
}

function Test-PCDEQueryTypeMatch {
    param(
        [string]$Question,
        [object]$TriggerConfig
    )

    if (-not $TriggerConfig) { return $false }

    $normalized = Get-PCDENormalizedQuestion -Question $Question
    $termCount  = Get-PCDEQuestionTermCount -Question $normalized

    if ($TriggerConfig.default -eq $true) {
        return $true
    }

    if ($null -ne $TriggerConfig.max_terms) {
        if ($termCount -gt [int]$TriggerConfig.max_terms) {
            return $false
        }
    }

    if ($TriggerConfig.starts_with) {
        foreach ($prefix in @($TriggerConfig.starts_with)) {
            if ($normalized.StartsWith(([string]$prefix).ToLowerInvariant())) {
                return $true
            }
        }
    }

    if ($TriggerConfig.contains) {
        foreach ($needle in @($TriggerConfig.contains)) {
            if ($normalized -like ("*" + ([string]$needle).ToLowerInvariant() + "*")) {
                return $true
            }
        }
    }

    if ($TriggerConfig.regex) {
        foreach ($pattern in @($TriggerConfig.regex)) {
            if ($normalized -match [string]$pattern) {
                return $true
            }
        }
    }

    return $false
}

function Get-PCDEMatchedQueryTypes {
    param(
        [string]$Question,
        [object]$Rules
    )

    $matches = @()
    $items = @()

    if ($null -eq $Rules -or $null -eq $Rules.query_types) {
        return $matches
    }

    if ($Rules.query_types -is [System.Collections.IDictionary]) {
        $items = @(
            $Rules.query_types.GetEnumerator() | ForEach-Object {
                [PSCustomObject]@{
                    Name = [string]$_.Key
                    Value = $_.Value
                }
            }
        )
    }
    else {
        $items = @(
            $Rules.query_types.PSObject.Properties | ForEach-Object {
                [PSCustomObject]@{
                    Name = [string]$_.Name
                    Value = $_.Value
                }
            }
        )
    }

    foreach ($item in $items) {
        $queryTypeName = [string]$item.Name
        $queryTypeDef = $item.Value

        if ([string]::IsNullOrWhiteSpace($queryTypeName)) { continue }
        if ($queryTypeName -in @('Keys','Values','Count','IsReadOnly','IsFixedSize','IsSynchronized','SyncRoot')) { continue }

        $triggerConfig = $null
        if ($queryTypeDef -and $queryTypeDef.PSObject.Properties.Name -contains 'triggers') {
            $triggerConfig = $queryTypeDef.triggers
        }
        elseif ($queryTypeDef -is [System.Collections.IDictionary] -and $queryTypeDef.Contains('triggers')) {
            $triggerConfig = $queryTypeDef['triggers']
        }

        if (Test-PCDEQueryTypeMatch -Question $Question -TriggerConfig $triggerConfig) {
            $matches += [PSCustomObject]@{
                QueryType = $queryTypeName
                Config = $queryTypeDef
            }
        }
    }

    return $matches
}

function Get-PCDESelectedQueryType {
    param(
        [string]$Question,
        [object]$Rules
    )

    $matches = @(Get-PCDEMatchedQueryTypes -Question $Question -Rules $Rules)

    $defaultType = 'general'
    if ($Rules -and $Rules.system -and $Rules.system.default_query_type) {
        $defaultType = [string]$Rules.system.default_query_type
    }

    $defaultConfig = $null
    if ($Rules -and $Rules.query_types) {
        if ($Rules.query_types -is [System.Collections.IDictionary]) {
            if ($Rules.query_types.Contains($defaultType)) {
                $defaultConfig = $Rules.query_types[$defaultType]
            }
        }
        else {
            $defaultConfig = $Rules.query_types.$defaultType
        }
    }

    if ($matches.Count -eq 0) {
        return [PSCustomObject]@{
            QueryType = $defaultType
            Config = $defaultConfig
            Matches = @()
        }
    }

    $useFirst = $false
    if ($Rules -and $Rules.routing_rules -and $Rules.routing_rules.use_first_matching_query_type -eq $true) {
        $useFirst = $true
    }

    if ($useFirst) {
        $precedence = @()
        if ($Rules.routing_rules.if_multiple_query_types_match.prefer_in_order) {
            $precedence = @($Rules.routing_rules.if_multiple_query_types_match.prefer_in_order)
        }

        foreach ($preferredType in $precedence) {
            $winner = $matches | Where-Object { $_.QueryType -eq $preferredType } | Select-Object -First 1
            if ($winner) {
                return [PSCustomObject]@{
                    QueryType = $winner.QueryType
                    Config = $winner.Config
                    Matches = $matches
                }
            }
        }
    }

    $first = $matches | Select-Object -First 1
    return [PSCustomObject]@{
        QueryType = $first.QueryType
        Config = $first.Config
        Matches = $matches
    }
}

function Get-PCDEQuerySignature {
    param(
        [string]$Question,
        [string]$QueryType
    )

    $normalized = Get-PCDENormalizedQuestion -Question $Question

    switch ($QueryType) {
        'acronym_definition' {
            if ($normalized -match '([a-z]{2,8})') {
                return "acronym_definition::$($matches[1])"
            }
            return "acronym_definition::generic"
        }
        'definition' { return "definition::what_is" }
        'procedural' { return "procedural::how_to" }
        'diagnostic' { return "diagnostic::why_failed" }
        'reflective' { return "reflective::judgment" }
        'followup' { return "followup::contextual" }
        'architecture' { return "architecture::system_design" }
        default { return "general::freeform" }
    }
}

function Get-PCDERoutingPlan {
    param(
        [string]$Question,
        [object]$Rules
    )

    $selection = Get-PCDESelectedQueryType -Question $Question -Rules $Rules
    $queryType = $selection.QueryType
    $config = $selection.Config

    $memoryOrder = @()
    if ($config) {
        if ($config -is [System.Collections.IDictionary]) {
            if ($config.Contains('preferred_memory_order')) {
                $memoryOrder = @($config['preferred_memory_order'])
            }
        }
        elseif ($config.preferred_memory_order) {
            $memoryOrder = @($config.preferred_memory_order)
        }
    }

    $memoryOrder = @(
        $memoryOrder |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    )

    if ($memoryOrder.Count -eq 0) {
        $memoryOrder = @('declarative','procedural','associative','ai_memory','working')
    }

    $arbiterMode = "general_resolution"
    if ($config) {
        if ($config -is [System.Collections.IDictionary]) {
            if ($config.Contains('arbiter_mode') -and $config['arbiter_mode']) {
                $arbiterMode = [string]$config['arbiter_mode']
            }
        }
        elseif ($config.arbiter_mode) {
            $arbiterMode = [string]$config.arbiter_mode
        }
    }

    $grounding = $null
    if ($config) {
        if ($config -is [System.Collections.IDictionary]) {
            if ($config.Contains('grounding')) {
                $grounding = $config['grounding']
            }
        }
        else {
            $grounding = $config.grounding
        }
    }

    return [PSCustomObject]@{
        QueryType = $queryType
        QuerySignature = Get-PCDEQuerySignature -Question $Question -QueryType $queryType
        PreferredOrder = $memoryOrder
        Grounding = $grounding
        ArbiterMode = $arbiterMode
        Matches = $selection.Matches
    }
}

function Convert-PCDEMemoryNameToLabel {
    param(
        [string]$MemoryName,
        [object]$Rules
    )

    if ($Rules.memory_types.$MemoryName.label) {
        return [string]$Rules.memory_types.$MemoryName.label
    }

    return $MemoryName
}


$aiSessionId = $null
$token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$cviEndpoint = "https://miratv.club/_workers/api/series/dog_open_proc.php"

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
            Write-Host "`n[OLLAMA] [$($result.source)] $($result.answer)`n" -ForegroundColor Green
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
    Write-Host "#==========================================================#" -ForegroundColor Cyan
    Write-Host "|              [AI] 'CSA-PCDE' (Patents Pending)             |" -ForegroundColor Cyan
    Write-Host "|                MASTER CONTROL CONSOLE                    |" -ForegroundColor Cyan
    Write-Host "|             Cognitive Substrate Architecture             |" -ForegroundColor Cyan
    Write-Host "|      Persistent Cognitive Development Environment        |" -ForegroundColor Cyan
    Write-Host "|                     Command Center                       |" -ForegroundColor Cyan
    Write-Host "#==========================================================#" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Status {
    Write-Host "[STATUS] SYSTEM STATUS" -ForegroundColor Yellow
    Write-Host "================"
    
    # Check database connectivity
    try {
        $test = Invoke-SqlQueryObjects -Sql "SELECT 1 as test"
        if ($test -and @($test).Count -gt 0) {
            Write-Host "[OK] Database: Connected to pcde_memory" -ForegroundColor Green
        } else {
            Write-Host "[ERR] Database: Connection failed" -ForegroundColor Red
        }
    } catch {
        Write-Host "[ERR] Database: Connection failed" -ForegroundColor Red
    }
    
    # Check Ollama
    try {
        $ollamaTest = Invoke-RestMethod -Uri "$($config.OllamaUrl)/api/tags" -TimeoutSec 5 -ErrorAction SilentlyContinue
        if ($ollamaTest.models) {
            $modelNames = $ollamaTest.models | ForEach-Object { $_.name }
            Write-Host "[OK] Ollama: Connected (Models: $($modelNames -join ', '))" -ForegroundColor Green
        }
    } catch {
        Write-Host "[WARN] Ollama: Not connected (local AI unavailable)" -ForegroundColor Yellow
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
    Write-Host "[ACTIVE] ACTIVE SERVICES:" -ForegroundColor Yellow
    
    # Core Services
    Write-Host "  CORE SERVICES (4-8):" -ForegroundColor Cyan
    $coreServices = @('SpineScheduler', 'CVIWatcher', 'TelemetryWatcher', 'SpoolUploader', 'AILearning')
    
    foreach ($service in $coreServices) {
        $job = $jobs | Where-Object { $_.Name -eq $service }
        $info = $serviceMap[$service]
        
        if ($job -and $job.State -eq 'Running') {
            Write-Host "    [OK] [$($info.menu)] $($info.name)" -ForegroundColor Green
        } else {
            Write-Host "    [PAUSE] [$($info.menu)] $($info.name)" -ForegroundColor Gray
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
            Write-Host "    [OK] [$($info.menu)] $($info.name)" -ForegroundColor Green
        } else {
            Write-Host "    [PAUSE] [$($info.menu)] $($info.name)" -ForegroundColor Gray
        }
    }
    
    # Show AI session if active
    if ($aiSessionId) {
        Write-Host ""
        Write-Host "? Active AI Session: $($aiSessionId.Substring(0,8))..." -ForegroundColor Cyan
    }
}

function Start-Service {
    param([string]$Name, [string]$Path, [array]$Args = @())
    
    if (Test-Path $Path) {
        Write-Host "Starting $Name..." -ForegroundColor Yellow
        Start-Job -Name $Name -FilePath $Path -ArgumentList $Args
        Write-Host "[OK] $Name started" -ForegroundColor Green
    } else {
        Write-Host "[ERR] $Name not found at $Path" -ForegroundColor Red
    }
}

function Stop-ServiceByName {
    param([string]$Name)
    
    $job = Get-Job -Name $Name -ErrorAction SilentlyContinue
    if ($job) {
        Stop-Job $job
        Remove-Job $job
        Write-Host "[OK] $Name stopped" -ForegroundColor Green
    } else {
        Write-Host "[WARN] $Name is not running" -ForegroundColor Yellow
    }
}

function Show-Menu {
    Write-Host ""
    Write-Host " COMMANDS" -ForegroundColor Magenta
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
    Write-Host "  [OLLAMA] GENERATIVE AI:" -ForegroundColor Magenta
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
            Write-Host "`n[AI] RECENT AI LEARNINGS" -ForegroundColor Cyan
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
            Write-Host "`n[AI] ACTIVE WORKING MEMORY" -ForegroundColor Cyan
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
    
    Write-Host "`n[START] Starting AI Session..." -ForegroundColor Yellow
    
    $script:aiSessionId = $SessionId
    Write-Host "[OK] AI Session started (ID: $($SessionId.Substring(0,8))...)" -ForegroundColor Green
    
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


function Convert-AnyToArray {
    param([object]$Value)

    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) { return @($Value) }
    if ($Value -is [System.Collections.IEnumerable]) { return @($Value) }
    return @($Value)
}

function Get-RowPropertyNames {
    param([object]$Row)

    if ($null -eq $Row) { return @() }
    try { return @($Row.PSObject.Properties.Name) } catch { return @() }
}

function Test-IsLongTermEvidenceRow {
    param([object]$Row)

    if ($null -eq $Row) { return $false }
    $names = @(Get-RowPropertyNames -Row $Row)
    if ($names.Count -eq 0) { return $false }

    if ($names -contains 'source_db' -or $names -contains 'source_table' -or $names -contains 'preview_text' -or $names -contains 'matched_text') {
        return $true
    }

    return $false
}

function Extract-ProcedureEvidenceRows {
    param([object]$Response)

    $evidence = @()
    if ($null -eq $Response) { return $evidence }

    $candidates = New-Object System.Collections.ArrayList
    [void]$candidates.Add($Response)

    foreach ($propName in @('rows','data','result','results','tables','table','recordset','recordsets')) {
        if ($Response.PSObject.Properties.Name -contains $propName) {
            $propVal = $Response.$propName
            foreach ($item in (Convert-AnyToArray -Value $propVal)) {
                [void]$candidates.Add($item)
            }
        }
    }

    foreach ($candidate in @($candidates)) {
        foreach ($row in (Convert-AnyToArray -Value $candidate)) {
            if ($null -eq $row) { continue }

            if (Test-IsLongTermEvidenceRow -Row $row) {
                $evidence += $row
                continue
            }

            foreach ($propName in @('rows','data','results','table')) {
                if ($row.PSObject.Properties.Name -contains $propName) {
                    foreach ($nested in (Convert-AnyToArray -Value $row.$propName)) {
                        if (Test-IsLongTermEvidenceRow -Row $nested) {
                            $evidence += $nested
                        }
                    }
                }
            }
        }
    }

    return @($evidence)
}

function Invoke-SqlRawResponse {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sql,

        [string]$DatabaseName = "pcde_memory",

        [string]$Context = "SQL"
    )

    $body = @{
        token = $token
        db = $DatabaseName
        sql = $Sql
        params = @()
    } | ConvertTo-Json -Depth 6 -Compress

    Write-DebugLog -Category 'SQL' -Message ("BEGIN [{0}] db={1} timeout={2}s sql={3}" -f $Context, $DatabaseName, $config.SQLTimeout, (($Sql -replace "`r|`n", ' ') -replace '\s+', ' ').Trim())

    try {
        $response = Invoke-RestMethod -Uri $cviEndpoint -Method Post -Body $body -ContentType "application/json" -TimeoutSec $config.SQLTimeout -ErrorAction Stop
        $shape = if ($null -eq $response) { 'null' } else { ($response.PSObject.Properties.Name -join ',') }
        Write-DebugLog -Category 'SQL' -Message ("END   [{0}] db={1} raw-shape={2}" -f $Context, $DatabaseName, $shape)
        return $response
    }
    catch {
        $msg = $_.Exception.Message
        Write-DebugLog -Category 'SQL' -Message ("FAIL  [{0}] db={1} error={2}" -f $Context, $DatabaseName, $msg)
        return $null
    }
}

function Invoke-SqlQueryObjects {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sql,

        [string]$DatabaseName = "pcde_memory",

        [string]$Context = "SQL"
    )

    $body = @{
        token = $token
        db = $DatabaseName
        sql = $Sql
        params = @()
    } | ConvertTo-Json -Depth 6 -Compress

    Write-DebugLog -Category 'SQL' -Message ("BEGIN [{0}] db={1} timeout={2}s sql={3}" -f $Context, $DatabaseName, $config.SQLTimeout, (($Sql -replace "`r|`n", ' ') -replace '\s+', ' ').Trim())

    try {
        $response = Invoke-RestMethod -Uri $cviEndpoint -Method Post -Body $body -ContentType "application/json" -TimeoutSec $config.SQLTimeout -ErrorAction Stop
        $rows = @(Normalize-ResponseRows -Response $response)
        $shape = if ($null -eq $response) { 'null' } else { ($response.PSObject.Properties.Name -join ',') }
        Write-DebugLog -Category 'SQL' -Message ("END   [{0}] db={1} rows={2} shape={3}" -f $Context, $DatabaseName, $rows.Count, $shape)
        return $rows
    }
    catch {
        $msg = $_.Exception.Message
        Write-DebugLog -Category 'SQL' -Message ("FAIL  [{0}] db={1} error={2}" -f $Context, $DatabaseName, $msg)
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
        elseif ($props -contains 'preview' -or $props -contains 'preview_text') {
            $src = if ($props -contains 'source_name' -and $row.source_name) { $row.source_name }                    elseif ($props -contains 'source_table' -and $row.source_table) { $row.source_table }                    elseif ($props -contains 'source_db' -and $row.source_db) { $row.source_db }                    else { 'long_term' }
            $previewValue = if ($props -contains 'preview' -and $row.preview) { $row.preview }                             elseif ($props -contains 'preview_text' -and $row.preview_text) { $row.preview_text }                             else { '' }
            $columnInfo = if ($props -contains 'source_column' -and $row.source_column) { " | cols=$($row.source_column)" } else { '' }
            "- [$src$columnInfo] $previewValue"
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

function Show-MemoryRowsPreview {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Rows,

        [string]$Kind = 'rows',

        [int]$MaxLines = 3,

        [string]$Indent = '      '
    )

    if (-not $Rows -or @($Rows).Count -eq 0) {
        return
    }

    $previewText = Format-MemoryRows -Rows @($Rows | Select-Object -First $MaxLines) -Kind $Kind
    $previewLines = @($previewText -split "`n")
    foreach ($line in $previewLines) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            Write-Host ($Indent + $line) -ForegroundColor DarkGray
        }
    }
}

function Safe-SqlQuery {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sql,

        [string]$Context = "SQL Query",

        [string]$DatabaseName = "pcde_memory"
    )

    Write-Host "   [SEARCH] $Context..." -ForegroundColor Gray
    try {
        $rows = Invoke-SqlQueryObjects -Sql $Sql -DatabaseName $DatabaseName -Context $Context

        if ($null -eq $rows) {
            return $null
        }

        $rows = @($rows)

        if ($rows.Count -eq 0) {
            return $null
        }

        Write-Host "   [OK] Success! ($($rows.Count) rows)" -ForegroundColor DarkGreen
        return $rows
    }
    catch {
        Write-Host "   [ERR] $Context failed: $($_.Exception.Message)" -ForegroundColor DarkRed
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




function Search-ProceduralMemory {
    param([string[]]$Keywords)

    $fields = @('procedure_name', 'description', 'domain', 'why_it_exists')
    $where = Build-WhereClause -Fields $fields -Keywords $Keywords

    $sql = @"
SELECT procedure_id, procedure_name, procedure_type, domain, description
FROM pcde_procedure_registry
WHERE $where
ORDER BY procedure_id DESC
LIMIT 5
"@

    return Safe-SqlQuery -Sql $sql -Context "Procedural Memory"
}

function Search-DeclarativeMemory {
    param([string[]]$Keywords)

    $fields = @('predicate', 'object_value', 'domain')
    $where = Build-WhereClause -Fields $fields -Keywords $Keywords

    $sql = @"
SELECT fact_id, fact_type, domain, predicate, object_value, confidence
FROM pcde_declarative_memory
WHERE $where
ORDER BY confidence DESC, fact_id DESC
LIMIT 5
"@

    return Safe-SqlQuery -Sql $sql -Context "Declarative Memory"
}

function Search-AssociativeMemory {
    param([string[]]$Keywords)

    $fields = @('relation_type', 'relation_target', 'notes')
    $where = Build-WhereClause -Fields $fields -Keywords $Keywords

    $sql = @"
SELECT relation_id, procedure_id, relation_type, relation_target, notes
FROM pcde_procedure_relations
WHERE $where
ORDER BY relation_id DESC
LIMIT 5
"@

    return Safe-SqlQuery -Sql $sql -Context "Associative Memory"
}

function Search-WorkingMemory {
    param(
        [string[]]$Keywords,
        [string]$SessionId
    )

    $fields = @('slot_value')
    $where = Build-WhereClause -Fields $fields -Keywords $Keywords

    $sql = @"
SELECT slot_key, slot_value, created_at
FROM pcde_working_memory
WHERE session_id = '$SessionId'
   AND $where
   AND expires_at > NOW()
ORDER BY created_at DESC
LIMIT 5
"@

    return Safe-SqlQuery -Sql $sql -Context "Working Memory"
}

function Search-AIMemory {
    param([string[]]$Keywords)

    $fields = @('key_data', 'memory_type', 'agent_name')
    $where = Build-WhereClause -Fields $fields -Keywords $Keywords

    $sql = @"
SELECT memory_id, agent_name, memory_type, key_data, confidence, access_count
FROM pcde_ai_memory
WHERE $where
ORDER BY confidence DESC, access_count DESC, memory_id DESC
LIMIT 5
"@

    return Safe-SqlQuery -Sql $sql -Context "AI Memory"
}

function Invoke-PCDEMemorySearchByType {
    param(
        [string]$MemoryType,
        [string]$Question,
        [string[]]$Keywords,
        [string]$SessionId,
        [object]$Rules
    )

    $label = Convert-PCDEMemoryNameToLabel -MemoryName $MemoryType -Rules $Rules

    switch ($MemoryType) {
        'procedural' {
            return Search-ProceduralMemory -Keywords $Keywords
        }
        'declarative' {
            return Search-DeclarativeMemory -Keywords $Keywords
        }
        'associative' {
            return Search-AssociativeMemory -Keywords $Keywords
        }
        'working' {
            return Search-WorkingMemory -Keywords $Keywords -SessionId $SessionId
        }
        'ai_memory' {
            return Search-AIMemory -Keywords $Keywords
        }
        default {
            throw "Unknown memory type in routing rules: $MemoryType"
        }
    }
}

function Set-PCDECandidateScoresFromRules {
    param(
        [object[]]$Candidates,
        [object]$Rules
    )

    foreach ($candidate in @($Candidates)) {
        $memoryType = $candidate.Source
        $basePriority = 0.50

        if ($memoryType -eq 'long_term') {
            $basePriority = 0.89
        }
        elseif ($Rules.memory_types.$memoryType.default_priority) {
            $basePriority = [double]$Rules.memory_types.$memoryType.default_priority
        }

        $candidate.Confidence = $basePriority
        $rowCountBonus = 0.0
        if ($candidate.Rows) {
            $rowCountBonus = [Math]::Min((@($candidate.Rows).Count * 0.01), 0.05)
        }

        $candidate.Score = [Math]::Round(($basePriority + $rowCountBonus), 4)
    }

    return @($Candidates | Sort-Object -Property @{Expression='Score';Descending=$true}, @{Expression='Confidence';Descending=$true}, @{Expression='Count';Descending=$true})
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
        'long_term'   { 0.89 }
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


function Get-PCDELongTermSearchTargets {
    # Comprehensive list of ALL searchable tables across both databases
    $targets = @()
    
    # LAKE KNOWLEDGE DATABASE - All tables with text content
    $lakeKnowledgeTables = @(
        @{ Table = "raw_artifacts"; IdColumn = "id"; PreviewFields = @("content"); SearchFields = @("content", "artifact_key", "inferred_topic") },
        @{ Table = "raw_conversations"; IdColumn = "id"; PreviewFields = @("content"); SearchFields = @("content") },
        @{ Table = "extracted_docs"; IdColumn = "id"; PreviewFields = @("title", "content"); SearchFields = @("title", "content", "source_ref") },
        @{ Table = "doc_sections"; IdColumn = "id"; PreviewFields = @("title", "content"); SearchFields = @("title", "content") },
        @{ Table = "knowledge_units"; IdColumn = "id"; PreviewFields = @("summary", "topic", "intent"); SearchFields = @("summary", "topic", "intent", "unit_type") },
        @{ Table = "knowledge_links"; IdColumn = "id"; PreviewFields = @("link_type", "rationale"); SearchFields = @("link_type", "rationale", "conversation_id") },
        @{ Table = "published_context_reports"; IdColumn = "report_id"; PreviewFields = @("component_name", "report_type", "report_content"); SearchFields = @("component_name", "report_type", "report_content") },
        @{ Table = "lake_signals"; IdColumn = "id"; PreviewFields = @("signal_name", "domain", "payload"); SearchFields = @("signal_name", "domain", "payload", "worker") },
        @{ Table = "cm_system_context_snapshots"; IdColumn = "snapshot_id"; PreviewFields = @("component_name", "context_snapshot"); SearchFields = @("component_name", "context_snapshot") },
        @{ Table = "topics"; IdColumn = "id"; PreviewFields = @("topic"); SearchFields = @("topic") },
        @{ Table = "ai_component_registry"; IdColumn = "component_id"; PreviewFields = @("component_name", "description"); SearchFields = @("component_name", "description", "component_type") },
        @{ Table = "ai_component_learning_log"; IdColumn = "learning_id"; PreviewFields = @("component_name", "milestone"); SearchFields = @("component_name", "milestone", "learning_phase") }
    )
    
    # LAKE VECTOR DATABASE - All tables with text content
    $lakeVectorTables = @(
        @{ Table = "raw_artifacts"; IdColumn = "id"; PreviewFields = @("content"); SearchFields = @("content", "artifact_key", "inferred_topic") },
        @{ Table = "raw_conversations"; IdColumn = "id"; PreviewFields = @("content"); SearchFields = @("content") },
        @{ Table = "extracted_docs"; IdColumn = "id"; PreviewFields = @("title", "content"); SearchFields = @("title", "content", "source_ref") },
        @{ Table = "doc_sections"; IdColumn = "id"; PreviewFields = @("title", "content"); SearchFields = @("title", "content") },
        @{ Table = "knowledge_units"; IdColumn = "id"; PreviewFields = @("summary", "topic", "intent"); SearchFields = @("summary", "topic", "intent", "unit_type") },
        @{ Table = "knowledge_links"; IdColumn = "id"; PreviewFields = @("link_type", "rationale"); SearchFields = @("link_type", "rationale", "conversation_id") },
        @{ Table = "published_context_reports"; IdColumn = "report_id"; PreviewFields = @("component_name", "report_type", "report_content"); SearchFields = @("component_name", "report_type", "report_content") },
        @{ Table = "semantic_vector_store"; IdColumn = "vector_id"; PreviewFields = @("content_text", "content_type"); SearchFields = @("content_text", "content_type", "source_table") },
        @{ Table = "cvi_carousel"; IdColumn = "id"; PreviewFields = @("component", "payload_type", "payload"); SearchFields = @("component", "payload_type", "payload") },
        @{ Table = "ai_memory_index"; IdColumn = "id"; PreviewFields = @("summary", "topic", "domain"); SearchFields = @("summary", "topic", "domain", "unit_type") },
        @{ Table = "cm_system_context_snapshots"; IdColumn = "snapshot_id"; PreviewFields = @("component_name", "context_snapshot"); SearchFields = @("component_name", "context_snapshot") },
        @{ Table = "cm_system_context_snapshots_neuronet_signals"; IdColumn = "snapshot_id"; PreviewFields = @("component_name", "signal_type", "context_snapshot"); SearchFields = @("component_name", "signal_type", "context_snapshot") },
        @{ Table = "topics"; IdColumn = "id"; PreviewFields = @("topic"); SearchFields = @("topic") }
    )
    
    # Build search targets for Lake Knowledge
    foreach ($tbl in $lakeKnowledgeTables) {
        # Build preview expression
        $previewParts = @()
        foreach ($field in $tbl.PreviewFields) {
            $previewParts += "COALESCE($field, '')"
        }
        $previewExpr = "LEFT(CONCAT_WS(' | ', $($previewParts -join ', ')), 220)"
        
        # Build WHERE clause with all search fields
        $whereParts = @()
        foreach ($field in $tbl.SearchFields) {
            $whereParts += "$field LIKE '%{0}%' ESCAPE '\\'"
        }
        $whereClause = "($($whereParts -join ' OR '))"
        
        $targets += [pscustomobject]@{
            Name = "Lake Knowledge - $($tbl.Table)"
            Database = "lake_knowledge"
            Table = $tbl.Table
            IdColumn = $tbl.IdColumn
            PreviewExpression = $previewExpr
            PreviewAlias = "preview"
            WhereClause = $whereClause
        }
    }
    
    # Build search targets for Lake Vector
    foreach ($tbl in $lakeVectorTables) {
        # Build preview expression
        $previewParts = @()
        foreach ($field in $tbl.PreviewFields) {
            $previewParts += "COALESCE($field, '')"
        }
        $previewExpr = "LEFT(CONCAT_WS(' | ', $($previewParts -join ', ')), 220)"
        
        # Build WHERE clause with all search fields
        $whereParts = @()
        foreach ($field in $tbl.SearchFields) {
            $whereParts += "$field LIKE '%{0}%' ESCAPE '\\'"
        }
        $whereClause = "($($whereParts -join ' OR '))"
        
        $targets += [pscustomobject]@{
            Name = "Lake Vector - $($tbl.Table)"
            Database = "lake_vector"
            Table = $tbl.Table
            IdColumn = $tbl.IdColumn
            PreviewExpression = $previewExpr
            PreviewAlias = "preview"
            WhereClause = $whereClause
        }
    }
    
    return $targets
}




function Normalize-RecallSearchTerm {
    param([string]$SearchTerm)

    if ([string]::IsNullOrWhiteSpace($SearchTerm)) { return '' }

    $term = $SearchTerm.ToLowerInvariant().Trim()
    $term = $term -replace '[\?\.,:;!]+', ' '
    $term = $term -replace "^what\s+is\s+", ''
    $term = $term -replace "^what's\s+", ''
    $term = $term -replace "^whats\s+", ''
    $term = $term -replace "^define\s+", ''
    $term = $term -replace "^meaning\s+of\s+", ''
    $term = $term -replace '\s+', ' '
    return $term.Trim()
}

function Resolve-RecallQueryType {
    param(
        [string]$Question,
        [string]$CurrentQueryType = 'general'
    )

    if (-not [string]::IsNullOrWhiteSpace($CurrentQueryType) -and $CurrentQueryType -ne 'general') {
        return $CurrentQueryType
    }

    $normalized = ''
    if (-not [string]::IsNullOrWhiteSpace($Question)) {
        $normalized = $Question.ToLowerInvariant().Trim()
    }

    if ($normalized -match '^(what\s+is|what''s|whats|define\b|meaning\s+of\b)') {
        return 'definition'
    }

    return 'general'
}

function Invoke-PCDELongTermRecall {
    param(
        [string]$SearchTerm,
        [string]$QueryType = "general",
        [int]$MaxRowsPerTarget = 25
    )

    $normalizedTerm = Normalize-RecallSearchTerm -SearchTerm $SearchTerm
    if ([string]::IsNullOrWhiteSpace($normalizedTerm)) {
        Write-Host "   [NONE] Empty search term, skipping long-term recall" -ForegroundColor DarkGray
        Write-DebugLog -Category 'RECALL' -Message 'Skipped long-term recall because normalized term was empty.'
        return @()
    }

    $effectiveQueryType = Resolve-RecallQueryType -Question $SearchTerm -CurrentQueryType $QueryType
    $effectiveLimit = if ($MaxRowsPerTarget -gt 0) { $MaxRowsPerTarget } else { 25 }

    $escapedTerm = $normalizedTerm -replace "'", "''"
    $escapedType = $effectiveQueryType -replace "'", "''"

    Write-Host "   [PROC] Calling long-term recall stored procedure..." -ForegroundColor Cyan
    Write-Host "      Term: '$normalizedTerm'" -ForegroundColor DarkGray
    Write-Host "      Type: $effectiveQueryType" -ForegroundColor DarkGray
    Write-Host "      Limit: $effectiveLimit" -ForegroundColor DarkGray

    $sql = "CALL xpdgxfsp_pcde_memory.pcde_long_term_memory_recall('$escapedTerm', '$escapedType', $effectiveLimit);"
    Write-DebugLog -Category 'RECALL' -Message ("Calling stored procedure with term='{0}' type='{1}' limit={2}" -f $normalizedTerm, $effectiveQueryType, $effectiveLimit)

    try {
        $rawResponse = Invoke-SqlRawResponse -Sql $sql -DatabaseName "pcde_memory" -Context 'LongTermRecallProc'
        if ($null -eq $rawResponse) {
            Write-DebugLog -Category 'RECALL' -Message 'Stored procedure returned null raw response.'
            return @()
        }

        $rawShape = $rawResponse.PSObject.Properties.Name -join ','
        Write-DebugLog -Category 'RECALL' -Message ("Raw stored procedure response shape: {0}" -f $rawShape)

        if ($rawResponse.PSObject.Properties.Name -contains 'rows') {
            $rowArray = @(Convert-AnyToArray -Value $rawResponse.rows)
            if ($rowArray.Count -gt 0) {
                $firstNames = (Get-RowPropertyNames -Row $rowArray[0]) -join ','
                Write-DebugLog -Category 'RECALL' -Message ("rows[0] property names: {0}" -f $firstNames)
            }
        }

        $evidenceRows = @(Extract-ProcedureEvidenceRows -Response $rawResponse)
        Write-DebugLog -Category 'RECALL' -Message ("Extracted evidence row count = {0}" -f $evidenceRows.Count)

        if ($evidenceRows.Count -gt 0) {
            Write-Host "   [OK] Long-term recall returned $($evidenceRows.Count) row(s)" -ForegroundColor Green
            $first = $evidenceRows[0] | ConvertTo-Json -Depth 6 -Compress
            Write-DebugLog -Category 'RECALL' -Message ("First extracted evidence row: {0}" -f $first)
            return $evidenceRows
        }

        $fallbackRows = @(Normalize-ResponseRows -Response $rawResponse)
        $fallbackRows = @($fallbackRows | Where-Object { $null -ne $_ })
        if ($fallbackRows.Count -gt 0) {
            $firstFallbackNames = (Get-RowPropertyNames -Row $fallbackRows[0]) -join ','
            Write-DebugLog -Category 'RECALL' -Message ("No evidence rows found. First fallback row properties: {0}" -f $firstFallbackNames)
        }
        Write-DebugLog -Category 'RECALL' -Message 'Stored procedure returned no extractable evidence rows.'
        return @()
    }
    catch {
        Write-Host "   [ERR] Long-term recall failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-DebugLog -Category 'RECALL' -Message ("Stored procedure call failed: {0}" -f $_.Exception.Message)
        return @()
    }
}

function Test-LongTermMemoryTables {
    Write-Host "`n? Testing Long-Term Memory Table Access" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    
    $targets = Get-PCDELongTermSearchTargets
    $foundTables = @()
    $missingTables = @()
    
    foreach ($target in $targets) {
        $sql = "SELECT COUNT(*) as count FROM $($target.Table) LIMIT 1"
        try {
            $result = Invoke-SqlQueryObjects -Sql $sql -DatabaseName $target.Database
            $foundTables += $target.Name
            Write-Host "[OK] $($target.Name) - Accessible" -ForegroundColor Green
        }
        catch {
            $missingTables += $target.Name
            Write-Host "[ERR] $($target.Name) - Not accessible: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    
    Write-Host "`n[STATUS] Summary:" -ForegroundColor Cyan
    Write-Host "   Accessible tables: $($foundTables.Count)" -ForegroundColor Green
    Write-Host "   Inaccessible tables: $($missingTables.Count)" -ForegroundColor DarkGray
}


function Invoke-PCDEPass1Decision {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Question,

        [string]$QueryType = "general",

        [object[]]$Candidates = @(),

        [object]$GroundingRules = $null,

        [string]$ArbiterMode = "general_resolution"
    )
    47
    $model = Get-OllamaModel
    if (-not $model) {
        return [pscustomobject]@{
            sufficient = $false
            needs_long_term_recall = ($Candidates.Count -eq 0)
            confidence = 0.0
            recall_terms = @($Question)
        }
    }

    $previewItems = @()
    foreach ($candidate in @($Candidates | Sort-Object -Property Score, Confidence, Count -Descending | Select-Object -First 5)) {
        $previewText = ""
        if ($candidate.Rows -and @($candidate.Rows).Count -gt 0) {
            $previewText = Format-MemoryRows -Rows @($candidate.Rows | Select-Object -First 2) -Kind $candidate.Source
            if ($previewText.Length -gt 240) {
                $previewText = $previewText.Substring(0,240)
            }
        }

        $previewItems += [pscustomobject]@{
            memory_type = $candidate.Source
            label = $candidate.Label
            preview = $previewText
        }
    }

    $systemPrompt = @"
You are operating inside the PCDE cognitive system.

Do NOT answer the user's question yet.

Your job is only to assess whether the currently retrieved memory is sufficient, or whether long-term recall is needed.

Rules:
- Prefer system memory over general knowledge.
- If the current evidence is incomplete, ambiguous, conflicting, or likely too shallow, request long-term recall.
- If the current evidence appears sufficient and grounded, do not request long-term recall.
- Be strict and conservative.
- Return JSON only.

Return this schema:
{
  "sufficient": true,
  "needs_long_term_recall": false,
  "confidence": 0.0,
  "recall_terms": ["term1","term2"]
}
"@

    $payload = [pscustomobject]@{
        question = $Question
        query_type = $QueryType
        arbiter_mode = $ArbiterMode
        grounding_rules = $GroundingRules
        candidates = $previewItems
    } | ConvertTo-Json -Depth 8 -Compress

    $body = @{
        model = $model
        system = $systemPrompt
        prompt = $payload
        stream = $false
        format = 'json'
        options = @{
            temperature = 0.1
            num_predict = 200
        }
    } | ConvertTo-Json -Depth 8

    try {
        $response = Invoke-RestMethod -Uri "$($config.OllamaUrl)/api/generate" -Method Post -Body $body -ContentType "application/json"
        $raw = [string]$response.response
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        $terms = @()
        if ($parsed.recall_terms) { $terms = @($parsed.recall_terms | ForEach-Object { [string]$_ }) }
        if ($terms.Count -eq 0 -and ($parsed.needs_long_term_recall -eq $true)) { $terms = @($Question) }

        return [pscustomobject]@{
            sufficient = [bool]$parsed.sufficient
            needs_long_term_recall = [bool]$parsed.needs_long_term_recall
            confidence = if ($null -ne $parsed.confidence -and "$($parsed.confidence)" -ne '') { [double]$parsed.confidence } else { 0.0 }
            recall_terms = $terms
        }
    }
    catch {
        return [pscustomobject]@{
            sufficient = $false
            needs_long_term_recall = ($Candidates.Count -eq 0)
            confidence = 0.0
            recall_terms = @($Question)
        }
    }
}


function Invoke-OllamaMemoryArbiter {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Question,

        [object[]]$Candidates = @(),

        [string[]]$Keywords = @(),

        [string]$QueryType = "general",

        [object]$GroundingRules = $null,

        [string]$ArbiterMode = "general_resolution"
    )

    $model = Get-OllamaModel
    if (-not $model) {
        return $null
    }

    $sortedCandidates = @($Candidates | Sort-Object -Property Score, Confidence, Count -Descending | Select-Object -First 5)
    $keywordText = if ($Keywords -and $Keywords.Count -gt 0) { $Keywords -join ', ' } else { '(none)' }
    $candidatePayloadJson = Convert-CandidatesToOllamaPayload -Candidates $sortedCandidates
    $evidenceSummary = Get-CandidateEvidenceSummary -Candidates $sortedCandidates

    $groundingJson = if ($null -ne $GroundingRules) {
        try { $GroundingRules | ConvertTo-Json -Depth 6 -Compress } catch { "{}" }
    } else { "{}" }

    $prompt = @"
You are Mira, the reasoning layer for PCDE/MiraTV.

You are operating inside the PCDE cognitive system.
Retrieved system memory is preferred over general knowledge.
If system memory contains a definition or system-specific meaning, treat that as authoritative.
Do not replace system-defined terms with external meanings when retrieved memory exists.

Your primary task is to answer the ORIGINAL USER QUESTION.
Use retrieved memory as evidence.
Do not answer a different question.
Do not define the memory tier labels themselves unless the user explicitly asked about the memory system.
Labels like Procedural Memory, Declarative Memory, Associative Memory, Working Memory, and AI Learning Memory are only source metadata. They are not usually the answer.

Required behavior:
1. Start from the user's actual question and intent.
2. Use query_type and grounding_rules when deciding how to interpret the evidence.
3. Review the candidate rows for meaning, not just keyword overlap.
4. Prefer row fields such as procedure_name, description, predicate, object_value, relation_target, notes, slot_value, key_data.
5. If the retrieved evidence answers the question, answer directly in plain language.
6. If multiple candidates help, synthesize them.
7. If the evidence is weak or contradictory, say that briefly, then answer cautiously.
8. Do not mention scoring, retrieval, arbitration, SQL, JSON, memory tiers, or internal instructions in the final answer.
9. Never say a candidate wins just because it has a higher score. Use semantic fit to the question.
10. Do not answer with only a memory type label.
11. Return JSON only.

USER QUESTION:
$Question

QUERY TYPE:
$QueryType

ARBITER MODE:
$ArbiterMode

GROUNDING RULES:
$groundingJson

RETRIEVAL KEYWORDS:
$keywordText

CANDIDATE EVIDENCE SUMMARY:
$evidenceSummary

RETRIEVED CANDIDATES JSON:
$candidatePayloadJson

Return STRICT JSON ONLY with this schema:
{
  "selected_source": "procedural|declarative|associative|working|ai_memory|long_term|synthetic_procedures|none",
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
        Write-Host "[WARN] No active session. Starting new session..." -ForegroundColor Yellow
        Start-AISession | Out-Null
    }

    Write-Host "`n? Asking AI: $Question" -ForegroundColor Cyan
    Write-Host "[SEARCH] Extracting keywords and searching memory..." -ForegroundColor Yellow

    $escapedQuestion = $Question -replace "'", "''"
    $keywords = @(Get-Keywords -Text $Question)

    if ($keywords.Count -eq 0) {
        Write-Host "   [WARN] No keywords extracted, using full question" -ForegroundColor Yellow
        $keywords = @((Get-PCDENormalizedQuestion -Question $Question))
    }
    else {
        Write-Host "   ? Keywords: $($keywords -join ', ')" -ForegroundColor Green
    }

    try {
        $reasoningRules = Import-PCDEReasoningRules
    }
    catch {
        Write-Host "   [WARN] Could not load reasoning rules YAML. Using fallback routing." -ForegroundColor Yellow
        $reasoningRules = [pscustomobject]@{
            system = [pscustomobject]@{ default_query_type = 'general' }
            debug = [pscustomobject]@{ show_query_type = $false; show_selected_evidence_set = $true }
            candidate_selection = [pscustomobject]@{ max_candidates_sent_to_arbiter = 8 }
            memory_types = [pscustomobject]@{
                procedural = [pscustomobject]@{ label = 'Procedural Memory'; default_priority = 0.90 }
                declarative = [pscustomobject]@{ label = 'Declarative Memory'; default_priority = 0.95 }
                associative = [pscustomobject]@{ label = 'Associative Memory'; default_priority = 0.80 }
                working = [pscustomobject]@{ label = 'Working Memory'; default_priority = 0.75 }
                ai_memory = [pscustomobject]@{ label = 'AI Learning Memory'; default_priority = 0.78 }
            }
        }
        $routingPlan = [pscustomobject]@{
            QueryType = 'general'
            QuerySignature = 'general::freeform'
            PreferredOrder = @('declarative','procedural','associative','ai_memory','working')
            Grounding = $null
            ArbiterMode = 'general_resolution'
            Matches = @()
        }
    }

    if (-not $routingPlan) {
        $routingPlan = Get-PCDERoutingPlan -Question $Question -Rules $reasoningRules
    }

    if ($reasoningRules.debug.show_query_type -eq $true) {
        Write-Host ("   ? Query Type: {0}" -f $routingPlan.QueryType) -ForegroundColor Yellow
    }

    $normalizedQuestion = Get-PCDENormalizedQuestion -Question $Question
    $queryType = $routingPlan.QueryType
    $querySignature = $routingPlan.QuerySignature
    $retrievalStrategy = ($routingPlan.PreferredOrder -join " -> ")

    $memoryResult = $null
    $memorySource = ""
    $confidence = 0
    $memoryCandidates = @()
    $bestCandidate = $null
    $searchedMemoryTypes = @()

    foreach ($memoryType in @($routingPlan.PreferredOrder)) {
        $searchedMemoryTypes += $memoryType
        $label = Convert-PCDEMemoryNameToLabel -MemoryName $memoryType -Rules $reasoningRules
        $memoryIcon = switch ($memoryType) {
            'procedural' { '[PROC]' }
            'declarative' { '[DECL]' }
            'associative' { '[ASSOC]' }
            'working' { '[WORK]' }
            'ai_memory' { '[AI]' }
            default { '?' }
        }
        Write-Host ("   {0} Searching {1}..." -f $memoryIcon, $label) -ForegroundColor Cyan

        try {
            $rows = Invoke-PCDEMemorySearchByType -MemoryType $memoryType -Question $Question -Keywords $keywords -SessionId $script:aiSessionId -Rules $reasoningRules
            if ($rows -and @($rows).Count -gt 0) {
                Write-Host ("   [OK] Found in {0} ({1} rows)" -f $label, @($rows).Count) -ForegroundColor Green
                Show-MemoryRowsPreview -Rows @($rows) -Kind $memoryType -MaxLines 3
                $defaultConfidence = if ($reasoningRules.memory_types.$memoryType.default_priority) { [double]$reasoningRules.memory_types.$memoryType.default_priority } else { 0.70 }
                $candidate = New-MemoryCandidate -Source $memoryType -Label $label -Rows $rows -DefaultConfidence $defaultConfidence
                if ($candidate) { $memoryCandidates += $candidate }
            } else {
                Write-Host ("   [NONE] No results in {0}" -f $label) -ForegroundColor DarkGray
            }
        }
        catch {
            Write-Host ("   [ERR] {0} failed: {1}" -f $label, $_.Exception.Message) -ForegroundColor Red
        }
    }

    if ($memoryCandidates.Count -gt 0) {
        $memoryCandidates = Set-PCDECandidateScoresFromRules -Candidates $memoryCandidates -Rules $reasoningRules
        $bestCandidate = $memoryCandidates | Select-Object -First 1
        $memoryResult = @($bestCandidate.Rows)
        $memorySource = $bestCandidate.Source
        $confidence = $bestCandidate.Confidence

        if ($reasoningRules.debug.show_selected_evidence_set -ne $false) {
            Write-Host ("   [BEST] Selected evidence set: {0}" -f $bestCandidate.Label) -ForegroundColor Magenta
        }
    }

    if (-not $memoryResult -and ($Question -match "procedures?" -or $Question -match "what (procedures|services) (do you have|are available)")) {
        Write-Host "   [PROC] Checking for available procedures in database..." -ForegroundColor Cyan

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
                Write-Host "   [OK] Built synthetic procedure candidate" -ForegroundColor Green
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

    $pass1 = Invoke-PCDEPass1Decision `
        -Question $Question `
        -QueryType $queryType `
        -Candidates $memoryCandidates `
        -GroundingRules $routingPlan.Grounding `
        -ArbiterMode $routingPlan.ArbiterMode

    Write-Host ("   [AI] Pass1 -> sufficient={0} recall={1}" -f $pass1.sufficient, $pass1.needs_long_term_recall) -ForegroundColor Cyan

    if ($pass1.needs_long_term_recall -eq $true) {
        $recallTerms = @($pass1.recall_terms)
        if ($recallTerms.Count -eq 0) {
            $recallTerms = @($Question)
        }

        $longTermSearch = ($recallTerms -join " ")
        Write-Host ("   [RECALL] Long-term recall: {0}" -f $longTermSearch) -ForegroundColor Yellow

        $longTermRows = @(Invoke-PCDELongTermRecall -SearchTerm $longTermSearch -QueryType $queryType -MaxRowsPerTarget 25)
        if ($longTermRows.Count -gt 0) {
            Write-Host ("   [OK] Long-term recall returned {0} rows" -f $longTermRows.Count) -ForegroundColor Green
            Show-MemoryRowsPreview -Rows @($longTermRows) -Kind 'long_term' -MaxLines 5

            $memoryCandidates += [pscustomobject]@{
                Source = 'long_term'
                Label = 'Long Term Memory'
                Rows = @($longTermRows)
                Confidence = 0.89
                Score = 0.90
                Count = @($longTermRows).Count
            }

            $memoryCandidates = @($memoryCandidates | Sort-Object -Property Score, Confidence, Count -Descending)
            $bestCandidate = $memoryCandidates | Select-Object -First 1
            $memoryResult = @($bestCandidate.Rows)
            $memorySource = $bestCandidate.Source
            $confidence = $bestCandidate.Confidence

            if ($reasoningRules.debug.show_selected_evidence_set -ne $false) {
                Write-Host ("   [BEST] Reconciled evidence set: {0}" -f $bestCandidate.Label) -ForegroundColor Magenta
            }
        }
        else {
            Write-Host "   [NONE] Long-term recall returned no additional rows" -ForegroundColor DarkGray
            Write-Host ("   [LOG] Debug log: {0}" -f (Join-Path $logDir (("master_control_debug_{0}.log" -f (Get-Date -Format "yyyyMMdd"))))) -ForegroundColor DarkYellow
        }
    }

    Write-Host "[OLLAMA] Asking Ollama to evaluate the question against retrieved memory..." -ForegroundColor Yellow
    $arbiterCandidates = @($memoryCandidates | Select-Object -First $reasoningRules.candidate_selection.max_candidates_sent_to_arbiter)
    $arbiterResult = Invoke-OllamaMemoryArbiter `
        -Question $Question `
        -Candidates $arbiterCandidates `
        -Keywords $keywords `
        -QueryType $queryType `
        -GroundingRules $routingPlan.Grounding `
        -ArbiterMode $routingPlan.ArbiterMode

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
            query_type = $queryType
            query_signature = $querySignature
            retrieval_strategy = $retrievalStrategy
            searched_memory_types = $searchedMemoryTypes
        }
    }

    if ($memoryResult) {
        Write-Host "[WARN] Ollama unavailable. Falling back to highest-scoring retrieved memory." -ForegroundColor Yellow

        $formattedAnswer = Format-MemoryRows -Rows $memoryResult -Kind $memorySource
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
            query_type = $queryType
            query_signature = $querySignature
            retrieval_strategy = $retrievalStrategy
            searched_memory_types = $searchedMemoryTypes
        }
    }

    Write-Host "[OLLAMA] No memory matches and Ollama arbitration unavailable. Using plain Ollama fallback if possible..." -ForegroundColor Yellow

    $model = Get-OllamaModel
    if (-not $model) {
        return @{
            answer = "I'm Mira, your AI assistant. I can help you with questions about the MiraTV system, but no stored memory matched and Ollama was not reachable."
            source = "fallback"
            confidence = 0.5
            query_type = $queryType
            query_signature = $querySignature
            retrieval_strategy = $retrievalStrategy
            searched_memory_types = $searchedMemoryTypes
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
            query_type = $queryType
            query_signature = $querySignature
            retrieval_strategy = $retrievalStrategy
            searched_memory_types = $searchedMemoryTypes
        }
    }
    catch {
        return @{
            answer = "I'm Mira, your AI assistant. I can help you with questions about the MiraTV system, but no stored memory matched and Ollama was unavailable."
            source = "fallback"
            confidence = 0.5
            query_type = $queryType
            query_signature = $querySignature
            retrieval_strategy = $retrievalStrategy
            searched_memory_types = $searchedMemoryTypes
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
        Write-Host "`n? Chat History:" -ForegroundColor Cyan
        Write-Host "================" -ForegroundColor Cyan

        foreach ($row in @($history)) {
            $text = [string]$row.slot_value
            if ($row.slot_key -like 'q_*') {
                Write-Host "? $text" -ForegroundColor White
            }
            elseif ($row.slot_key -like 'a_*') {
                if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + "..." }
                Write-Host "[OLLAMA] $text" -ForegroundColor Green
            }
        }
    } else {
        Write-Host "No chat history" -ForegroundColor Yellow
    }
}

function Show-MemoryStats {
    Write-Host "`n[STATUS] MEMORY SYSTEM STATISTICS" -ForegroundColor Cyan
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
            Write-Host "`n[START] STARTING ALL SERVICES" -ForegroundColor Cyan
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
            Write-Host "[OK] All services started" -ForegroundColor Green
            Read-Host "Press Enter to continue"
        }
        "2" { 
            Get-Job | Stop-Job
            Get-Job | Remove-Job
            Write-Host "[OK] All services stopped" -ForegroundColor Green
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
            Write-Host "[OK] AI Learning started" -ForegroundColor Green
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
            Write-Host "[OK] Learning Loop started" -ForegroundColor Green
            Read-Host "Press Enter to continue"
        }
        "10" { 
            Start-Job -Name "AccessoryLoop" -ScriptBlock {
                while($true) {
                    & "C:\miratv_ingest\MASTER_ACCESSORY_UPLOAD_LOOP.bat"
                    Start-Sleep -Seconds 60
                }
            }
            Write-Host "[OK] Accessory Loop started" -ForegroundColor Green
            Read-Host "Press Enter to continue"
        }
        "11" { 
            Start-Job -Name "RunnerLoop" -ScriptBlock {
                while($true) {
                    & "C:\miratv_ingest\master_runner_loop.bat"
                    Start-Sleep -Seconds 120
                }
            }
            Write-Host "[OK] Runner Loop started" -ForegroundColor Green
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
                Write-Host "[OK] Export complete: $exportFile" -ForegroundColor Green
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
            Write-Host "[OK] Mastery Accessory Loop started" -ForegroundColor Green
            Read-Host "Press Enter to continue"
        }
        "18" {
            Start-Job -Name "MainSeriesLoop" -ScriptBlock {
                while($true) {
                    & "C:\miratv_ingest\master_runner_loop.bat"
                    Start-Sleep -Seconds 120
                }
            }
            Write-Host "[OK] Main Series Loop started" -ForegroundColor Green
            Read-Host "Press Enter to continue"
        }
        "19" {
            Start-Job -Name "MasterUploadLoop" -ScriptBlock {
                while($true) {
                    & "C:\miratv_ingest\MASTER_UPLOAD_LOOP.bat"
                    Start-Sleep -Seconds 60
                }
            }
            Write-Host "[OK] Master Upload Loop started" -ForegroundColor Green
            Read-Host "Press Enter to continue"
        }
        "25" {
            if (Test-Path "C:\miratv_ingest\Find-FileRelationships.ps1") {
                & "C:\miratv_ingest\Find-FileRelationships.ps1"
                Write-Host "[OK] Relationship Finder executed" -ForegroundColor Green
            } else {
                Write-Host "[WARN] Relationship Finder script not found: C:\miratv_ingest\Find-FileRelationships.ps1" -ForegroundColor Yellow
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
                Write-Host "`n[OLLAMA] [$($result.source)] $($result.answer)" -ForegroundColor Green
            }
            Read-Host "`nPress Enter to continue"
        }
        "22" { 
            Show-ChatHistory
            Read-Host "Press Enter to continue"
        }
        "23" { 
            $script:aiSessionId = $null
            Write-Host "[OK] Chat session cleared" -ForegroundColor Green
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