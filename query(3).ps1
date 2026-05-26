#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Sql,

    [string]$Db = "lake_knowledge",

    [string[]]$Params = @(),

    [switch]$PassThruEnvelope
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$endpoint = "https://miratv.club/_workers/api/series/dog_open.php"

function New-QueryError {
    param(
        [string]$Message,
        [object]$RawResponse = $null
    )

    [PSCustomObject]@{
        PSTypeName  = 'MiraTV.QueryError'
        Ok          = $false
        Error       = $Message
        RawResponse = $RawResponse
        Rows        = @()
    }
}

function Normalize-Rows {
    param(
        [object]$Response
    )

    if ($null -eq $Response) {
        return @()
    }

    # Common response shapes
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

    # Single object fallback
    return @($Response)
}

try {
    Write-Verbose "Executing on [$Db]"
    Write-Verbose "SQL: $Sql"

    $bodyObject = @{
        token  = $token
        db     = $Db
        sql    = $Sql
        params = @($Params)
    }

    # Keep JSON only for HTTP transport to dog_open.php
    $bodyJson = $bodyObject | ConvertTo-Json -Depth 10 -Compress

    $response = Invoke-RestMethod `
        -Uri $endpoint `
        -Method Post `
        -Body $bodyJson `
        -ContentType "application/json"

    $rows = Normalize-Rows -Response $response

    $envelope = [PSCustomObject]@{
        PSTypeName = 'MiraTV.QueryResult'
        Ok         = $true
        Error      = $null
        RowCount   = @($rows).Count
        Rows       = @($rows)
        Raw        = $response
    }

    if ($PassThruEnvelope) {
        $envelope
    }
    else {
        # Default: return rows directly, PowerShell-native
        $envelope.Rows
    }
}
catch {
    $rawResponse = $null

    try {
        if ($_.Exception.Response) {
            $stream = $_.Exception.Response.GetResponseStream()
            if ($stream) {
                $reader = [System.IO.StreamReader]::new($stream)
                $rawResponse = $reader.ReadToEnd()
                $reader.Dispose()
            }
        }
    }
    catch {
        # ignore secondary extraction errors
    }

    $errorEnvelope = New-QueryError -Message $_.Exception.Message -RawResponse $rawResponse

    if ($PassThruEnvelope) {
        $errorEnvelope
    }
    else {
        throw "Query failed: $($errorEnvelope.Error)"
    }
}