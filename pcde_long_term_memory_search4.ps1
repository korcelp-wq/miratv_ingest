param(
    [Parameter(Mandatory=$true)]
    [string]$SearchTerm,

    [string]$QueryScript = "C:\miratv_ingest\dashboard\Query.ps1",

    [int]$MaxRowsPerTarget = 5,

    [switch]$IncludePcdeMemory
)

function Escape-SqlLike {
    param([string]$Value)

    if ($null -eq $Value) { return "" }

    $escaped = $Value.Replace("'", "''")
    $escaped = $escaped.Replace("%", "\%")
    $escaped = $escaped.Replace("_", "\_")
    return $escaped
}

function Invoke-QueryScript {
    param([string]$Sql)

    try {
        $rows = & $QueryScript -Sql $Sql 2>$null
        if ($null -eq $rows) { return @() }
        return @($rows)
    }
    catch {
        Write-Host ("   ERROR: " + $_.Exception.Message) -ForegroundColor Red
        return @()
    }
}

function Show-Matches {
    param(
        [object[]]$Rows,
        [string]$PreviewProperty
    )

    foreach ($row in @($Rows)) {
        $preview = ""
        if ($row -and $row.PSObject.Properties[$PreviewProperty]) {
            $preview = [string]$row.$PreviewProperty
        }
        elseif ($row -and $row.PSObject.Properties['preview']) {
            $preview = [string]$row.preview
        }
        else {
            $preview = [string]$row
        }

        if ($preview.Length -gt 220) {
            $preview = $preview.Substring(0,220) + "..."
        }

        $idText = ""
        if ($row -and $row.PSObject.Properties['record_id']) {
            $idText = " [id=" + [string]$row.record_id + "]"
        }

        Write-Host ("      ->" + $idText + " " + $preview) -ForegroundColor Gray
    }
}

$searchTargets = @(
    [pscustomobject]@{ Name = "Lake Knowledge - raw_artifacts.content"; Database = "xpdgxfsp_lake_knowledge"; Table = "raw_artifacts"; IdColumn = "id"; PreviewExpression = "LEFT(content, 220)"; PreviewAlias = "preview"; WhereClause = "content LIKE '%{0}%' ESCAPE '\\'" },
    [pscustomobject]@{ Name = "Lake Knowledge - raw_conversations.content"; Database = "xpdgxfsp_lake_knowledge"; Table = "raw_conversations"; IdColumn = "id"; PreviewExpression = "LEFT(content, 220)"; PreviewAlias = "preview"; WhereClause = "content LIKE '%{0}%' ESCAPE '\\'" },
    [pscustomobject]@{ Name = "Lake Knowledge - extracted_docs.content/title"; Database = "xpdgxfsp_lake_knowledge"; Table = "extracted_docs"; IdColumn = "id"; PreviewExpression = "LEFT(CONCAT_WS(' | ', COALESCE(title,''), COALESCE(content,''), COALESCE(source_ref,'')), 220)"; PreviewAlias = "preview"; WhereClause = "(content LIKE '%{0}%' ESCAPE '\\' OR title LIKE '%{0}%' ESCAPE '\\' OR source_ref LIKE '%{0}%' ESCAPE '\\')" },
    [pscustomobject]@{ Name = "Lake Knowledge - doc_sections.content/title"; Database = "xpdgxfsp_lake_knowledge"; Table = "doc_sections"; IdColumn = "id"; PreviewExpression = "LEFT(CONCAT_WS(' | ', COALESCE(title,''), COALESCE(content,'')), 220)"; PreviewAlias = "preview"; WhereClause = "(content LIKE '%{0}%' ESCAPE '\\' OR title LIKE '%{0}%' ESCAPE '\\')" },
    [pscustomobject]@{ Name = "Lake Knowledge - knowledge_units"; Database = "xpdgxfsp_lake_knowledge"; Table = "knowledge_units"; IdColumn = "id"; PreviewExpression = "LEFT(CONCAT_WS(' | ', COALESCE(title,''), COALESCE(summary,''), COALESCE(unit_text,'')), 220)"; PreviewAlias = "preview"; WhereClause = "(title LIKE '%{0}%' ESCAPE '\\' OR summary LIKE '%{0}%' ESCAPE '\\' OR unit_text LIKE '%{0}%' ESCAPE '\\')" },
    [pscustomobject]@{ Name = "Lake Knowledge - knowledge_links"; Database = "xpdgxfsp_lake_knowledge"; Table = "knowledge_links"; IdColumn = "id"; PreviewExpression = "LEFT(CONCAT_WS(' | ', COALESCE(link_type,''), COALESCE(rationale,''), COALESCE(conversation_id,'')), 220)"; PreviewAlias = "preview"; WhereClause = "(link_type LIKE '%{0}%' ESCAPE '\\' OR rationale LIKE '%{0}%' ESCAPE '\\' OR conversation_id LIKE '%{0}%' ESCAPE '\\')" },
    [pscustomobject]@{ Name = "Lake Knowledge - published_context_reports"; Database = "xpdgxfsp_lake_knowledge"; Table = "published_context_reports"; IdColumn = "report_id"; PreviewExpression = "LEFT(CONCAT_WS(' | ', COALESCE(component_name,''), COALESCE(report_type,''), COALESCE(report_content,'')), 220)"; PreviewAlias = "preview"; WhereClause = "(report_content LIKE '%{0}%' ESCAPE '\\' OR component_name LIKE '%{0}%' ESCAPE '\\' OR report_type LIKE '%{0}%' ESCAPE '\\')" },
    [pscustomobject]@{ Name = "Lake Knowledge - lake_signals"; Database = "xpdgxfsp_lake_knowledge"; Table = "lake_signals"; IdColumn = "id"; PreviewExpression = "LEFT(CONCAT_WS(' | ', COALESCE(signal_type,''), COALESCE(signal_text,''), COALESCE(signal_source,'')), 220)"; PreviewAlias = "preview"; WhereClause = "(signal_text LIKE '%{0}%' ESCAPE '\\' OR signal_type LIKE '%{0}%' ESCAPE '\\' OR signal_source LIKE '%{0}%' ESCAPE '\\')" },
    [pscustomobject]@{ Name = "Lake Vector - raw_artifacts.content"; Database = "xpdgxfsp_lake_vector"; Table = "raw_artifacts"; IdColumn = "id"; PreviewExpression = "LEFT(content, 220)"; PreviewAlias = "preview"; WhereClause = "content LIKE '%{0}%' ESCAPE '\\'" },
    [pscustomobject]@{ Name = "Lake Vector - raw_conversations.content"; Database = "xpdgxfsp_lake_vector"; Table = "raw_conversations"; IdColumn = "id"; PreviewExpression = "LEFT(content, 220)"; PreviewAlias = "preview"; WhereClause = "content LIKE '%{0}%' ESCAPE '\\'" },
    [pscustomobject]@{ Name = "Lake Vector - doc_sections.content/title"; Database = "xpdgxfsp_lake_vector"; Table = "doc_sections"; IdColumn = "id"; PreviewExpression = "LEFT(CONCAT_WS(' | ', COALESCE(title,''), COALESCE(content,'')), 220)"; PreviewAlias = "preview"; WhereClause = "(content LIKE '%{0}%' ESCAPE '\\' OR title LIKE '%{0}%' ESCAPE '\\')" },
    [pscustomobject]@{ Name = "Lake Vector - semantic_vector_store"; Database = "xpdgxfsp_lake_vector"; Table = "semantic_vector_store"; IdColumn = "vector_id"; PreviewExpression = "LEFT(CONCAT_WS(' | ', COALESCE(content_type,''), COALESCE(source_table,''), COALESCE(content_text,'')), 220)"; PreviewAlias = "preview"; WhereClause = "(content_text LIKE '%{0}%' ESCAPE '\\' OR content_type LIKE '%{0}%' ESCAPE '\\' OR source_table LIKE '%{0}%' ESCAPE '\\')" },
    [pscustomobject]@{ Name = "Lake Vector - cvi_carousel"; Database = "xpdgxfsp_lake_vector"; Table = "cvi_carousel"; IdColumn = "id"; PreviewExpression = "LEFT(CONCAT_WS(' | ', COALESCE(component,''), COALESCE(payload_type,''), COALESCE(payload,'')), 220)"; PreviewAlias = "preview"; WhereClause = "(payload LIKE '%{0}%' ESCAPE '\\' OR component LIKE '%{0}%' ESCAPE '\\' OR payload_type LIKE '%{0}%' ESCAPE '\\')" },
    [pscustomobject]@{ Name = "Lake Vector - ai_memory_index"; Database = "xpdgxfsp_lake_vector"; Table = "ai_memory_index"; IdColumn = "memory_id"; PreviewExpression = "LEFT(CONCAT_WS(' | ', COALESCE(memory_key,''), COALESCE(memory_type,''), COALESCE(content_summary,'')), 220)"; PreviewAlias = "preview"; WhereClause = "(memory_key LIKE '%{0}%' ESCAPE '\\' OR memory_type LIKE '%{0}%' ESCAPE '\\' OR content_summary LIKE '%{0}%' ESCAPE '\\')" },
    [pscustomobject]@{ Name = "Lake Vector - published_context_reports"; Database = "xpdgxfsp_lake_vector"; Table = "published_context_reports"; IdColumn = "report_id"; PreviewExpression = "LEFT(CONCAT_WS(' | ', COALESCE(component_name,''), COALESCE(report_type,''), COALESCE(report_content,'')), 220)"; PreviewAlias = "preview"; WhereClause = "(report_content LIKE '%{0}%' ESCAPE '\\' OR component_name LIKE '%{0}%' ESCAPE '\\' OR report_type LIKE '%{0}%' ESCAPE '\\')" },
    [pscustomobject]@{ Name = "Lake Vector - cm_system_context_snapshots"; Database = "xpdgxfsp_lake_vector"; Table = "cm_system_context_snapshots"; IdColumn = "snapshot_id"; PreviewExpression = "LEFT(CONCAT_WS(' | ', COALESCE(component_name,''), COALESCE(confidence_level,''), COALESCE(context_snapshot,'')), 220)"; PreviewAlias = "preview"; WhereClause = "(context_snapshot LIKE '%{0}%' ESCAPE '\\' OR component_name LIKE '%{0}%' ESCAPE '\\')" }
)

if ($IncludePcdeMemory) {
    $searchTargets += @(
        [pscustomobject]@{ Name = "PCDE Memory - declarative"; Database = "xpdgxfsp_pcde_memory"; Table = "pcde_declarative_memory"; IdColumn = "fact_id"; PreviewExpression = "LEFT(CONCAT_WS(' | ', COALESCE(predicate,''), COALESCE(object_value,''), COALESCE(domain,'')), 220)"; PreviewAlias = "preview"; WhereClause = "(predicate LIKE '%{0}%' ESCAPE '\\' OR object_value LIKE '%{0}%' ESCAPE '\\' OR domain LIKE '%{0}%' ESCAPE '\\')" },
        [pscustomobject]@{ Name = "PCDE Memory - procedural"; Database = "xpdgxfsp_pcde_memory"; Table = "pcde_procedure_registry"; IdColumn = "procedure_id"; PreviewExpression = "LEFT(CONCAT_WS(' | ', COALESCE(procedure_name,''), COALESCE(description,''), COALESCE(domain,''), COALESCE(why_it_exists,'')), 220)"; PreviewAlias = "preview"; WhereClause = "(procedure_name LIKE '%{0}%' ESCAPE '\\' OR description LIKE '%{0}%' ESCAPE '\\' OR domain LIKE '%{0}%' ESCAPE '\\' OR why_it_exists LIKE '%{0}%' ESCAPE '\\')" },
        [pscustomobject]@{ Name = "PCDE Memory - associative"; Database = "xpdgxfsp_pcde_memory"; Table = "pcde_procedure_relations"; IdColumn = "relation_id"; PreviewExpression = "LEFT(CONCAT_WS(' | ', COALESCE(relation_type,''), COALESCE(relation_target,''), COALESCE(notes,'')), 220)"; PreviewAlias = "preview"; WhereClause = "(relation_type LIKE '%{0}%' ESCAPE '\\' OR relation_target LIKE '%{0}%' ESCAPE '\\' OR notes LIKE '%{0}%' ESCAPE '\\')" },
        [pscustomobject]@{ Name = "PCDE Memory - AI memory"; Database = "xpdgxfsp_pcde_memory"; Table = "pcde_ai_memory"; IdColumn = "memory_id"; PreviewExpression = "LEFT(CONCAT_WS(' | ', COALESCE(agent_name,''), COALESCE(memory_type,''), COALESCE(key_data,'')), 220)"; PreviewAlias = "preview"; WhereClause = "(agent_name LIKE '%{0}%' ESCAPE '\\' OR memory_type LIKE '%{0}%' ESCAPE '\\' OR key_data LIKE '%{0}%' ESCAPE '\\')" }
    )
}

if (-not (Test-Path $QueryScript)) {
    throw "Query.ps1 not found: $QueryScript"
}

$escapedTerm = Escape-SqlLike -Value $SearchTerm

Write-Host ""
Write-Host "PCDE LONG-TERM MEMORY SEARCH" -ForegroundColor Cyan
Write-Host ("Search Term: " + $SearchTerm) -ForegroundColor White
Write-Host ("Using Query Script: " + $QueryScript) -ForegroundColor DarkGray
Write-Host ""

$totalHits = 0
$totalTargetsWithHits = 0

foreach ($target in $searchTargets) {
    $where = [string]::Format($target.WhereClause, $escapedTerm)

    $sqlLines = @(
        "SELECT",
        "    " + $target.IdColumn + " AS record_id,",
        "    " + $target.PreviewExpression + " AS " + $target.PreviewAlias,
        "FROM " + $target.Database + "." + $target.Table,
        "WHERE " + $where,
        "LIMIT " + $MaxRowsPerTarget + ";"
    )
    $sql = $sqlLines -join [Environment]::NewLine

    Write-Host ("TABLE " + $target.Name) -ForegroundColor Yellow

    $rows = Invoke-QueryScript -Sql $sql

    if ($rows -and @($rows).Count -gt 0) {
        $count = @($rows).Count
        $totalTargetsWithHits++
        $totalHits += $count
        Write-Host ("   OK: " + $count + " match(es)") -ForegroundColor Green
        Show-Matches -Rows $rows -PreviewProperty $target.PreviewAlias
    }
    else {
        Write-Host "   No matches" -ForegroundColor DarkGray
    }

    Write-Host ""
}

if ($totalHits -gt 0) {
    Write-Host ("Done. Found " + $totalHits + " total match row(s) across " + $totalTargetsWithHits + " target(s).") -ForegroundColor Green
}
else {
    Write-Host "Done. No matches found." -ForegroundColor DarkGray
}
