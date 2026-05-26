# MiraTV DB Query Helper for dog_open_proc.php
# File: tools/common/DbQuery.psm1
# Purpose:
#   Shared PowerShell helper for read-only DB query calls from MiraTV workers.
#
# Bridge:
#   dog_open_proc.php
#
# Design:
#   - Does not contain credentials or tokens.
#   - Does not hardcode production endpoint.
#   - Reads endpoint from DOG_OPEN_PROC_ENDPOINT unless passed explicitly.
#   - Reads token from DOG_OPEN_PROC_TOKEN unless passed explicitly.
#   - Enforces local read-only SQL guard before calling the bridge.
#   - Sends JSON POST body: token, db, sql, params.
#   - Accepts response shapes from dog_open_proc.php:
#       { rows: [...] }
#       { rowsets: [...] }
#       { result: [...] }
#
# Required environment variables:
#   $env:DOG_OPEN_PROC_ENDPOINT = "https://miratv.club/_workers/api/series/dog_open_proc.php"
#   $env:DOG_OPEN_PROC_TOKEN = "<token>"
#
# Example:
#   Import-Module ".\tools\common\DbQuery.psm1" -Force
#   Invoke-ReadOnlyDbQuery -DatabaseKey "content" -Sql "SELECT COUNT(*) AS row_count FROM epg_programs"

Set-StrictMode -Version Latest

function Test-ReadOnlySql {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sql
    )

    if ([string]::IsNullOrWhiteSpace($Sql)) {
        throw "SQL is required."
    }

    $trimmed = $Sql.Trim()

    # Remove leading comments enough to avoid blocking normal documented SELECT queries.
    $normalized = $trimmed -replace "(?ms)^\s*(--.*?$|/\*.*?\*/)\s*", ""
    $normalizedUpper = $normalized.ToUpperInvariant()

    $allowedStarts = @(
        "SELECT ",
        "SELECT`r",
        "SELECT`n",
        "SHOW ",
        "DESCRIBE ",
        "DESC ",
        "EXPLAIN ",
	"WITH "
    )

    $startsAllowed = $false

    foreach ($prefix in $allowedStarts) {
        if ($normalizedUpper.StartsWith($prefix) -or $normalizedUpper -eq $prefix.Trim()) {
            $startsAllowed = $true
            break
        }
    }

    if (-not $startsAllowed) {
        throw "Blocked non-read-only SQL. Only SELECT, SHOW, DESCRIBE, EXPLAIN, and WITH queries are allowed from DbQuery.psm1."
    }

    $blockedPatterns = @(
        "\bINSERT\b",
        "\bUPDATE\b",
        "\bDELETE\b",
        "\bDROP\b",
        "\bALTER\b",
        "\bCREATE\b",
        "\bTRUNCATE\b",
        "\bREPLACE\b",
        "\bRENAME\b",
        "\bGRANT\b",
        "\bREVOKE\b",
        "\bLOCK\b",
        "\bUNLOCK\b",
        "\bCALL\b",
        "\bLOAD\b",
        "\bOUTFILE\b",
        "\bINTO\s+OUTFILE\b",
        "\bINTO\s+DUMPFILE\b",
        "\bSET\b",
        "\bSTART\s+TRANSACTION\b",
        "\bCOMMIT\b",
        "\bROLLBACK\b"
    )

    foreach ($pattern in $blockedPatterns) {
        if ($normalizedUpper -match $pattern) {
            throw "Blocked SQL because it contains a prohibited keyword or operation: $pattern"
        }
    }

    return $true
}

function Resolve-DogOpenProcEndpoint {
    [CmdletBinding()]
    param(
        [string]$Endpoint = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($Endpoint)) {
        return $Endpoint
    }

    $envEndpoint = [Environment]::GetEnvironmentVariable("DOG_OPEN_PROC_ENDPOINT", "Process")

    if (-not [string]::IsNullOrWhiteSpace($envEndpoint)) {
        return $envEndpoint
    }

    $envEndpoint = [Environment]::GetEnvironmentVariable("DOG_OPEN_PROC_ENDPOINT", "User")

    if (-not [string]::IsNullOrWhiteSpace($envEndpoint)) {
        return $envEndpoint
    }

    $envEndpoint = [Environment]::GetEnvironmentVariable("DOG_OPEN_PROC_ENDPOINT", "Machine")

    if (-not [string]::IsNullOrWhiteSpace($envEndpoint)) {
        return $envEndpoint
    }

    throw "DOG_OPEN_PROC_ENDPOINT is not configured. Set DOG_OPEN_PROC_ENDPOINT or pass -Endpoint."
}

function Resolve-DogOpenProcToken {
    [CmdletBinding()]
    param(
        [string]$Token = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        return $Token
    }

    $envToken = [Environment]::GetEnvironmentVariable("DOG_OPEN_PROC_TOKEN", "Process")

    if (-not [string]::IsNullOrWhiteSpace($envToken)) {
        return $envToken
    }

    $envToken = [Environment]::GetEnvironmentVariable("DOG_OPEN_PROC_TOKEN", "User")

    if (-not [string]::IsNullOrWhiteSpace($envToken)) {
        return $envToken
    }

    $envToken = [Environment]::GetEnvironmentVariable("DOG_OPEN_PROC_TOKEN", "Machine")

    if (-not [string]::IsNullOrWhiteSpace($envToken)) {
        return $envToken
    }

    throw "DOG_OPEN_PROC_TOKEN is not configured. Set DOG_OPEN_PROC_TOKEN or pass -Token."
}

function Convert-ToArraySafe {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [System.Array]) {
        return @($Value)
    }

    return @($Value)
}

function Convert-DogOpenProcResponseRows {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Response
    )

    if ($null -eq $Response) {
        return @()
    }

    if ($Response.PSObject.Properties.Name -contains "error") {
        $errorValue = [string]$Response.error

        if (-not [string]::IsNullOrWhiteSpace($errorValue)) {
            throw "dog_open_proc.php returned error: $errorValue"
        }
    }

    if ($Response.PSObject.Properties.Name -contains "ok") {
        $okValue = $Response.ok

        if ($okValue -eq $false) {
            $message = "dog_open_proc.php returned ok=false"

            if ($Response.PSObject.Properties.Name -contains "message") {
                $message = "$message message=$($Response.message)"
            }

            throw $message
        }
    }

    if ($Response.PSObject.Properties.Name -contains "rows") {
        return Convert-ToArraySafe -Value $Response.rows
    }

    if ($Response.PSObject.Properties.Name -contains "result") {
        return Convert-ToArraySafe -Value $Response.result
    }

    if ($Response.PSObject.Properties.Name -contains "rowsets") {
        $rowsets = Convert-ToArraySafe -Value $Response.rowsets

        if ($rowsets.Count -eq 0) {
            return @()
        }

        $first = $rowsets[0]

        if ($null -eq $first) {
            return @()
        }

        if ($first -is [System.Array]) {
            return @($first)
        }

        if ($first.PSObject.Properties.Name -contains "rows") {
            return Convert-ToArraySafe -Value $first.rows
        }

        return Convert-ToArraySafe -Value $first
    }

    if ($Response -is [System.Array]) {
        return @($Response)
    }

    return @($Response)
}

function Invoke-DogOpenProc {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DatabaseKey,

        [Parameter(Mandatory = $true)]
        [string]$Sql,

        [object[]]$Params = @(),

        [string]$Endpoint = "",

        [string]$Token = "",

        [int]$TimeoutSec = 30,

        [hashtable]$ExtraBody = @{}
    )

    if ([string]::IsNullOrWhiteSpace($DatabaseKey)) {
        throw "DatabaseKey is required."
    }

    if ([string]::IsNullOrWhiteSpace($Sql)) {
        throw "Sql is required."
    }

    $resolvedEndpoint = Resolve-DogOpenProcEndpoint -Endpoint $Endpoint
    $resolvedToken = Resolve-DogOpenProcToken -Token $Token

    $body = [ordered]@{
        token = $resolvedToken
        db = $DatabaseKey
        sql = $Sql
        params = @($Params)
    }

    if ($null -ne $ExtraBody) {
        foreach ($key in $ExtraBody.Keys) {
            if (-not [string]::IsNullOrWhiteSpace([string]$key)) {
                $body[$key] = $ExtraBody[$key]
            }
        }
    }

    $jsonBody = $body | ConvertTo-Json -Depth 20

    try {
        $response = Invoke-RestMethod `
            -Uri $resolvedEndpoint `
            -Method Post `
            -ContentType "application/json" `
            -Body $jsonBody `
            -TimeoutSec $TimeoutSec

        return $response
    }
    catch {
        throw "Invoke-DogOpenProc failed: $($_.Exception.Message)"
    }
}

function Invoke-ReadOnlyDbQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DatabaseKey,

        [Parameter(Mandatory = $true)]
        [string]$Sql,

        [object[]]$Params = @(),

        [string]$Endpoint = "",

        [string]$Token = "",

        [int]$TimeoutSec = 30,

        [hashtable]$ExtraBody = @{}
    )

    [void](Test-ReadOnlySql -Sql $Sql)

    $resolvedEndpoint = Resolve-DogOpenProcEndpoint -Endpoint $Endpoint

    $response = Invoke-DogOpenProc `
        -DatabaseKey $DatabaseKey `
        -Sql $Sql `
        -Params $Params `
        -Endpoint $resolvedEndpoint `
        -Token $Token `
        -TimeoutSec $TimeoutSec `
        -ExtraBody $ExtraBody

    $rows = Convert-DogOpenProcResponseRows -Response $response

    return [pscustomobject]@{
        ok = $true
        endpoint = $resolvedEndpoint
        database_key = $DatabaseKey
        row_count = @($rows).Count
        rows = @($rows)
        raw_response = $response
    }
}

function Get-FirstDbQueryRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$QueryResult
    )

    if ($null -eq $QueryResult) {
        return $null
    }

    if (-not ($QueryResult.PSObject.Properties.Name -contains "rows")) {
        return $null
    }

    $rows = Convert-ToArraySafe -Value $QueryResult.rows

    if ($rows.Count -eq 0) {
        return $null
    }

    return $rows[0]
}

Export-ModuleMember -Function `
    Test-ReadOnlySql, `
    Resolve-DogOpenProcEndpoint, `
    Resolve-DogOpenProcToken, `
    Convert-DogOpenProcResponseRows, `
    Invoke-DogOpenProc, `
    Invoke-ReadOnlyDbQuery, `
    Get-FirstDbQueryRow