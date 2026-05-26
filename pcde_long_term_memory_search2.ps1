param(
    [Parameter(Mandatory=$true)]
    [string]$SearchTerm,

    [string]$QueryScript = "C:\miratv_ingest\dashboard\Query.ps1",

    [int]$MaxRowsPerTable = 5
)

# ============================================================
# SIMPLE SAFE ESCAPE
# ============================================================
function Escape-Sql {
    param([string]$Value)
    if (-not $Value) { return "" }
    return $Value.Replace("'", "''")
}

# ============================================================
# RUN QUERY VIA YOUR Query.ps1
# ============================================================
function Run-Query {
    param([string]$Sql)

    try {
        return & $QueryScript -Sql $Sql 2>$null
    }
    catch {
        Write-Host "❌ Query failed: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

# ============================================================
# GET TEXT COLUMNS FROM ALL DBs
# ============================================================
function Get-SearchTargets {

    $sql = @"
SELECT
    TABLE_SCHEMA,
    TABLE_NAME,
    COLUMN_NAME
FROM information_schema.COLUMNS
WHERE DATA_TYPE IN ('char','varchar','text','mediumtext','longtext')
  AND TABLE_SCHEMA IN (
    'xpdgxfsp_pcde_memory',
    'xpdgxfsp_lake_knowledge',
    'xpdgxfsp_lake_vector'
)
ORDER BY TABLE_SCHEMA, TABLE_NAME;
"@

    return Run-Query $sql
}

# ============================================================
# MAIN SEARCH
# ============================================================

Write-Host ""
Write-Host "🔍 PCDE LONG-TERM MEMORY SEARCH" -ForegroundColor Cyan
Write-Host "Search Term: $SearchTerm"
Write-Host ""

$escaped = Escape-Sql $SearchTerm
$targets = Get-SearchTargets

if (-not $targets) {
    Write-Host "❌ No searchable columns found" -ForegroundColor Red
    exit
}

$resultsFound = 0

foreach ($t in $targets) {

    $db     = $t.TABLE_SCHEMA
    $table  = $t.TABLE_NAME
    $column = $t.COLUMN_NAME

    $sql = @"
SELECT
    '$db' as db_name,
    '$table' as table_name,
    '$column' as column_name,
    LEFT($column, 200) as preview
FROM $db.$table
WHERE $column LIKE '%$escaped%'
LIMIT $MaxRowsPerTable;
"@

    $rows = Run-Query $sql

    if ($rows -and $rows.Count -gt 0) {

        $resultsFound++

        Write-Host ""
        Write-Host "📂 $db.$table ($column)" -ForegroundColor Yellow

        foreach ($r in $rows) {
            $preview = $r.preview
            if ($preview.Length -gt 200) {
                $preview = $preview.Substring(0,200)
            }
            Write-Host "   → $preview"
        }
    }
}

Write-Host ""

if ($resultsFound -eq 0) {
    Write-Host "⚪ No matches found" -ForegroundColor DarkGray
} else {
    Write-Host "✅ Matches found in $resultsFound locations" -ForegroundColor Green
}