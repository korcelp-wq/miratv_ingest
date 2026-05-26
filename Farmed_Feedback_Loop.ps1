#!/usr/bin/env pwsh
param(
    [string]$QueryScript = "C:\miratv_ingest\dashboard\Query.ps1",
    [int]$LookbackHours = 24,
    [int]$MaxWorkingQueries = 25,
    [int]$MaxRowsPerTarget = 5,
    [int]$MaxDerivedQueriesPerSeed = 5,
    [int]$MinimumTermLength = 3,
    [switch]$IncludePcdeMemory,
    [switch]$WriteBoosts,
    [switch]$WriteWorkingRefresh,
    [switch]$VerboseLoop
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info {
    param([string]$Message, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    Write-Host $Message -ForegroundColor $Color
}

function Escape-SqlLike {
    param([string]$Value)
    if ($null -eq $Value) { return "" }

    $escaped = $Value.Replace("\", "\\")
    $escaped = $escaped.Replace("'", "''")
    $escaped = $escaped.Replace("%", "\%")
    $escaped = $escaped.Replace("_", "\_")
    return $escaped
}

function Escape-SqlString {
    param([string]$Value)
    if ($null -eq $Value) { return "" }
    return ($Value -replace "'", "''")
}

function Invoke-QueryRows {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sql,

        [string]$DatabaseName = "pcde_memory"
    )

    try {
        $rows = & $QueryScript -Db $DatabaseName -Sql $Sql 2>$null
        if ($null -eq $rows) { return @() }
        return @($rows)
    }
    catch {
        Write-Info ("   ERROR: {0}" -f $_.Exception.Message) Red
        return @()
    }
}

function Invoke-NonQuery {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sql,

        [string]$DatabaseName = "pcde_memory"
    )

    try {
        [void](& $QueryScript -Db $DatabaseName -Sql $Sql 2>$null)
        return $true
    }
    catch {
        Write-Info ("   ERROR write failed: {0}" -f $_.Exception.Message) Red
        return $false
    }
}

function Get-RecentWorkingQuerySeeds {
    $sql = @"
SELECT
    slot_key,
    slot_value,
    created_at
FROM pcde_working_memory
WHERE slot_key LIKE 'q_%'
  AND created_at >= DATE_SUB(NOW(), INTERVAL $LookbackHours HOUR)
ORDER BY created_at DESC
LIMIT $MaxWorkingQueries;
"@

    return Invoke-QueryRows -Sql $sql -DatabaseName "pcde_memory"
}

function Get-Keywords {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $stopWords = @(
        'who','what','where','when','why','how','which','whose',
        'is','are','was','were','be','been','being',
        'do','does','did','done','doing',
        'can','could','will','would','shall','should','may','might','must',
        'the','a','an','and','or','but','if','then','else','when',
        'this','that','these','those','with','from','into','about',
        'for','too','very','just','now'
    )

    $words = $Text -split '\s+' | ForEach-Object {
        $_.Trim("?.,!;:()[]{}\"'").ToLowerInvariant()
    }

    return @(
        $words |
        Where-Object { $_.Length -ge $MinimumTermLength -and $stopWords -notcontains $_ } |
        Select-Object -Unique
    )
}

function Test-IsAcronymLike {
    param([string]$Question)

    if ([string]::IsNullOrWhiteSpace($Question)) { return $false }
    $q = $Question.Trim()
    return (
        $q -match '^[A-Za-z]{2,8}\??$' -or
        $q -match '^what is [A-Za-z]{2,8}\??$' -or
        $q -match '^what does [A-Za-z]{2,8} stand for\??$'
    )
}

function Get-AcronymToken {
    param([string]$Question)

    if ([string]::IsNullOrWhiteSpace($Question)) { return $null }
    $q = $Question.Trim().ToLowerInvariant()

    if ($q -match '^[a-z]{2,8}\??$') {
        return ($q -replace '\?', '').ToUpperInvariant()
    }

    if ($q -match '^what is ([a-z]{2,8})\??$') {
        return $matches[1].ToUpperInvariant()
    }

    if ($q -match '^what does ([a-z]{2,8}) stand for\??$') {
        return $matches[1].ToUpperInvariant()
    }

    return $null
}

function Get-DerivedQueriesFromSeed {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SeedQuery
    )

    $derived = New-Object System.Collections.Generic.List[string]
    $keywords = @(Get-Keywords -Text $SeedQuery)

    if (Test-IsAcronymLike -Question $SeedQuery) {
        $token = Get-AcronymToken -Question $SeedQuery
        if (-not [string]::IsNullOrWhiteSpace($token)) {
            $derived.Add($token) | Out-Null
            $derived.Add("$token definition") | Out-Null
            $derived.Add("what is $token") | Out-Null
            $derived.Add("$token architecture") | Out-Null
            $derived.Add("$token procedure") | Out-Null
        }
    }

    foreach ($kw in $keywords | Select-Object -First 3) {
        $derived.Add($kw) | Out-Null
    }

    if ($keywords.Count -ge 2) {
        $derived.Add(($keywords | Select-Object -First 2) -join ' ') | Out-Null
    }

    return @(
        $derived |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique |
        Select-Object -First $MaxDerivedQueriesPerSeed
    )
}

$script:SearchTargets = @(
    [pscustomobject]@{
        Name = "Lake Knowledge - extracted_docs"
        Database = "xpdgxfsp_lake_knowledge"
        Table = "extracted_docs"
        IdColumn = "id"
        PreviewExpression = "LEFT(CONCAT_WS(' | ', COALESCE(title,''), COALESCE(source_ref,''), COALESCE(content,'')), 220)"
        PreviewAlias = "preview"
        WhereClause = "(content LIKE '%{0}%' ESCAPE '\\' OR title LIKE '%{0}%' ESCAPE '\\' OR source_ref LIKE '%{0}%' ESCAPE '\\')"
        SourceKind = "doc"
    },
    [pscustomobject]@{
        Name = "Lake Knowledge - knowledge_units"
        Database = "xpdgxfsp_lake_knowledge"
        Table = "knowledge_units"
        IdColumn = "id"
        PreviewExpression = "LEFT(CONCAT_WS(' | ', COALESCE(title,''), COALESCE(summary,''), COALESCE(unit_text,'')), 220)"
        PreviewAlias = "preview"
        WhereClause = "(title LIKE '%{0}%' ESCAPE '\\' OR summary LIKE '%{0}%' ESCAPE '\\' OR unit_text LIKE '%{0}%' ESCAPE '\\')"
        SourceKind = "unit"
    },
    [pscustomobject]@{
        Name = "Lake Knowledge - doc_sections"
        Database = "xpdgxfsp_lake_knowledge"
        Table = "doc_sections"
        IdColumn = "id"
        PreviewExpression = "LEFT(CONCAT_WS(' | ', COALESCE(title,''), COALESCE(content,'')), 220)"
        PreviewAlias = "preview"
        WhereClause = "(content LIKE '%{0}%' ESCAPE '\\' OR title LIKE '%{0}%' ESCAPE '\\')"
        SourceKind = "section"
    },
    [pscustomobject]@{
        Name = "Lake Vector - ai_memory_index"
        Database = "xpdgxfsp_lake_vector"
        Table = "ai_memory_index"
        IdColumn = "memory_id"
        PreviewExpression = "LEFT(CONCAT_WS(' | ', COALESCE(memory_key,''), COALESCE(memory_type,''), COALESCE(content_summary,'')), 220)"
        PreviewAlias = "preview"
        WhereClause = "(memory_key LIKE '%{0}%' ESCAPE '\\' OR memory_type LIKE '%{0}%' ESCAPE '\\' OR content_summary LIKE '%{0}%' ESCAPE '\\')"
        SourceKind = "memory_index"
    },
    [pscustomobject]@{
        Name = "Lake Vector - cvi_carousel"
        Database = "xpdgxfsp_lake_vector"
        Table = "cvi_carousel"
        IdColumn = "id"
        PreviewExpression = "LEFT(CONCAT_WS(' | ', COALESCE(component,''), COALESCE(payload_type,''), COALESCE(payload,'')), 220)"
        PreviewAlias = "preview"
        WhereClause = "(payload LIKE '%{0}%' ESCAPE '\\' OR component LIKE '%{0}%' ESCAPE '\\' OR payload_type LIKE '%{0}%' ESCAPE '\\')"
        SourceKind = "carousel"
    }
)

if ($IncludePcdeMemory) {
    $script:SearchTargets += @(
        [pscustomobject]@{
            Name = "PCDE Memory - declarative"
            Database = "xpdgxfsp_pcde_memory"
            Table = "pcde_declarative_memory"
            IdColumn = "fact_id"
            PreviewExpression = "LEFT(CONCAT_WS(' | ', COALESCE(predicate,''), COALESCE(object_value,''), COALESCE(domain,'')), 220)"
            PreviewAlias = "preview"
            WhereClause = "(predicate LIKE '%{0}%' ESCAPE '\\' OR object_value LIKE '%{0}%' ESCAPE '\\' OR domain LIKE '%{0}%' ESCAPE '\\')"
            SourceKind = "declarative"
        },
        [pscustomobject]@{
            Name = "PCDE Memory - procedural"
            Database = "xpdgxfsp_pcde_memory"
            Table = "pcde_procedure_registry"
            IdColumn = "procedure_id"
            PreviewExpression = "LEFT(CONCAT_WS(' | ', COALESCE(procedure_name,''), COALESCE(description,''), COALESCE(domain,'')), 220)"
            PreviewAlias = "preview"
            WhereClause = "(procedure_name LIKE '%{0}%' ESCAPE '\\' OR description LIKE '%{0}%' ESCAPE '\\' OR domain LIKE '%{0}%' ESCAPE '\\')"
            SourceKind = "procedural"
        }
    )
}

function Search-LongTermTarget {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SearchTerm,

        [Parameter(Mandatory = $true)]
        [object]$Target
    )

    $escaped = Escape-SqlLike -Value $SearchTerm
    $where = [string]::Format($Target.WhereClause, $escaped)

    $sql = @"
SELECT
    $($Target.IdColumn) AS record_id,
    $($Target.PreviewExpression) AS $($Target.PreviewAlias)
FROM $($Target.Database).$($Target.Table)
WHERE $where
LIMIT $MaxRowsPerTarget;
"@

    $rows = Invoke-QueryRows -Sql $sql -DatabaseName "pcde_memory"
    foreach ($row in @($rows)) {
        try {
            Add-Member -InputObject $row -NotePropertyName db_name -NotePropertyValue $Target.Database -Force
            Add-Member -InputObject $row -NotePropertyName table_name -NotePropertyValue $Target.Table -Force
            Add-Member -InputObject $row -NotePropertyName source_kind -NotePropertyValue $Target.SourceKind -Force
            Add-Member -InputObject $row -NotePropertyName search_term -NotePropertyValue $SearchTerm -Force
        }
        catch { }
    }

    return @($rows)
}

function Get-DefinitionBiasScore {
    param(
        [string]$SeedQuery,
        [string]$PreviewText,
        [string]$SourceKind
    )

    $score = 0
    $preview = if ($null -eq $PreviewText) { "" } else { $PreviewText.ToLowerInvariant() }

    if (Test-IsAcronymLike -Question $SeedQuery) {
        if ($SourceKind -eq 'declarative') { $score += 40 }
        if ($preview -match 'definition|stands for|means|acronym|canonical') { $score += 30 }
        if ($preview -match 'procedure|implement|how to') { $score -= 15 }
    }

    return $score
}

function Get-ResultScore {
    param(
        [string]$SeedQuery,
        [string]$DerivedQuery,
        [object]$Row
    )

    $preview = ""
    if ($null -ne $Row.PSObject.Properties['preview']) {
        $preview = [string]$Row.preview
    }

    $score = 0
    $score += [Math]::Min(30, ($DerivedQuery.Length))
    $score += Get-DefinitionBiasScore -SeedQuery $SeedQuery -PreviewText $preview -SourceKind ([string]$Row.source_kind)

    if ($preview.ToLowerInvariant() -like "*$($DerivedQuery.ToLowerInvariant())*") {
        $score += 15
    }

    switch ([string]$Row.source_kind) {
        'declarative' { $score += 25 }
        'unit'        { $score += 15 }
        'doc'         { $score += 12 }
        'section'     { $score += 10 }
        'procedural'  { $score += 6 }
        default       { $score += 4 }
    }

    return $score
}

function Select-BestLongTermMatches {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SeedQuery,

        [Parameter(Mandatory = $true)]
        [object[]]$Rows
    )

    $seen = @{}
    $ranked = foreach ($row in @($Rows)) {
        $preview = if ($row.PSObject.Properties['preview']) { [string]$row.preview } else { "" }
        $key = "{0}|{1}|{2}" -f $row.db_name, $row.table_name, $preview
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true

        [pscustomobject]@{
            score = Get-ResultScore -SeedQuery $SeedQuery -DerivedQuery ([string]$row.search_term) -Row $row
            db_name = [string]$row.db_name
            table_name = [string]$row.table_name
            source_kind = [string]$row.source_kind
            record_id = [string]$row.record_id
            preview = $preview
            search_term = [string]$row.search_term
        }
    }

    return @($ranked | Sort-Object score -Descending | Select-Object -First 8)
}

function Write-LearnedBoost {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SeedQuery,

        [Parameter(Mandatory = $true)]
        [object[]]$RankedRows
    )

    foreach ($row in @($RankedRows)) {
        $payload = @{
            seed_query = $SeedQuery
            source_db = $row.db_name
            source_table = $row.table_name
            source_kind = $row.source_kind
            record_id = $row.record_id
            search_term = $row.search_term
            preview = $row.preview
            score = $row.score
            reinforcement_type = "priority_boost"
            origin = "Farmed_Feedback_Loop"
        } | ConvertTo-Json -Depth 6 -Compress

        $escapedPayload = Escape-SqlString -Value $payload

        $sql = @"
INSERT INTO pcde_ai_memory
(agent_name, memory_type, key_data, confidence, access_count)
VALUES
('FarmedFeedback', 'learned_boost', '$escapedPayload', 0.80, 1);
"@

        [void](Invoke-NonQuery -Sql $sql -DatabaseName "pcde_memory")
    }
}

function Write-WorkingRefreshEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SeedQuery,

        [Parameter(Mandatory = $true)]
        [object[]]$RankedRows
    )

    if (-not $RankedRows -or $RankedRows.Count -eq 0) { return }

    $summaryLines = @()
    foreach ($row in @($RankedRows | Select-Object -First 3)) {
        $summaryLines += ("[{0}] {1}" -f $row.source_kind, $row.preview)
    }

    $slotKey = "ff_" + ([guid]::NewGuid().ToString("N").Substring(0,10))
    $slotValue = @{
        seed_query = $SeedQuery
        reinforcement_type = "long_term_refresh"
        top_matches = $summaryLines
        generated_by = "Farmed_Feedback_Loop"
    } | ConvertTo-Json -Depth 6 -Compress

    $escapedSlotKey = Escape-SqlString -Value $slotKey
    $escapedSlotValue = Escape-SqlString -Value $slotValue

    $sql = @"
INSERT INTO pcde_working_memory
(session_id, slot_key, slot_value)
VALUES
('farmed_feedback', '$escapedSlotKey', '$escapedSlotValue');
"@

    [void](Invoke-NonQuery -Sql $sql -DatabaseName "pcde_memory")
}

function Show-RankedResults {
    param(
        [string]$SeedQuery,
        [object[]]$Rows
    )

    Write-Info ("SEED: {0}" -f $SeedQuery) Cyan
    if (-not $Rows -or $Rows.Count -eq 0) {
        Write-Info "   No long-term reinforcements found." DarkGray
        return
    }

    foreach ($row in @($Rows | Select-Object -First 5)) {
        $preview = $row.preview
        if ($preview.Length -gt 180) {
            $preview = $preview.Substring(0,180) + "..."
        }

        Write-Info ("   [{0}] score={1} {2}.{3} -> {4}" -f `
            $row.source_kind, $row.score, $row.db_name, $row.table_name, $preview) Gray
    }
}

if (-not (Test-Path $QueryScript)) {
    throw "Query.ps1 not found: $QueryScript"
}

Write-Info ""
Write-Info "FARMED FEEDBACK LOOP" Cyan
Write-Info "====================" Cyan
Write-Info ("LookbackHours      : {0}" -f $LookbackHours) DarkGray
Write-Info ("MaxWorkingQueries  : {0}" -f $MaxWorkingQueries) DarkGray
Write-Info ("MaxRowsPerTarget   : {0}" -f $MaxRowsPerTarget) DarkGray
Write-Info ("IncludePcdeMemory  : {0}" -f $IncludePcdeMemory.IsPresent) DarkGray
Write-Info ("WriteBoosts        : {0}" -f $WriteBoosts.IsPresent) DarkGray
Write-Info ("WriteWorkingRefresh: {0}" -f $WriteWorkingRefresh.IsPresent) DarkGray
Write-Info ""

$seeds = @(Get-RecentWorkingQuerySeeds)
if ($seeds.Count -eq 0) {
    Write-Info "No working-memory query seeds found." Yellow
    exit 0
}

$totalBoostCandidates = 0

foreach ($seed in $seeds) {
    $seedQuery = [string]$seed.slot_value
    if ([string]::IsNullOrWhiteSpace($seedQuery)) { continue }

    if ($VerboseLoop) {
        Write-Info ("Processing seed: {0}" -f $seedQuery) Yellow
    }

    $derivedQueries = @(Get-DerivedQueriesFromSeed -SeedQuery $seedQuery)
    $allRows = @()

    foreach ($dq in $derivedQueries) {
        foreach ($target in $script:SearchTargets) {
            $rows = @(Search-LongTermTarget -SearchTerm $dq -Target $target)
            if ($rows.Count -gt 0) {
                $allRows += $rows
            }
        }
    }

    $ranked = @(Select-BestLongTermMatches -SeedQuery $seedQuery -Rows $allRows)
    $totalBoostCandidates += $ranked.Count

    Show-RankedResults -SeedQuery $seedQuery -Rows $ranked

    if ($WriteBoosts -and $ranked.Count -gt 0) {
        Write-LearnedBoost -SeedQuery $seedQuery -RankedRows $ranked
    }

    if ($WriteWorkingRefresh -and $ranked.Count -gt 0) {
        Write-WorkingRefreshEntry -SeedQuery $seedQuery -RankedRows $ranked
    }

    Write-Info ""
}

Write-Info ("Done. Total ranked reinforcement candidates: {0}" -f $totalBoostCandidates) Green
