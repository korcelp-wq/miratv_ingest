#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory = $true)]
    [string]$SearchTerm,

    [string]$QueryType = "general",

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

function Escape-SqlLiteral {
    param([string]$Value)
    if ($null -eq $Value) { return "" }
    return ($Value -replace "'", "''")
}

function Write-Info {
    param([string]$Message, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    if (-not $Quiet) {
        Write-Host $Message -ForegroundColor $Color
    }
}

function Get-UsableRows {
    param($Response)

    if ($null -eq $Response) { return @() }

    if ($null -ne $Response.rows -and @($Response.rows).Count -gt 0) {
        return @($Response.rows)
    }

    if ($null -ne $Response.rowsets -and @($Response.rowsets).Count -gt 0) {
        foreach ($rowset in @($Response.rowsets)) {
            if ($null -ne $rowset -and @($rowset).Count -gt 0) {
                return @($rowset)
            }
        }
    }

    return @()
}

# Escape inputs
$escapedSearchTerm = Escape-SqlLiteral -Value $SearchTerm
$escapedQueryType  = Escape-SqlLiteral -Value $QueryType

# Build SQL CALL
$sql = "CALL $ProcedureName('$escapedSearchTerm', '$escapedQueryType', $Limit);"

# Build request body
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

    # Raw JSON output if requested
    if ($RawJson) {
        $response | ConvertTo-Json -Depth 20
        return
    }

    $usableRows = @(Get-UsableRows -Response $response)

    # Pretty output
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
            $preview     = if ($row.PSObject.Properties.Name -contains 'preview_text') { $row.preview_text } else { '' }
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
        }
    }

    # Always return full response object (for loops / automation)
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
