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

# =========================
# BGC RUNTIME LOAD
# =========================

$script:BgcContext = $null
$script:BGC_GovernanceEnabled = $false
$script:BGC_PartialAllowed = $true

$bgcConsumerPath = "C:\MiraTV\Modules\IMG\BGC\BGC_Runtime_Consumer.ps1"

if (Test-Path $bgcConsumerPath) {
    try {
        . $bgcConsumerPath -RuntimePath "C:\MiraTV\Modules\IMG\BGC\runtime\active_runtime.psd1"

        if ($null -ne $script:BgcContext) {
            $script:BGC_GovernanceEnabled = [bool](Get-BgcControlValue `
                -BgcContext $script:BgcContext `
                -Section "switches" `
                -Key "governance_enforcement")

            $partialAllowedValue = Get-BgcBehaviorValue `
                -BgcContext $script:BgcContext `
                -Section "processing" `
                -Key "partial_allowed"

            if ($null -ne $partialAllowedValue) {
                $script:BGC_PartialAllowed = [bool]$partialAllowedValue
            }

            Write-Host ""
            Write-Host "[BGC] Runtime Loaded" -ForegroundColor Green
            Write-Host "[BGC] Governance Enabled : $script:BGC_GovernanceEnabled" -ForegroundColor Cyan
            Write-Host "[BGC] Partial Allowed    : $script:BGC_PartialAllowed" -ForegroundColor Cyan
            Write-Host ""
        } else {
            Write-Host "[BGC] Consumer loaded but context is null" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "[BGC] Failed to load runtime: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
else {
    Write-Host "[BGC] Consumer not found   running without BGC" -ForegroundColor DarkYellow
}

function Test-BgcRule {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RuleCode
    )

    if (-not $script:BGC_GovernanceEnabled) { return $true }
    if (-not $script:BgcContext) { return $true }
    if (Get-Command Test-BgcRuleEnabled -ErrorAction SilentlyContinue) {
        return (Test-BgcRuleEnabled -BgcContext $script:BgcContext -RuleCode $RuleCode)
    }
    return $true
}

function Write-DebugLog {
    param(
        [string]$Message,
        [string]$Category = "GENERAL"
    )

    try {
        if (-not $config.DebugLogging) { return }
        if (-not (Test-Path $logDir)) { 
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null 
        }
        $logFile = Join-Path $logDir ("master_control_debug_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
        $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Category, $Message
        Add-Content -Path $logFile -Value $line -Encoding UTF8
    }
    catch { }
}

# ============================================================
# PCDE REASONING RULES
# ============================================================

function Get-PCDEYamlModuleAvailable {
    return [bool](Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)
}

function Import-PCDEReasoningRules {
    param(
        [string]$YamlPath = "C:\miratv_ingest\pcde_reasoning_rules.yaml"
    )

    if (-not (Test-Path $YamlPath)) {
        return $null
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

    return $null
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

    # If TriggerConfig is null or not an object, no match
    if ($null -eq $TriggerConfig) { 
        Write-DebugLog -Category "PCDE" -Message "Test-PCDEQueryTypeMatch: TriggerConfig is null"
        return $false 
    }

    $normalized = Get-PCDENormalizedQuestion -Question $Question
    $termCount  = Get-PCDEQuestionTermCount -Question $normalized

    # Safely check default property
    $hasDefault = $false
    if ($TriggerConfig -is [PSCustomObject] -and $TriggerConfig.PSObject.Properties.Name -contains 'default') {
        try {
            $hasDefault = ($TriggerConfig.default -eq $true)
        }
        catch {
            $hasDefault = $false
        }
    }
    
    if ($hasDefault) {
        Write-DebugLog -Category "PCDE" -Message "Test-PCDEQueryTypeMatch: default match"
        return $true
    }

    # Safely check max_terms
    $maxTerms = 0
    $hasMaxTerms = $false
    if ($TriggerConfig -is [PSCustomObject] -and $TriggerConfig.PSObject.Properties.Name -contains 'max_terms') {
        try {
            $maxTerms = [int]$TriggerConfig.max_terms
            $hasMaxTerms = $true
        }
        catch {
            $hasMaxTerms = $false
        }
    }
    
    if ($hasMaxTerms -and $termCount -gt $maxTerms) {
        Write-DebugLog -Category "PCDE" -Message "Test-PCDEQueryTypeMatch: term count $termCount exceeds max $maxTerms"
        return $false
    }

    # Check starts_with
    if ($TriggerConfig -is [PSCustomObject] -and $TriggerConfig.PSObject.Properties.Name -contains 'starts_with') {
        try {
            $prefixes = @($TriggerConfig.starts_with)
            foreach ($prefix in $prefixes) {
                if ($normalized.StartsWith(([string]$prefix).ToLowerInvariant())) {
                    Write-DebugLog -Category "PCDE" -Message "Test-PCDEQueryTypeMatch: starts_with match on '$prefix'"
                    return $true
                }
            }
        }
        catch { }
    }

    # Check contains
    if ($TriggerConfig -is [PSCustomObject] -and $TriggerConfig.PSObject.Properties.Name -contains 'contains') {
        try {
            $needles = @($TriggerConfig.contains)
            foreach ($needle in $needles) {
                if ($normalized -like ("*" + ([string]$needle).ToLowerInvariant() + "*")) {
                    Write-DebugLog -Category "PCDE" -Message "Test-PCDEQueryTypeMatch: contains match on '$needle'"
                    return $true
                }
            }
        }
        catch { }
    }

    # Check regex
    if ($TriggerConfig -is [PSCustomObject] -and $TriggerConfig.PSObject.Properties.Name -contains 'regex') {
        try {
            $patterns = @($TriggerConfig.regex)
            foreach ($pattern in $patterns) {
                if ($normalized -match [string]$pattern) {
                    Write-DebugLog -Category "PCDE" -Message "Test-PCDEQueryTypeMatch: regex match on '$pattern'"
                    return $true
                }
            }
        }
        catch { }
    }

    Write-DebugLog -Category "PCDE" -Message "Test-PCDEQueryTypeMatch: no match"
    return $false
}

function Get-PCDEMatchedQueryTypes {
    param(
        [string]$Question,
        [object]$Rules
    )

    $matches = @()
    
    if ($null -eq $Rules) {
        Write-DebugLog -Category "PCDE" -Message "Get-PCDEMatchedQueryTypes: Rules is null"
        return $matches
    }
    
    if ($null -eq $Rules.query_types) {
        Write-DebugLog -Category "PCDE" -Message "Get-PCDEMatchedQueryTypes: Rules.query_types is null"
        return $matches
    }

    $queryTypes = $Rules.query_types
    $items = @()
    
    # Handle different structures of query_types
    if ($queryTypes -is [System.Collections.IDictionary]) {
        foreach ($key in $queryTypes.Keys) {
            $items += [PSCustomObject]@{
                QueryType = $key
                Config = $queryTypes[$key]
            }
        }
    }
    elseif ($queryTypes -is [PSCustomObject]) {
        $props = $queryTypes.PSObject.Properties
        foreach ($prop in $props) {
            $items += [PSCustomObject]@{
                QueryType = $prop.Name
                Config = $prop.Value
            }
        }
    }
    else {
        Write-DebugLog -Category "PCDE" -Message "Get-PCDEMatchedQueryTypes: Unknown query_types type"
        return $matches
    }

    Write-DebugLog -Category "PCDE" -Message "Get-PCDEMatchedQueryTypes: Found $($items.Count) query types"

    # Filter by trigger matching
    $matched = @()
    foreach ($item in $items) {
        # Get triggers - could be a property or a nested object
        $triggerConfig = $null
        
        if ($item.Config -is [PSCustomObject] -and $item.Config.PSObject.Properties.Name -contains 'triggers') {
            $triggerConfig = $item.Config.triggers
            Write-DebugLog -Category "PCDE" -Message "Get-PCDEMatchedQueryTypes: Found triggers in Config object for $($item.QueryType)"
        }
        elseif ($item.Config -is [System.Collections.IDictionary] -and $item.Config.ContainsKey('triggers')) {
            $triggerConfig = $item.Config['triggers']
            Write-DebugLog -Category "PCDE" -Message "Get-PCDEMatchedQueryTypes: Found triggers in Config dictionary for $($item.QueryType)"
        }
        
        # If no triggers defined, skip this query type
        if ($null -eq $triggerConfig) {
            Write-DebugLog -Category "PCDE" -Message "Get-PCDEMatchedQueryTypes: No triggers for $($item.QueryType), skipping"
            continue
        }
        
        if (Test-PCDEQueryTypeMatch -Question $Question -TriggerConfig $triggerConfig) {
            Write-DebugLog -Category "PCDE" -Message "Get-PCDEMatchedQueryTypes: MATCH on $($item.QueryType)"
            $matched += $item
        }
    }

    Write-DebugLog -Category "PCDE" -Message "Get-PCDEMatchedQueryTypes: Total matches = $($matched.Count)"
    return $matched
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
        if ($Rules.query_types -is [System.Collections.IDictionary] -and $Rules.query_types.Contains($defaultType)) {
            $defaultConfig = $Rules.query_types[$defaultType]
        }
        elseif ($Rules.query_types -is [PSCustomObject] -and $null -ne $Rules.query_types.$defaultType) {
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
    if ($config -and $config.preferred_memory_order) {
        $memoryOrder = @($config.preferred_memory_order)
    }
    elseif ($Rules -and $Rules.default_preferred_order) {
        $memoryOrder = @($Rules.default_preferred_order)
    }

    if ($memoryOrder.Count -eq 0) {
        $memoryOrder = @('declarative', 'procedural', 'associative', 'ai_memory', 'working')
    }

    $arbiterMode = "general_resolution"
    if ($config -and $config.arbiter_mode) {
        $arbiterMode = [string]$config.arbiter_mode
    }

    $grounding = $null
    if ($config -and $config.grounding) {
        $grounding = $config.grounding
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

    if ($Rules -and $Rules.memory_types -and $Rules.memory_types.$MemoryName -and $Rules.memory_types.$MemoryName.label) {
        return [string]$Rules.memory_types.$MemoryName.label
    }

    return $MemoryName
}

# ============= DATABASE ACCESS =============
$token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$cviEndpoint = "https://miratv.club/_workers/api/series/dog_open_proc.php"

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

    Write-DebugLog -Category 'SQL' -Message ("BEGIN [{0}] db={1}" -f $Context, $DatabaseName)

    try {
        $response = Invoke-RestMethod -Uri $cviEndpoint -Method Post -Body $body -ContentType "application/json" -TimeoutSec $config.SQLTimeout -ErrorAction Stop
        
        $rows = @()
        if ($response -and $response.PSObject.Properties.Name -contains 'rows') {
            $rows = @($response.rows)
        }
        elseif ($response -and $response -is [array]) {
            $rows = @($response)
        }
        
        Write-DebugLog -Category 'SQL' -Message ("END   [{0}] db={1} rows={2}" -f $Context, $DatabaseName, $rows.Count)
        return $rows
    }
    catch {
        Write-DebugLog -Category 'SQL' -Message ("FAIL  [{0}] db={1} error={2}" -f $Context, $DatabaseName, $_.Exception.Message)
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

        if ($null -eq $rows -or @($rows).Count -eq 0) {
            Write-Host "   [NONE] No results" -ForegroundColor DarkGray
            return $null
        }

        $rowCount = @($rows).Count
        Write-Host "   [OK] Success! ($rowCount rows)" -ForegroundColor DarkGreen
        return $rows
    }
    catch {
        Write-Host "   [ERR] $Context failed: $($_.Exception.Message)" -ForegroundColor DarkRed
        return $null
    }
}

# ============= KEYWORD EXTRACTION =============
function Get-Keywords {
    param([string]$Text)
    
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }
    
    $words = $Text -split '\s+' | ForEach-Object { 
        $_.Trim('?.,!;:()[]{}"''').ToLower() 
    }
    
    $stopWords = @(
        'who', 'what', 'where', 'when', 'why', 'how', 'which', 'whose',
        'is', 'are', 'was', 'were', 'be', 'been', 'being',
        'do', 'does', 'did', 'done', 'doing',
        'can', 'could', 'will', 'would', 'shall', 'should', 'may', 'might', 'must',
        'the', 'a', 'an', 'and', 'or', 'but', 'if', 'then', 'else', 'when',
        'up', 'so', 'too', 'very', 'just', 'now', 'then'
    )
    
    $keywords = @($words | Where-Object { 
        $_.Length -gt 2 -and $stopWords -notcontains $_
    } | Select-Object -Unique)
    
    return $keywords
}

function Build-WhereClause {
    param(
        [string[]]$Fields,
        [string[]]$Keywords
    )
    
    if ($Keywords.Count -eq 0) { return "1=0" }
    
    $conditions = @()
    foreach ($field in $Fields) {
        foreach ($keyword in $Keywords) {
            $escapedKeyword = $keyword -replace "'", "''"
            $conditions += "$field LIKE '%$escapedKeyword%'"
        }
    }
    
    $conditionString = $conditions -join " OR "
    return "($conditionString)"
}

# ============= MEMORY SEARCH FUNCTIONS =============
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
        'procedural' { return Search-ProceduralMemory -Keywords $Keywords }
        'declarative' { return Search-DeclarativeMemory -Keywords $Keywords }
        'associative' { return Search-AssociativeMemory -Keywords $Keywords }
        'working' { return Search-WorkingMemory -Keywords $Keywords -SessionId $SessionId }
        'ai_memory' { return Search-AIMemory -Keywords $Keywords }
        default { return $null }
    }
}

# ============= FORMATTING FUNCTIONS =============
function Format-MemoryRows {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Rows,

        [string]$Kind = "rows"
    )

    if (-not $Rows -or @($Rows).Count -eq 0) {
        return "No $Kind found."
    }

    $lines = @()
    foreach ($row in @($Rows) | Select-Object -First 5) {
        $props = $row.PSObject.Properties.Name

        if ($props -contains 'procedure_name') {
            $desc = if ($props -contains 'description' -and $row.description) { $row.description } else { "" }
            $lines += "- $($row.procedure_name) | domain=$($row.domain) | type=$($row.procedure_type)"
        }
        elseif ($props -contains 'predicate') {
            $lines += "- $($row.predicate) -> $($row.object_value) | domain=$($row.domain) | confidence=$($row.confidence)"
        }
        elseif ($props -contains 'relation_type') {
            $lines += "- relation=$($row.relation_type) | target=$($row.relation_target)"
        }
        elseif ($props -contains 'slot_key') {
            $val = if ($row.slot_value.Length -gt 80) { $row.slot_value.Substring(0, 80) + "..." } else { $row.slot_value }
            $lines += "- $($row.slot_key) = $val"
        }
        elseif ($props -contains 'memory_type') {
            $lines += "- $($row.memory_type) | key=$($row.key_data) | confidence=$($row.confidence)"
        }
        else {
            $lines += "- " + (($row | Out-String).Trim() -replace '\s+', ' ')
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

    if (-not $Rows -or @($Rows).Count -eq 0) { return }

    $previewText = Format-MemoryRows -Rows @($Rows | Select-Object -First $MaxLines) -Kind $Kind
    $previewLines = @($previewText -split "`n")
    foreach ($line in $previewLines) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            Write-Host ($Indent + $line) -ForegroundColor DarkGray
        }
    }
}

# ============= AI FUNCTIONS =============
$aiSessionId = $null

function Start-AISession {
    param([string]$SessionId = (New-Guid).ToString())
    
    Write-Host "`n[START] Starting AI Session..." -ForegroundColor Yellow
    $script:aiSessionId = $SessionId
    Write-Host "[OK] AI Session started (ID: $($SessionId.Substring(0,8))...)" -ForegroundColor Green
    return $SessionId
}

function Get-OllamaModel {
    try {
        $models = Invoke-RestMethod -Uri "$($config.OllamaUrl)/api/tags" -TimeoutSec 5 -ErrorAction Stop
        $availableModels = @($models.models | ForEach-Object { $_.name })

        if ($availableModels.Count -eq 0) { return $null }

        if ($availableModels -notcontains $config.AIModel) {
            $config.AIModel = $availableModels[0]
        }

        return $config.AIModel
    }
    catch {
        return $null
    }
}

function Invoke-OllamaArbiter {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Question,

        [object[]]$MemoryRows = @(),

        [string]$QueryType = "general"
    )

    $model = Get-OllamaModel
    if (-not $model) { return $null }

    $memoryText = if ($MemoryRows.Count -gt 0) {
        Format-MemoryRows -Rows $MemoryRows
    } else {
        "No relevant memory found in the system."
    }

    $prompt = @"
You are Mira, the reasoning layer for PCDE/MiraTV.

Answer the user's question using the retrieved memory if available.
If no memory matches, answer based on general knowledge but clearly state that.

USER QUESTION:
$Question

QUERY TYPE:
$QueryType

RETRIEVED MEMORY:
$memoryText

Answer directly and concisely.
"@

    $body = @{
        model = $model
        prompt = $prompt
        stream = $false
        options = @{
            temperature = 0.3
            num_predict = 500
        }
    } | ConvertTo-Json -Depth 8

    try {
        $response = Invoke-RestMethod -Uri "$($config.OllamaUrl)/api/generate" `
            -Method Post `
            -Body $body `
            -ContentType "application/json" `
            -TimeoutSec 60

        $answer = [string]$response.response
        return @{
            answer = $answer
            model = $model
            has_memory = ($MemoryRows.Count -gt 0)
        }
    }
    catch {
        Write-DebugLog -Category "OLLAMA" -Message "Failed: $($_.Exception.Message)"
        return $null
    }
}

function Ask-AI {
    param([string]$Question)

    if ([string]::IsNullOrWhiteSpace($Question)) {
        return @{ answer = "Please ask a question."; source = "error" }
    }

    if (-not (Test-BgcRule -RuleCode "COST_001")) {
        Write-Host "[BGC] COST_001 disabled   blocking AI request" -ForegroundColor Yellow
        return @{
            answer = "BGC governance blocked this AI request because rule COST_001 is currently disabled."
            source = "bgc"
            confidence = 1.0
        }
    }

    if (-not $script:aiSessionId) {
        Start-AISession | Out-Null
    }

    Write-Host "`n? Asking AI: $Question" -ForegroundColor Cyan
    Write-Host "[SEARCH] Extracting keywords and searching memory..." -ForegroundColor Yellow

    $keywords = @(Get-Keywords -Text $Question)
if ($keywords.Count -eq 0 -or $null -eq $keywords) {
    Write-Host "   [WARN] No keywords extracted, using full question" -ForegroundColor Yellow
    $keywords = @((Get-PCDENormalizedQuestion -Question $Question))
}else {
        Write-Host "   ? Keywords: $($keywords -join ', ')" -ForegroundColor Green
    }

    $reasoningRules = Import-PCDEReasoningRules
    if (-not $reasoningRules) {
        Write-Host "   [WARN] No reasoning rules found, using defaults" -ForegroundColor Yellow
        $reasoningRules = [PSCustomObject]@{
            system = [PSCustomObject]@{ default_query_type = 'general' }
            memory_types = @{
                procedural = [PSCustomObject]@{ label = 'Procedural Memory' }
                declarative = [PSCustomObject]@{ label = 'Declarative Memory' }
                associative = [PSCustomObject]@{ label = 'Associative Memory' }
                working = [PSCustomObject]@{ label = 'Working Memory' }
                ai_memory = [PSCustomObject]@{ label = 'AI Learning Memory' }
            }
        }
    }

    $routingPlan = Get-PCDERoutingPlan -Question $Question -Rules $reasoningRules
    Write-Host "   ? Query Type: $($routingPlan.QueryType)" -ForegroundColor Yellow

    $allRows = @()
    foreach ($memoryType in @($routingPlan.PreferredOrder)) {
        $label = Convert-PCDEMemoryNameToLabel -MemoryName $memoryType -Rules $reasoningRules
        Write-Host "   [SEARCH] Searching $label..." -ForegroundColor Cyan

        try {
            $rows = Invoke-PCDEMemorySearchByType `
                -MemoryType $memoryType `
                -Question $Question `
                -Keywords $keywords `
                -SessionId $script:aiSessionId `
                -Rules $reasoningRules

            if ($rows -and @($rows).Count -gt 0) {
                $rowCount = @($rows).Count
                Write-Host "   [OK] Found in $label ($rowCount rows)" -ForegroundColor Green
                Show-MemoryRowsPreview -Rows $rows -Kind $memoryType
                $allRows += $rows
            } else {
                Write-Host "   [NONE] No results in $label" -ForegroundColor DarkGray
            }
        }
        catch {
            Write-Host "   [ERR] $label search failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    Write-Host "[OLLAMA] Generating response..." -ForegroundColor Yellow
    $result = Invoke-OllamaArbiter -Question $Question -MemoryRows $allRows -QueryType $routingPlan.QueryType

    if ($result -and $result.answer) {
        $escapedQuestion = $Question -replace "'", "''"
        $escapedAnswer = $result.answer -replace "'", "''"
        $qId = "q_$(Get-Random -Maximum 9999)"
        $aId = "a_$(Get-Random -Maximum 9999)"

        Invoke-SilentSqlNonQuery -Sql @"
INSERT INTO pcde_working_memory (session_id, slot_key, slot_value)
VALUES ('$script:aiSessionId', '$qId', '$escapedQuestion'),
       ('$script:aiSessionId', '$aId', '$escapedAnswer')
"@ | Out-Null

        return @{
            answer = $result.answer
            source = if ($result.has_memory) { "ollama+memory" } else { "ollama" }
            confidence = 0.8
            query_type = $routingPlan.QueryType
        }
    }

    if ($allRows.Count -gt 0) {
        $formattedAnswer = Format-MemoryRows -Rows $allRows
        return @{
            answer = $formattedAnswer
            source = "memory_fallback"
            confidence = 0.7
            query_type = $routingPlan.QueryType
        }
    }

    return @{
        answer = "I'm Mira, your AI assistant. I couldn't find relevant information in the system memory, and the AI service was unavailable. Please try again later."
        source = "fallback"
        confidence = 0.5
        query_type = $routingPlan.QueryType
    }
}

# ============= UI FUNCTIONS =============
function Show-Header {
    Clear-Host
    Write-Host "#==========================================================#" -ForegroundColor Cyan
    Write-Host "|              CSA-PCDE - Patents Pending                  !" -ForegroundColor Cyan
    Write-Host "|                MASTER CONTROL CONSOLE                    !" -ForegroundColor Cyan
    Write-Host "|             Cognitive Substrate Architecture             !" -ForegroundColor Cyan
    Write-Host "|      Persistent Cognitive Development Environment        !" -ForegroundColor Cyan
    Write-Host "|                     Command Center                       !" -ForegroundColor Cyan
    Write-Host "#==========================================================#" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Status {
    Write-Host "[STATUS] SYSTEM STATUS" -ForegroundColor Yellow
    Write-Host "================"
    
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
    
    try {
        $ollamaTest = Invoke-RestMethod -Uri "$($config.OllamaUrl)/api/tags" -TimeoutSec 5 -ErrorAction SilentlyContinue
        if ($ollamaTest.models) {
            $modelNames = $ollamaTest.models | ForEach-Object { $_.name }
            Write-Host "[OK] Ollama: Connected (Models: $($modelNames -join ', '))" -ForegroundColor Green
        }
    } catch {
        Write-Host "[WARN] Ollama: Not connected (local AI unavailable)" -ForegroundColor Yellow
    }
    
    $jobs = Get-Job
    
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
    
    Write-Host "ACTIVE SERVICES" -ForegroundColor Yellow
    
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
    
    if ($aiSessionId) {
        Write-Host ""
        Write-Host "? Active AI Session: $($aiSessionId.Substring(0,8))..." -ForegroundColor Cyan
    }
}

function Show-Menu {
    Write-Host ""
    Write-Host " COMMANDS" -ForegroundColor Magenta
    Write-Host "==========="
    Write-Host ""
    Write-Host "  SERVICE CONTROL:" -ForegroundColor White
    Write-Host "    1 Start All Services" 
    Write-Host "    2 Stop All Services"
    Write-Host "    3 Show Service Status"
    Write-Host ""
    Write-Host "  CORE SERVICES:" -ForegroundColor White
    Write-Host "    4 Start Spine Scheduler"
    Write-Host "    5 Start CVI Watcher"
    Write-Host "    6 Start Telemetry Watcher"
    Write-Host "    7 Start Spool Uploader"
    Write-Host "    8 Start AI Learning Loop"
    Write-Host ""
    Write-Host "  LEARNING LOOP SERVICES:" -ForegroundColor White
    Write-Host "    9 Start Learning Loop"
    Write-Host "   10 Start Accessory Loop"
    Write-Host "   11 Start Runner Loop"
    Write-Host ""
    Write-Host "  AI COMMANDS:" -ForegroundColor White
    Write-Host "   12 Show AI Learnings"
    Write-Host "   13 Show Working Memory"
    Write-Host "   14 Run Governance Learner Now"
    Write-Host ""
    Write-Host "  [OLLAMA] GENERATIVE AI:" -ForegroundColor Magenta
    Write-Host "   20 Start AI Chat Session (Interactive)"
    Write-Host "   21 Ask AI a Question (Single)"
    Write-Host "   22 Show Chat History"
    Write-Host "   23 Clear Chat Session"
    Write-Host "   24 Show Complete Memory Statistics"
    Write-Host ""
    Write-Host "  DATABASE:" -ForegroundColor White
    Write-Host "   15 Run Custom SQL"
    Write-Host "   16 Export AI Memory"
    Write-Host ""
    Write-Host "  ADDITIONAL PROCESSES:" -ForegroundColor White
    Write-Host "   17 Start Mastery Accessory Loop"
    Write-Host "   18 Start Main Series Loop"
    Write-Host "   19 Start Master Upload Loop"
    Write-Host "   25 Run Relationship Finder"
    Write-Host ""
    Write-Host "  99 Exit"
    Write-Host ""
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

function Show-AILearnings {
    try {
        $result = Invoke-SqlQueryObjects -Sql @"
SELECT memory_id, agent_name, memory_type, LEFT(key_data,100) as preview, confidence, created_at 
FROM pcde_ai_memory 
ORDER BY confidence DESC, memory_id DESC 
LIMIT 10
"@

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
        $result = Invoke-SqlQueryObjects -Sql @"
SELECT slot_key, slot_value, created_at, expires_at 
FROM pcde_working_memory 
WHERE expires_at > NOW() 
ORDER BY created_at DESC
"@

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

function Show-ChatHistory {
    if (-not $script:aiSessionId) {
        Write-Host "No active session" -ForegroundColor Yellow
        return
    }

    $history = Invoke-SqlQueryObjects -Sql @"
SELECT slot_key, slot_value, created_at
FROM pcde_working_memory
WHERE session_id = '$script:aiSessionId'
  AND (slot_key LIKE 'q_%' OR slot_key LIKE 'a_%')
ORDER BY created_at
"@

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
        @{ Name = "pcde_ai_memory"; Display = "AI Learning Memory" }
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

# ============= MAIN LOOP =============
do {
    Show-Header
    Show-Status
    Show-Menu
    
    $choice = Read-Host "Enter command"
    
    switch ($choice) {
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
        "12" { Show-AILearnings; Read-Host "Press Enter to continue" }
        "13" { Show-WorkingMemory; Read-Host "Press Enter to continue" }
        "14" { 
            & "C:\miratv_ingest\workers\GovernanceLearner.ps1"
            Read-Host "Press Enter to continue"
        }
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
        "25" {
            if (Test-Path "C:\miratv_ingest\Find-FileRelationships.ps1") {
                & "C:\miratv_ingest\Find-FileRelationships.ps1"
                Write-Host "[OK] Relationship Finder executed" -ForegroundColor Green
            } else {
                Write-Host "[WARN] Relationship Finder script not found" -ForegroundColor Yellow
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