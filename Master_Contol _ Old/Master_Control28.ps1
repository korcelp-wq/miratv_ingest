# ============================================================
# PCDE MASTER CONTROL (CLEAN BUILD WITH PASS-1)
# ============================================================

$QueryScript = "C:\miratv_ingest\Query.ps1"
$OllamaUrl   = "http://localhost:11434/api/generate"
$OllamaModel = "mistral:latest"

# ============================================================
# SIMPLE KEYWORD EXTRACTION
# ============================================================

function Get-SearchKeywords {
    param([string]$Text)

    if (-not $Text) { return @() }

    return ($Text.ToLower() -split "\W+") |
        Where-Object { $_.Length -gt 2 } |
        Select-Object -Unique
}

# ============================================================
# MEMORY SEARCH (BASIC)
# ============================================================

function Search-DeclarativeMemory {
    param([string[]]$Keywords)

    $like = ($Keywords | ForEach-Object { "predicate LIKE '%$_%' OR object_value LIKE '%$_%'" }) -join " OR "

    $sql = @"
SELECT fact_id, predicate, object_value
FROM pcde_declarative_memory
WHERE $like
LIMIT 5;
"@

    return & $QueryScript -Sql $sql 2>$null
}

function Search-ProceduralMemory {
    param([string[]]$Keywords)

    $like = ($Keywords | ForEach-Object { "description LIKE '%$_%'" }) -join " OR "

    $sql = @"
SELECT procedure_id, procedure_name, description
FROM pcde_procedure_registry
WHERE $like
LIMIT 5;
"@

    return & $QueryScript -Sql $sql 2>$null
}

function Search-AssociativeMemory {
    param([string[]]$Keywords)

    $like = ($Keywords | ForEach-Object { "notes LIKE '%$_%'" }) -join " OR "

    $sql = @"
SELECT relation_id, relation_type, relation_target, notes
FROM pcde_procedure_relations
WHERE $like
LIMIT 5;
"@

    return & $QueryScript -Sql $sql 2>$null
}

# ============================================================
# PASS 1 - OLLAMA DECISION
# ============================================================

function Invoke-PCDEPass1Decision {
    param(
        [string]$UserQuestion,
        [object[]]$CandidateResults
    )

    $candidatePreview = @()

    foreach ($c in $CandidateResults) {
        $text = ""

        if ($c.rows -and $c.rows.Count -gt 0) {
            $row = $c.rows[0]
            $text = ($row | Out-String)
        }

        if ($text.Length -gt 200) {
            $text = $text.Substring(0,200)
        }

        $candidatePreview += @{
            memory_type = $c.memory_type
            preview = $text
        }
    }

    $systemPrompt = @"
You are inside PCDE.

DO NOT answer.

Decide only:

{
  "sufficient": true or false,
  "needs_long_term_recall": true or false,
  "confidence": 0.0 to 1.0,
  "recall_terms": ["term"]
}
"@

    $payload = @{
        question = $UserQuestion
        candidates = $candidatePreview
    } | ConvertTo-Json -Depth 5

    $request = @{
        model = $OllamaModel
        prompt = $payload
        system = $systemPrompt
        stream = $false
    } | ConvertTo-Json -Depth 5

    try {
        $response = Invoke-RestMethod -Uri $OllamaUrl `
            -Method Post `
            -Body $request `
            -ContentType "application/json"

        if ($response.response -match '\{.*\}') {
            return ($matches[0] | ConvertFrom-Json)
        }
    }
    catch {}

    return @{
        sufficient = $false
        needs_long_term_recall = $true
        confidence = 0.0
        recall_terms = @($UserQuestion)
    }
}

# ============================================================
# LONG TERM RECALL
# ============================================================

function Invoke-LongTermRecall {
    param([string]$Term)

    $sql = "CALL pcde_long_term_memory_recall('$Term');"

    try {
        return & $QueryScript -Sql $sql 2>$null
    }
    catch {
        return $null
    }
}

# ============================================================
# MAIN AI FLOW
# ============================================================

function Ask-PCDE {
    param([string]$Question)

    Write-Host ""
    Write-Host "🤔 Question: $Question" -ForegroundColor Cyan

    $keywords = Get-SearchKeywords $Question

    Write-Host "🔑 Keywords: $($keywords -join ', ')" -ForegroundColor DarkYellow

    $candidates = @()

    $decl = Search-DeclarativeMemory $keywords
    if ($decl) {
        Write-Host "📚 Declarative found" -ForegroundColor Green
        $candidates += @{ memory_type="declarative"; rows=$decl }
    }

    $proc = Search-ProceduralMemory $keywords
    if ($proc) {
        Write-Host "📋 Procedural found" -ForegroundColor Green
        $candidates += @{ memory_type="procedural"; rows=$proc }
    }

    $assoc = Search-AssociativeMemory $keywords
    if ($assoc) {
        Write-Host "🔗 Associative found" -ForegroundColor Green
        $candidates += @{ memory_type="associative"; rows=$assoc }
    }

    # -------------------------------
    # PASS 1
    # -------------------------------
    $pass1 = Invoke-PCDEPass1Decision $Question $candidates

    Write-Host "🧠 Pass1 → recall=$($pass1.needs_long_term_recall)" -ForegroundColor Cyan

    if ($pass1.needs_long_term_recall -eq $true) {

        $term = ($pass1.recall_terms -join " ")

        Write-Host "🔁 Long-term recall: $term" -ForegroundColor Yellow

        $lt = Invoke-LongTermRecall $term

        if ($lt) {
            Write-Host "✅ Long-term memory added" -ForegroundColor Green
            $candidates += @{ memory_type="long_term"; rows=$lt }
        }
    }

    # -------------------------------
    # FINAL ANSWER (simple for now)
    # -------------------------------
    Write-Host ""
    Write-Host "🤖 Final Answer (placeholder)" -ForegroundColor White
    Write-Host "Use Pass-2 here next." -ForegroundColor DarkGray
}

# ============================================================
# INTERACTIVE LOOP
# ============================================================

while ($true) {
    $q = Read-Host "You"
    if ($q -eq "/exit") { break }
    Ask-PCDE $q
}