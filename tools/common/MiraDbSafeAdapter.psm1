<#
.SYNOPSIS
  Safe DB adapter skeleton for MiraTV governed workers.

.DESCRIPTION
  Contract-first adapter skeleton.

  This module intentionally supports dry-run behavior now and refuses real DB writes
  until a later explicit implementation step promotes it.

  Current supported behavior:
    - Validate unsafe SQL patterns
    - Validate required parameters
    - Return dry-run preview result
    - Return schema-check-not-implemented result without connecting
    - Refuse apply mode

  No DB connections.
  No DB reads.
  No DB writes.
  No provider calls.
#>

Set-StrictMode -Version Latest

function Test-MiraDbSqlSafety {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Sql
    )

    $blockedPatterns = @(
        '\bDELETE\b',
        '\bDROP\b',
        '\bTRUNCATE\b',
        '\bALTER\b',
        '\bCREATE\b',
        '\bGRANT\b',
        '\bREVOKE\b'
    )

    $violations = @()
    foreach ($pattern in $blockedPatterns) {
        if ($Sql -match $pattern) {
            $violations += $pattern
        }
    }

    return [pscustomobject][ordered]@{
        is_safe = (@($violations).Count -eq 0)
        violations = ($violations -join "|")
        db_reads = $false
        db_writes = $false
        provider_calls = $false
    }
}

function Test-MiraDbRequiredParameters {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Parameters,

        [Parameter(Mandatory = $true)]
        [string[]]$RequiredParameterNames
    )

    $missing = @()
    foreach ($name in $RequiredParameterNames) {
        if (-not $Parameters.ContainsKey($name)) {
            $missing += $name
            continue
        }

        $value = $Parameters[$name]
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
            $missing += $name
        }
    }

    return [pscustomobject][ordered]@{
        is_valid = (@($missing).Count -eq 0)
        missing_parameters = ($missing -join "|")
        required_parameter_count = @($RequiredParameterNames).Count
        supplied_parameter_count = @($Parameters.Keys).Count
        db_reads = $false
        db_writes = $false
        provider_calls = $false
    }
}

function Invoke-MiraDbQuerySafe {
    [CmdletBinding()]
    param(
        [ValidateSet("schema_check", "dry_run", "apply")]
        [string]$Mode = "dry_run",

        [Parameter(Mandatory = $true)]
        [string]$Sql,

        [hashtable]$Parameters = @{},

        [string[]]$RequiredParameterNames = @(),

        [int]$Limit = 25,

        [switch]$AllowDbRead,

        [switch]$AllowDbWrite
    )

    if ($Limit -lt 1) { $Limit = 1 }
    if ($Limit -gt 100) { $Limit = 100 }

    $sqlSafety = Test-MiraDbSqlSafety -Sql $Sql
    $parameterCheck = Test-MiraDbRequiredParameters -Parameters $Parameters -RequiredParameterNames $RequiredParameterNames

    if (-not $sqlSafety.is_safe) {
        return [pscustomobject][ordered]@{
            status = "blocked"
            disposition = "blocked_unsafe_sql"
            mode = $Mode
            sql_is_safe = $false
            sql_violations = $sqlSafety.violations
            parameters_valid = $parameterCheck.is_valid
            missing_parameters = $parameterCheck.missing_parameters
            rows_affected = 0
            db_reads = $false
            db_writes = $false
            provider_calls = $false
        }
    }

    if (-not $parameterCheck.is_valid) {
        return [pscustomobject][ordered]@{
            status = "blocked"
            disposition = "blocked_missing_required_parameters"
            mode = $Mode
            sql_is_safe = $true
            sql_violations = ""
            parameters_valid = $false
            missing_parameters = $parameterCheck.missing_parameters
            rows_affected = 0
            db_reads = $false
            db_writes = $false
            provider_calls = $false
        }
    }

    if ($Mode -eq "schema_check") {
        if (-not $AllowDbRead) {
            return [pscustomobject][ordered]@{
                status = "blocked"
                disposition = "blocked_schema_check_requires_explicit_db_read"
                mode = $Mode
                sql_is_safe = $true
                parameters_valid = $true
                rows_affected = 0
                db_reads = $false
                db_writes = $false
                provider_calls = $false
            }
        }

        return [pscustomobject][ordered]@{
            status = "blocked"
            disposition = "blocked_schema_check_db_adapter_not_implemented"
            mode = $Mode
            sql_is_safe = $true
            parameters_valid = $true
            rows_affected = 0
            db_reads = $false
            db_writes = $false
            provider_calls = $false
        }
    }

    if ($Mode -eq "apply") {
        if (-not $AllowDbWrite) {
            return [pscustomobject][ordered]@{
                status = "blocked"
                disposition = "blocked_apply_requires_explicit_db_write"
                mode = $Mode
                sql_is_safe = $true
                parameters_valid = $true
                rows_affected = 0
                db_reads = $false
                db_writes = $false
                provider_calls = $false
            }
        }

        return [pscustomobject][ordered]@{
            status = "blocked"
            disposition = "blocked_apply_db_adapter_not_implemented"
            mode = $Mode
            sql_is_safe = $true
            parameters_valid = $true
            rows_affected = 0
            db_reads = $false
            db_writes = $false
            provider_calls = $false
        }
    }

    return [pscustomobject][ordered]@{
        status = "pass"
        disposition = "dry_run_preview"
        mode = $Mode
        sql_is_safe = $true
        parameters_valid = $true
        supplied_parameter_count = @($Parameters.Keys).Count
        limit = $Limit
        rows_affected = 0
        db_reads = $false
        db_writes = $false
        provider_calls = $false
    }
}

Export-ModuleMember -Function Test-MiraDbSqlSafety, Test-MiraDbRequiredParameters, Invoke-MiraDbQuerySafe
