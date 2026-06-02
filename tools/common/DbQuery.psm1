# MiraTV DB Query Helper for dog_open_proc.php
# File: tools/common/DbQuery.psm1
# Purpose:
#   Shared PowerShell helper for DB query calls from MiraTV workers.
#
# Bridge:
#   dog_open_proc.php
#
# Design:
#   - Does not contain credentials or tokens.
#   - Does not hardcode a production token.
#   - Endpoint/token resolution order:
#       1. Explicit -Endpoint / -Token parameters
#       2. Process/User/Machine environment variables:
#            DOG_OPEN_PROC_ENDPOINT
#            DOG_OPEN_PROC_TOKEN
#       3. Optional local config files:
#            runtime/control/dog_open_proc_config.json
#            tools/config/dog_open_proc_config.json
#   - Invoke-DogOpenProc is the low-level bridge and can execute any SQL the bridge allows.
#   - Invoke-ReadOnlyDbQuery enforces the local read-only SQL guard.
#
# Optional config example:
# {
#   "default_endpoint": "https://miratv.club/_workers/api/dog_open_proc.php",
#   "token": "PUT_LOCAL_TOKEN_HERE",
#   "endpoints": {
#     "content": "https://miratv.club/_workers/api/dog_open_proc.php",
#     "series": "https://miratv.club/_workers/api/series/dog_open_proc.php"
#   }
# }

Set-StrictMode -Version Latest

function Get-DbQueryRepoRoot {
    [CmdletBinding()]
    param()

    if ($PSScriptRoot) {
        $candidate = Join-Path $PSScriptRoot "..\.."
        $resolved = Resolve-Path -Path $candidate -ErrorAction SilentlyContinue
        if ($null -ne $resolved) {
            return $resolved.Path
        }
    }

    return (Get-Location).Path
}

function Get-ObjectPropertyValue {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties |
        Where-Object { $_.Name -ieq $Name } |
        Select-Object -First 1

    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-DogOpenProcConfig {
    [CmdletBinding()]
    param([string]$ConfigPath = "")

    $paths = @()

    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $paths += $ConfigPath
    }

    $repoRoot = Get-DbQueryRepoRoot
    $paths += (Join-Path $repoRoot "runtime\control\dog_open_proc_config.json")
    $paths += (Join-Path $repoRoot "tools\config\dog_open_proc_config.json")

    foreach ($path in $paths) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }

        if (Test-Path -LiteralPath $path) {
            try {
                $config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                return [pscustomobject]@{
                    path = $path
                    config = $config
                }
            }
            catch {
                throw "Failed to parse dog_open_proc config file: $path error=$($_.Exception.Message)"
            }
        }
    }

    return $null
}

function Test-ReadOnlySql {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Sql)

    if ([string]::IsNullOrWhiteSpace($Sql)) {
        throw "SQL is required."
    }

    $trimmed = $Sql.Trim()
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
        throw "Blocked non-read-only SQL. Only SELECT, SHOW, DESCRIBE, EXPLAIN, and WITH queries are allowed from Invoke-ReadOnlyDbQuery."
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
        [string]$Endpoint = "",
        [string]$DatabaseKey = "",
        [string]$ConfigPath = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($Endpoint)) {
        return $Endpoint
    }

    foreach ($scope in @("Process", "User", "Machine")) {
        $envEndpoint = [Environment]::GetEnvironmentVariable("DOG_OPEN_PROC_ENDPOINT", $scope)
        if (-not [string]::IsNullOrWhiteSpace($envEndpoint)) {
            return $envEndpoint
        }
    }

    $configInfo = Get-DogOpenProcConfig -ConfigPath $ConfigPath

    if ($null -ne $configInfo) {
        $config = $configInfo.config
        $endpoints = Get-ObjectPropertyValue -Object $config -Name "endpoints"

        if ($null -ne $endpoints -and -not [string]::IsNullOrWhiteSpace($DatabaseKey)) {
            $dbEndpoint = Get-ObjectPropertyValue -Object $endpoints -Name $DatabaseKey
            if (-not [string]::IsNullOrWhiteSpace([string]$dbEndpoint)) {
                return [string]$dbEndpoint
            }
        }

        $defaultEndpoint = Get-ObjectPropertyValue -Object $config -Name "default_endpoint"
        if (-not [string]::IsNullOrWhiteSpace([string]$defaultEndpoint)) {
            return [string]$defaultEndpoint
        }

        $endpointValue = Get-ObjectPropertyValue -Object $config -Name "endpoint"
        if (-not [string]::IsNullOrWhiteSpace([string]$endpointValue)) {
            return [string]$endpointValue
        }
    }

    throw "DOG_OPEN_PROC_ENDPOINT is not configured. Set DOG_OPEN_PROC_ENDPOINT, pass -Endpoint, or create runtime\control\dog_open_proc_config.json."
}

function Resolve-DogOpenProcToken {
    [CmdletBinding()]
    param(
        [string]$Token = "",
        [string]$DatabaseKey = "",
        [string]$ConfigPath = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        return $Token
    }

    foreach ($scope in @("Process", "User", "Machine")) {
        $envToken = [Environment]::GetEnvironmentVariable("DOG_OPEN_PROC_TOKEN", $scope)
        if (-not [string]::IsNullOrWhiteSpace($envToken)) {
            return $envToken
        }
    }

    $configInfo = Get-DogOpenProcConfig -ConfigPath $ConfigPath

    if ($null -ne $configInfo) {
        $config = $configInfo.config
        $tokens = Get-ObjectPropertyValue -Object $config -Name "tokens"

        if ($null -ne $tokens -and -not [string]::IsNullOrWhiteSpace($DatabaseKey)) {
            $dbToken = Get-ObjectPropertyValue -Object $tokens -Name $DatabaseKey
            if (-not [string]::IsNullOrWhiteSpace([string]$dbToken)) {
                return [string]$dbToken
            }
        }

        foreach ($name in @("token", "default_token")) {
            $tokenValue = Get-ObjectPropertyValue -Object $config -Name $name
            if (-not [string]::IsNullOrWhiteSpace([string]$tokenValue)) {
                return [string]$tokenValue
            }
        }
    }

    throw "DOG_OPEN_PROC_TOKEN is not configured. Set DOG_OPEN_PROC_TOKEN, pass -Token, or create runtime\control\dog_open_proc_config.json."
}

function Convert-ToArraySafe {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

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
    param([AllowNull()][object]$Response)

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
        [Parameter(Mandatory = $true)][string]$DatabaseKey,
        [Parameter(Mandatory = $true)][string]$Sql,
        [object[]]$Params = @(),
        [string]$Endpoint = "",
        [string]$Token = "",
        [int]$TimeoutSec = 30,
        [hashtable]$ExtraBody = @{},
        [string]$ConfigPath = ""
    )

    if ([string]::IsNullOrWhiteSpace($DatabaseKey)) {
        throw "DatabaseKey is required."
    }

    if ([string]::IsNullOrWhiteSpace($Sql)) {
        throw "Sql is required."
    }

    $resolvedEndpoint = Resolve-DogOpenProcEndpoint -Endpoint $Endpoint -DatabaseKey $DatabaseKey -ConfigPath $ConfigPath
    $resolvedToken = Resolve-DogOpenProcToken -Token $Token -DatabaseKey $DatabaseKey -ConfigPath $ConfigPath

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
        throw "Invoke-DogOpenProc failed: endpoint=$resolvedEndpoint database_key=$DatabaseKey message=$($_.Exception.Message)"
    }
}

function Invoke-ReadOnlyDbQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DatabaseKey,
        [Parameter(Mandatory = $true)][string]$Sql,
        [object[]]$Params = @(),
        [string]$Endpoint = "",
        [string]$Token = "",
        [int]$TimeoutSec = 30,
        [hashtable]$ExtraBody = @{},
        [string]$ConfigPath = ""
    )

    [void](Test-ReadOnlySql -Sql $Sql)

    $resolvedEndpoint = Resolve-DogOpenProcEndpoint -Endpoint $Endpoint -DatabaseKey $DatabaseKey -ConfigPath $ConfigPath

    $response = Invoke-DogOpenProc `
        -DatabaseKey $DatabaseKey `
        -Sql $Sql `
        -Params $Params `
        -Endpoint $resolvedEndpoint `
        -Token $Token `
        -TimeoutSec $TimeoutSec `
        -ExtraBody $ExtraBody `
        -ConfigPath $ConfigPath

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
    param([Parameter(Mandatory = $true)][object]$QueryResult)

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
    Get-DogOpenProcConfig, `
    Resolve-DogOpenProcEndpoint, `
    Resolve-DogOpenProcToken, `
    Convert-DogOpenProcResponseRows, `
    Invoke-DogOpenProc, `
    Invoke-ReadOnlyDbQuery, `
    Get-FirstDbQueryRow
