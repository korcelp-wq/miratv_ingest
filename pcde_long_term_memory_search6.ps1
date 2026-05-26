param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$SearchTerm,

    [string[]]$Databases = @(
        "xpdgxfsp_pcde_memory",
        "xpdgxfsp_lake_knowledge",
        "xpdgxfsp_lake_vector"
    ),

    [string]$Host = "localhost",
    [int]$Port = 3306,
    [string]$User = "",
    [string]$Password = "",
    [string]$MySqlExePath = "mysql",
    [int]$MaxRowsPerColumn = 5,
    [int]$PreviewLength = 260,
    [int]$MaxColumnsToSearch = 250,
    [switch]$CaseSensitive,
    [switch]$ShowSqlOnly,
    [switch]$IncludeJsonColumns,
    [switch]$Wide,
    [string[]]$ExcludeTables = @(
        "embeddings",
        "semantic_vector_store",
        "vector_embedding_metadata",
        "embedding_queue"
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-MySqlCli {
    param([string]$ExePath)

    try {
        $null = & $ExePath --version 2>$null
        return $true
    }
    catch {
        return $false
    }
}

function Quote-MySqlIdent {
    param([string]$Value)
    return "`" + ($Value -replace "`", "``") + "`"
}

function Escape-MySqlString {
    param([string]$Value)
    if ($null -eq $Value) { return "" }
    $escaped = $Value
    $escaped = $escaped -replace "\\", "\\\\"
    $escaped = $escaped -replace "'", "''"
    return $escaped
}

function Invoke-MySqlTextQuery {
    param(
        [string]$Sql,
        [string]$Host,
        [int]$Port,
        [string]$User,
        [string]$Password,
        [string]$MySqlExePath
    )

    if (-not (Test-MySqlCli -ExePath $MySqlExePath)) {
        throw "mysql CLI not found. Set -MySqlExePath to the full path of mysql.exe."
    }

    $args = @(
        "--host=$Host",
        "--port=$Port",
        "--batch",
        "--raw",
        "--skip-column-names"
    )

    if (-not [string]::IsNullOrWhiteSpace($User)) {
        $args += "--user=$User"
    }

    if (-not [string]::IsNullOrWhiteSpace($Password)) {
        $args += "--password=$Password"
    }

    $args += "--execute=$Sql"

    $output = & $MySqlExePath @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("MySQL query failed: " + ($output -join [Environment]::NewLine))
    }

    return @($output)
}

function Convert-TabSeparatedToObjects {
    param(
        [string[]]$Lines,
        [string[]]$Headers
    )

    $objects = @()
    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "`t", $Headers.Count
        $row = [ordered]@{}
        for ($i = 0; $i -lt $Headers.Count; $i++) {
            $value = ""
            if ($i -lt $parts.Count) {
                $value = $parts[$i]
            }
            $row[$Headers[$i]] = $value
        }
        $objects += [pscustomobject]$row
    }
    return $objects
}

function Get-SearchableColumns {
    param(
        [string[]]$Databases,
        [string]$Host,
        [int]$Port,
        [string]$User,
        [string]$Password,
        [string]$MySqlExePath,
        [string[]]$ExcludeTables,
        [switch]$IncludeJsonColumns
    )

    $dbList = ($Databases | ForEach-Object { "'" + (Escape-MySqlString $_) + "'" }) -join ","
    $excluded = ""
    if ($ExcludeTables -and $ExcludeTables.Count -gt 0) {
        $excludedTables = ($ExcludeTables | ForEach-Object { "'" + (Escape-MySqlString $_) + "'" }) -join ","
        $excluded = " AND c.TABLE_NAME NOT IN ($excludedTables)"
    }

    $jsonClause = ""
    if (-not $IncludeJsonColumns) {
        $jsonClause = " AND c.DATA_TYPE <> 'json'"
    }

    $sql = @"
SELECT
  c.TABLE_SCHEMA,
  c.TABLE_NAME,
  c.COLUMN_NAME,
  c.DATA_TYPE,
  CASE
    WHEN k.COLUMN_NAME IS NOT NULL THEN k.COLUMN_NAME
    ELSE ''
  END AS PRIMARY_KEY_COLUMN
FROM information_schema.COLUMNS c
LEFT JOIN information_schema.KEY_COLUMN_USAGE k
  ON c.TABLE_SCHEMA = k.TABLE_SCHEMA
 AND c.TABLE_NAME = k.TABLE_NAME
 AND k.CONSTRAINT_NAME = 'PRIMARY'
 AND k.ORDINAL_POSITION = 1
WHERE c.TABLE_SCHEMA IN ($dbList)
  AND c.DATA_TYPE IN ('char','varchar','tinytext','text','mediumtext','longtext')
  $jsonClause
  $excluded
ORDER BY c.TABLE_SCHEMA, c.TABLE_NAME, c.ORDINAL_POSITION;
"@

    $lines = Invoke-MySqlTextQuery -Sql $sql -Host $Host -Port $Port -User $User -Password $Password -MySqlExePath $MySqlExePath
    return Convert-TabSeparatedToObjects -Lines $lines -Headers @('table_schema','table_name','column_name','data_type','primary_key_column')
}

function Build-SearchUnionSql {
    param(
        [object[]]$Columns,
        [string]$SearchTerm,
        [int]$MaxRowsPerColumn,
        [int]$PreviewLength,
        [switch]$CaseSensitive
    )

    $escapedSearch = Escape-MySqlString $SearchTerm
    $likeExpr = if ($CaseSensitive) {
        "CAST({0} AS CHAR) LIKE BINARY '%{1}%'"
    } else {
        "LOWER(CAST({0} AS CHAR)) LIKE '%{1}%'"
    }

    if (-not $CaseSensitive) {
        $escapedSearch = $escapedSearch.ToLowerInvariant()
    }

    $chunks = New-Object System.Collections.Generic.List[string]

    foreach ($col in $Columns) {
        $schema = Quote-MySqlIdent $col.table_schema
        $table  = Quote-MySqlIdent $col.table_name
        $column = Quote-MySqlIdent $col.column_name

        $pkExpr = if ([string]::IsNullOrWhiteSpace($col.primary_key_column)) {
            "''"
        } else {
            "CAST(" + (Quote-MySqlIdent $col.primary_key_column) + " AS CHAR)"
        }

        $whereClause = [string]::Format($likeExpr, $column, $escapedSearch)

        $sql = @"
SELECT
  '$($col.table_schema)' AS db_name,
  '$($col.table_name)' AS table_name,
  '$($col.column_name)' AS column_name,
  $pkExpr AS record_id,
  LEFT(REPLACE(REPLACE(CAST($column AS CHAR), CHAR(13), ' '), CHAR(10), ' '), $PreviewLength) AS preview_text
FROM $schema.$table
WHERE $whereClause
LIMIT $MaxRowsPerColumn
"@
        $chunks.Add($sql) | Out-Null
    }

    if ($chunks.Count -eq 0) {
        throw "No searchable columns were discovered."
    }

    return ($chunks -join "`nUNION ALL`n") + "`nORDER BY db_name, table_name, column_name;"
}

function Show-SearchPlan {
    param([object[]]$Columns)

    $grouped = $Columns | Group-Object table_schema, table_name
    Write-Host ""
    Write-Host "Search plan:" -ForegroundColor Cyan
    foreach ($group in $grouped) {
        $first = $group.Group[0]
        $cols = ($group.Group | ForEach-Object { $_.column_name }) -join ", "
        Write-Host (" - {0}.{1}: {2}" -f $first.table_schema, $first.table_name, $cols) -ForegroundColor DarkGray
    }
}

function Show-Results {
    param(
        [object[]]$Rows,
        [switch]$Wide
    )

    if (-not $Rows -or $Rows.Count -eq 0) {
        Write-Host ""
        Write-Host "No matches found." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host ("Matches found: {0}" -f $Rows.Count) -ForegroundColor Green

    $groups = $Rows | Group-Object db_name, table_name
    foreach ($group in $groups) {
        $first = $group.Group[0]
        Write-Host ""
        Write-Host ("[{0}.{1}]" -f $first.db_name, $first.table_name) -ForegroundColor Cyan

        foreach ($row in $group.Group) {
            $rid = if ([string]::IsNullOrWhiteSpace($row.record_id)) { "-" } else { $row.record_id }
            $preview = [string]$row.preview_text
            if (-not $Wide -and $preview.Length -gt 180) {
                $preview = $preview.Substring(0, 180) + "..."
            }

            Write-Host ("  • {0} | id={1}" -f $row.column_name, $rid) -ForegroundColor White
            Write-Host ("    {0}" -f $preview) -ForegroundColor Gray
        }
    }
}

Write-Host ""
Write-Host "PCDE Long-Term Memory Search" -ForegroundColor Cyan
Write-Host "============================" -ForegroundColor Cyan

$allColumns = Get-SearchableColumns `
    -Databases $Databases `
    -Host $Host `
    -Port $Port `
    -User $User `
    -Password $Password `
    -MySqlExePath $MySqlExePath `
    -ExcludeTables $ExcludeTables `
    -IncludeJsonColumns:$IncludeJsonColumns

if (-not $allColumns -or $allColumns.Count -eq 0) {
    throw "No searchable text columns found in the requested databases."
}

$searchColumns = @($allColumns | Select-Object -First $MaxColumnsToSearch)

Write-Host ("Discovered {0} searchable text columns across {1} database(s)." -f $allColumns.Count, $Databases.Count) -ForegroundColor DarkCyan
if ($searchColumns.Count -lt $allColumns.Count) {
    Write-Host ("Using first {0} columns due to -MaxColumnsToSearch limit." -f $searchColumns.Count) -ForegroundColor Yellow
}

Show-SearchPlan -Columns $searchColumns

$sql = Build-SearchUnionSql `
    -Columns $searchColumns `
    -SearchTerm $SearchTerm `
    -MaxRowsPerColumn $MaxRowsPerColumn `
    -PreviewLength $PreviewLength `
    -CaseSensitive:$CaseSensitive

if ($ShowSqlOnly) {
    Write-Host ""
    Write-Host "Generated SQL:" -ForegroundColor Cyan
    Write-Output $sql
    exit 0
}

$rawResultLines = Invoke-MySqlTextQuery `
    -Sql $sql `
    -Host $Host `
    -Port $Port `
    -User $User `
    -Password $Password `
    -MySqlExePath $MySqlExePath

$results = Convert-TabSeparatedToObjects -Lines $rawResultLines -Headers @('db_name','table_name','column_name','record_id','preview_text')
Show-Results -Rows $results -Wide:$Wide
