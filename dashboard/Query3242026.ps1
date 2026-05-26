#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory = $true)]
    [string]$Sql,

    [string]$Database = "lake_knowledge",

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

function Test-IsScalarLike {
    param([object]$Value)

    if ($null -eq $Value) { return $true }
    if ($Value -is [string]) { return $true }
    if ($Value -is [ValueType]) { return $true }
    return $false
}

function Test-LooksLikeRowCollection {
    param([object]$Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [string]) { return $false }
    if (-not ($Value -is [System.Collections.IEnumerable])) { return $false }

    $items = @($Value)
    if ($items.Count -eq 0) { return $true }

    foreach ($item in $items) {
        if ($null -eq $item) { continue }
        if (Test-IsScalarLike -Value $item) {
            return $false
        }
    }

    return $true
}

function Test-IsStatusOnlyRow {
    param([object]$Row)

    if ($null -eq $Row) { return $true }

    $propNames = @($Row.PSObject.Properties.Name)
    if ($propNames.Count -eq 0) { return $false }

    $statusProps = @('affected', 'ok', 'status', 'message', 'rowcount', 'rows_affected')
    $nonStatus = @($propNames | Where-Object { $_ -notin $statusProps })

    return ($nonStatus.Count -eq 0)
}

function Get-FirstMeaningfulRows {
    param([object]$Response)

    if ($null -eq $Response) {
        return @()
    }

    # Preferred direct row containers
    foreach ($name in @('rows','Rows','data','Data','result','Result')) {
        if ($Response.PSObject.Properties.Name -contains $name) {
            $candidate = $Response.$name
            if (Test-LooksLikeRowCollection -Value $candidate) {
                $rows = @($candidate)
                if ($rows.Count -eq 0) { return @() }
                if (-not (Test-IsStatusOnlyRow -Row $rows[0])) {
                    return $rows
                }
            }
        }
    }

    # Multi-result-set containers
    foreach ($name in @('tables','Tables','resultSets','ResultSets','sets','Sets')) {
        if ($Response.PSObject.Properties.Name -contains $name) {
            foreach ($set in @($Response.$name)) {
                if (Test-LooksLikeRowCollection -Value $set) {
                    $rows = @($set)
                    if ($rows.Count -eq 0) { continue }
                    if (-not (Test-IsStatusOnlyRow -Row $rows[0])) {
                        return $rows
                    }
                }
            }
        }
    }

    # Generic property scan for nested row collections
    foreach ($prop in $Response.PSObject.Properties) {
        $value = $prop.Value
        if (Test-LooksLikeRowCollection -Value $value) {
            $rows = @($value)
            if ($rows.Count -eq 0) { continue }
            if (-not (Test-IsStatusOnlyRow -Row $rows[0])) {
                return $rows
            }
        }
    }

    # Enumerable response itself
    if (Test-LooksLikeRowCollection -Value $Response) {
        $rows = @($Response)
        if ($rows.Count -gt 0 -and -not (Test-IsStatusOnlyRow -Row $rows[0])) {
            return $rows
        }
    }

    # Fallback to direct rows/status when nothing better exists
    foreach ($name in @('rows','Rows','data','Data','result','Result')) {
        if ($Response.PSObject.Properties.Name -contains $name) {
            return @($Response.$name)
        }
    }

    if (Test-LooksLikeRowCollection -Value $Response) {
        return @($Response)
    }

    return @($Response)
}

try {
    Write-Verbose "Executing on [$Database]"
    Write-Verbose "SQL: $Sql"


    $bodyObject = @{
        token  = $token
        db     = $Database
        sql    = $Sql
        params = @($Params)
    }
    $bodyJson = $bodyObject | ConvertTo-Json -Depth 20 -Compress

    $response = Invoke-RestMethod `
        -Uri $endpoint `
        -Method Post `
        -Body $bodyJson `
        -ContentType "application/json"

    $rows = @(Get-FirstMeaningfulRows -Response $response)

    $envelope = [PSCustomObject]@{
        PSTypeName = 'MiraTV.QueryResult'
        Ok         = $true
        Error      = $null
        RowCount   = $rows.Count
        Rows       = $rows
        Raw        = $response
    }

    if ($PassThruEnvelope) {
        $envelope
    }
    else {
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
    }

    $errorEnvelope = New-QueryError -Message $_.Exception.Message -RawResponse $rawResponse

    Write-Host "[Query Error] $($errorEnvelope.Error)" -ForegroundColor Red
    if ($rawResponse) {
        Write-Host "[Raw Response] $rawResponse" -ForegroundColor Yellow
    }
    if ($PassThruEnvelope) {
        $errorEnvelope
    }
    else {
        throw "Query failed: $($errorEnvelope.Error) | Raw: $rawResponse"
    }
}
