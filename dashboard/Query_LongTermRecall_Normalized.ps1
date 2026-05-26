#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory = $true)]
    [string]$SearchTerm,

    [string]$QueryType = "",

    [int]$Limit = 8,

    [string]$Database = "xpdgxfsp_pcde_memory",

    [string]$ProcedureName = "pcde_long_term_memory_recall",

    [string]$Endpoint = "https://miratv.club/_workers/api/series/dog_open_proc.php",

    [switch]$RawJson,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"

function Write-Info {
    param([string]$Message, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    if (-not $Quiet) {
        Write-Host $Message -ForegroundColor $Color
    }
}

function Escape-SqlLiteral {
    param([string]$Value)
    if ($null -eq $Value) { return "" }
    return ($Value -replace "'", "''")
}

function Get-Keywords {
    param([string]$Question)

    if ([string]::IsNullOrWhiteSpace($Question)) { return @() }

    $stopWords = @(
        'what','is','are','was','were','the','a','an','and','or','but',
        'how','do','does','did','to','for','of','in','on','with',
        'who','when','where','why','which','this','that','these','those',
        'can','could','would','should','will','about','into','from','it'
    )

    $trimChars = @('?','.',',','!',';',':','(',')','[',']','{','}','"',"'",'-','_','/','\')
    $words = $Question -split '\s+' | ForEach-Object {
        $_.Trim($trimChars).ToLowerInvariant()
    }

    return @(
        $words |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and
            $_.Length -gt 2 -and
            $stopWords -notcontains $_
        } |
        Select-Object -Unique
    )
}

function Get-QueryIntent {
    param([string]$Question)

    $result = [ordered]@{
        OriginalQuestion = $Question
        QueryType = "general"
        NormalizedSearchTerm = $Question
        Keywords = @()
    }

    if ([string]::IsNullOrWhiteSpace($Question)) {
        return [pscustomobject]$result
    }

    $q = $Question.Trim()
    $lower = $q.ToLowerInvariant()
    $keywords = @(Get-Keywords -Question $q)
    $result.Keywords = $keywords

    if ($q -match '^[A-Za-z]{2,8}\??$') {
        $result.QueryType = "acronym_definition"
        $result.NormalizedSearchTerm = (($q -replace '\?', '').ToUpperInvariant())
        return [pscustomobject]$result
    }

    if ($lower -match '^what is ([a-z0-9]{2,8})\??$') {
        $result.QueryType = "acronym_definition"
        $result.NormalizedSearchTerm = $matches[1].ToUpperInvariant()
        return [pscustomobject]$result
    }

    if ($lower -match '^what does ([a-z0-9]{2,8}) stand for\??$') {
        $result.QueryType = "acronym_definition"
        $result.NormalizedSearchTerm = $matches[1].ToUpperInvariant()
        return [pscustomobject]$result
    }

    if ($lower -match '^(how do i|how do we|how do you|how to)\b') {
        $result.QueryType = "procedural"
        if ($keywords.Count -gt 0) {
            $result.NormalizedSearchTerm = ($keywords -join ' ')
        }
        return [pscustomobject]$result
    }

    if ($lower -match '^(what is|define|meaning of)\b') {
        $result.QueryType = "definition"
        if ($keywords.Count -gt 0) {
            $result.NormalizedSearchTerm = ($keywords -join ' ')
        }
        return [pscustomobject]$result
    }

    if ($keywords.Count -gt 0) {
        if ($keywords.Count -eq 1) {
            $result.NormalizedSearchTerm = $keywords[0]
        }
        else {
            $result.NormalizedSearchTerm = ($keywords -join ' ')
        }
    }

    return [pscustomobject]$result
}

function Test-RowLikeObject {
    param($Object)

    if ($null -eq $Object) { return $false }
    if ($Object -isnot [psobject]) { return $false }

    $props = @($Object.PSObject.Properties.Name)
    if ($props.Count -eq 0) { return $false }

    $rowHints = @(
        'source_db','source_table','source_column','record_id',
        'memory_domain','evidence_class','exact_hit','core_hit',
        'token_match_count','source_weight','query_type_bonus',
        'relevance_score','preview_text','matched_text',
        'source_name','preview'
    )

    foreach ($hint in $rowHints) {
        if ($props -contains $hint) { return $true }
    }

    return $false
}

function Expand-RowContainer {
    param($InputObject)

    $results = @()

    if ($null -eq $InputObject) { return @() }
    if ($InputObject -is [string]) { return @() }

    if (Test-RowLikeObject -Object $InputObject) {
        return @($InputObject)
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        foreach ($item in $InputObject) {
            $results += @(Expand-RowContainer -InputObject $item)
        }
        return @($results)
    }

    if ($InputObject -is [psobject]) {
        foreach ($propName in @('rows','rowsets','data','result')) {
            if ($InputObject.PSObject.Properties.Name -contains $propName) {
                $results += @(Expand-RowContainer -InputObject $InputObject.$propName)
            }
        }
    }

    return @($results)
}

function Get-UsableRows {
    param($Response)
    if ($null -eq $Response) { return @() }
    return @(Expand-RowContainer -InputObject $Response)
}

$intent = Get-QueryIntent -Question $SearchTerm

$effectiveQueryType = if ([string]::IsNullOrWhiteSpace($QueryType)) { $intent.QueryType } else { $QueryType }
$normalizedSearchTerm = [string]$intent.NormalizedSearchTerm

$escapedSearchTerm = Escape-SqlLiteral -Value $normalizedSearchTerm
$escapedQueryType  = Escape-SqlLiteral -Value $effectiveQueryType

$sql = "CALL $ProcedureName('$escapedSearchTerm', '$escapedQueryType', $Limit);"

$bodyObject = @{
    token  = $token
    db     = $Database
    sql    = $sql
    params = @()
}

$bodyJson = $bodyObject | ConvertTo-Json -Depth 10 -Compress

Write-Info ""
Write-Info "LONG TERM MEMORY RECALL" Cyan
Write-Info "=======================" Cyan
Write-Info "Question: $SearchTerm" DarkGray
Write-Info "Normalized Search: $normalizedSearchTerm" DarkGray
Write-Info "Query Type: $effectiveQueryType" DarkGray
if ($intent.Keywords.Count -gt 0) {
    Write-Info ("Keywords: {0}" -f ($intent.Keywords -join ', ')) DarkGray
}
Write-Info "DB: $Database" DarkGray
Write-Info "PROC: $ProcedureName" DarkGray
Write-Info "SQL: $sql" Yellow
Write-Info ""

try {
    $response = Invoke-RestMethod `
        -Uri $Endpoint `
        -Method Post `
        -Body $bodyJson `
        -ContentType "application/json" `
        -ErrorAction Stop

    if ($RawJson) {
        $response | ConvertTo-Json -Depth 30
        return
    }

    $usableRows = @(Get-UsableRows -Response $response)

    if ($usableRows.Count -gt 0) {
        if (-not $Quiet) {
            Write-Host ("Returned rows: {0}" -f $usableRows.Count) -ForegroundColor Green
            if ($null -ne $response.rowset_count) {
                Write-Host ("Rowsets: {0}" -f $response.rowset_count) -ForegroundColor DarkGray
            }
            Write-Host ""
        }

        foreach ($row in $usableRows) {
            $sourceDb    = if ($row.PSObject.Properties.Name -contains 'source_db') { $row.source_db } else { '' }
            $sourceTable = if ($row.PSObject.Properties.Name -contains 'source_table') { $row.source_table } else { '' }
            $preview     = if ($row.PSObject.Properties.Name -contains 'preview_text') { $row.preview_text } elseif ($row.PSObject.Properties.Name -contains 'preview') { $row.preview } else { '' }
            $score       = if ($row.PSObject.Properties.Name -contains 'relevance_score') { $row.relevance_score } else { '' }
            $domain      = if ($row.PSObject.Properties.Name -contains 'memory_domain') { $row.memory_domain } else { '' }
            $class       = if ($row.PSObject.Properties.Name -contains 'evidence_class') { $row.evidence_class } else { 'unknown' }

            if (-not $Quiet) {
                Write-Host ("[{0}] {1}.{2} score={3} domain={4}" -f $class, $sourceDb, $sourceTable, $score, $domain) -ForegroundColor Cyan
                if (-not [string]::IsNullOrWhiteSpace($preview)) {
                    Write-Host ("   {0}" -f $preview) -ForegroundColor Gray
                }
            }
        }
    }
    else {
        Write-Info "No rows returned." Yellow
        if (-not $Quiet -and $null -ne $response.rowset_count) {
            Write-Host ("Rowsets: {0}" -f $response.rowset_count) -ForegroundColor DarkGray
            Write-Host "Tip: try shorter normalized terms like CVI, telemetry monitor, BGC runtime." -ForegroundColor Yellow
        }
    }

    return $response
}
catch {
    Write-Host ""
    Write-Host "Long-term recall failed." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red

    if ($_.Exception.Response) {
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $responseBody = $reader.ReadToEnd()

            Write-Host ""
            Write-Host "Response body:" -ForegroundColor Yellow
            Write-Host $responseBody
        }
        catch { }
    }

    throw
}
