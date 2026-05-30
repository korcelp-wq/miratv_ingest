<#
.SYNOPSIS
  Safe database adapter for MiraTV governed import/apply gates.

.DESCRIPTION
  This module is intentionally conservative.

  Supported behavior:
    - Validate unsafe SQL patterns
    - Validate required parameters
    - Return dry-run preview result
    - Run explicit read-only schema checks through DbQuery.psm1 / dog_open_proc
    - Refuse apply mode unless a future explicit write implementation is promoted

  Safety model:
    - dry_run mode: no DB reads, no DB writes, no provider calls
    - schema_check mode: DB reads only when -AllowDbRead is explicitly passed
    - apply mode: still blocked; no DB writes implemented here
#>

Set-StrictMode -Version Latest

function Test-MiraDbSqlSafety {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Sql
    )

    $blockedPatterns = @(
        '\bDELETE\b',
        '\bDROP\b',
        '\bTRUNCATE\b',
        '\bALTER\b',
        '\bCREATE\b',
        '\bGRANT\b',
        '\bREVOKE\b',
        '\bLOAD_FILE\b',
        '\bINTO\s+OUTFILE\b',
        '\bINTO\s+DUMPFILE\b'
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
        [Parameter()]
        [hashtable]$Parameters,

        [Parameter()]
        [string[]]$RequiredParameterNames
    )

    if ($null -eq $Parameters) {
        $Parameters = @{}
    }

    if ($null -eq $RequiredParameterNames) {
        $RequiredParameterNames = @()
    }

    $missing = @()
    foreach ($name in $RequiredParameterNames) {
        if (-not $Parameters.ContainsKey($name)) {
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

function Get-MiraDbAdapterText {
    param(
        [object]$Object,
        [string]$Name,
        [string]$Default = ""
    )

    if ($null -eq $Object) { return $Default }

    $property = $Object.PSObject.Properties |
        Where-Object { $_.Name -ieq $Name } |
        Select-Object -First 1

    if ($null -eq $property -or $null -eq $property.Value) { return $Default }

    return [string]$property.Value
}

function Get-MiraDbSchemaKeyFound {
    param(
        [object[]]$IndexRows,
        [string]$RequiredUniqueKey
    )

    if ($null -eq $IndexRows) { return $false }
    if ([string]::IsNullOrWhiteSpace($RequiredUniqueKey)) { return $false }

    $uniqueIndexGroups = @($IndexRows |
        Where-Object { [string]$_.Non_unique -eq "0" } |
        Group-Object -Property Key_name)

    foreach ($group in $uniqueIndexGroups) {
        $keyColumns = @($group.Group |
            Sort-Object { [int]$_.Seq_in_index } |
            ForEach-Object { [string]$_.Column_name })

        if (($keyColumns -join "|") -eq $RequiredUniqueKey) {
            return $true
        }
    }

    return $false
}

function Invoke-MiraDbSchemaCheck {
    [CmdletBinding()]
    param(
        [string]$DatabaseKey = "content",
        [string]$TargetTable = "vod",
        [string[]]$RequiredColumns = @("provider", "provider_vod_id", "category_id", "title", "updated_at"),
        [string]$RequiredUniqueKey = "provider|provider_vod_id"
    )

    $modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) "common\DbQuery.psm1"
    if (-not (Test-Path -LiteralPath $modulePath)) {
        return [pscustomobject][ordered]@{
            status = "blocked"
            disposition = "blocked_schema_check_db_query_module_missing"
            mode = "schema_check"
            schema_valid = $false
            database_key = $DatabaseKey
            target_table = $TargetTable
            required_unique_key = $RequiredUniqueKey
            required_columns = ($RequiredColumns -join "|")
            missing_required_columns = ""
            key_found = $false
            db_reads = $false
            db_writes = $false
            provider_calls = $false
            rows_affected = 0
        }
    }

    Import-Module $modulePath -Force

    $columnQuery = "SHOW COLUMNS FROM $TargetTable;"
    $indexQuery = "SHOW INDEX FROM $TargetTable;"

    $columnEnvelope = Invoke-ReadOnlyDbQuery `
        -DatabaseKey $DatabaseKey `
        -Sql $columnQuery

    $indexEnvelope = Invoke-ReadOnlyDbQuery `
        -DatabaseKey $DatabaseKey `
        -Sql $indexQuery

    $columnRows = @($columnEnvelope[0].rows)
    $indexRows = @($indexEnvelope[0].rows)

    $columnsFound = @($columnRows | ForEach-Object { [string]$_.Field })
    $missingColumns = @($RequiredColumns | Where-Object { $_ -notin $columnsFound })
    $keyFound = Get-MiraDbSchemaKeyFound -IndexRows $indexRows -RequiredUniqueKey $RequiredUniqueKey

    $schemaValid = (@($missingColumns).Count -eq 0 -and $keyFound)

    $disposition = "schema_check_validated"
    $status = "pass"

    if (-not $schemaValid) {
        $disposition = "schema_check_completed_with_blocks"
        $status = "warning"
    }

    return [pscustomobject][ordered]@{
        status = $status
        disposition = $disposition
        mode = "schema_check"
        schema_valid = $schemaValid
        database_key = $DatabaseKey
        target_table = $TargetTable
        required_unique_key = $RequiredUniqueKey
        required_columns = ($RequiredColumns -join "|")
        missing_required_columns = ($missingColumns -join "|")
        key_found = $keyFound
        column_row_count = @($columnRows).Count
        index_row_count = @($indexRows).Count
        db_reads = $true
        db_writes = $false
        provider_calls = $false
        rows_affected = 0
    }
}

function Invoke-MiraDbQuerySafe {
    [CmdletBinding()]
    param(
        [ValidateSet("schema_check", "dry_run", "apply")]
        [string]$Mode = "dry_run",

        [Parameter()]
        [string]$Sql,

        [hashtable]$Parameters = @{},

        [string[]]$RequiredParameterNames = @(),

        [int]$Limit = 25,

        [switch]$AllowDbRead,

        [switch]$AllowDbWrite,

        [string]$DatabaseKey = "content",

        [string]$TargetTable = "vod",

        [string[]]$RequiredColumns = @("provider", "provider_vod_id", "category_id", "title", "updated_at"),

        [string]$RequiredUniqueKey = "provider|provider_vod_id"
    )

    if ($null -eq $Parameters) {
        $Parameters = @{}
    }

    if ($null -eq $RequiredParameterNames) {
        $RequiredParameterNames = @()
    }

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
                missing_parameters = ""
                rows_affected = 0
                db_reads = $false
                db_writes = $false
                provider_calls = $false
            }
        }

        $schemaResult = Invoke-MiraDbSchemaCheck `
            -DatabaseKey $DatabaseKey `
            -TargetTable $TargetTable `
            -RequiredColumns $RequiredColumns `
            -RequiredUniqueKey $RequiredUniqueKey

        return [pscustomobject][ordered]@{
            status = $schemaResult.status
            disposition = $schemaResult.disposition
            mode = $Mode
            sql_is_safe = $true
            sql_violations = ""
            parameters_valid = $true
            missing_parameters = ""
            schema_valid = $schemaResult.schema_valid
            database_key = $schemaResult.database_key
            target_table = $schemaResult.target_table
            required_unique_key = $schemaResult.required_unique_key
            required_columns = $schemaResult.required_columns
            missing_required_columns = $schemaResult.missing_required_columns
            key_found = $schemaResult.key_found
            column_row_count = $schemaResult.column_row_count
            index_row_count = $schemaResult.index_row_count
            rows_affected = 0
            db_reads = $schemaResult.db_reads
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
                missing_parameters = ""
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
            missing_parameters = ""
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
        sql_violations = ""
        parameters_valid = $true
        missing_parameters = ""
        supplied_parameter_count = @($Parameters.Keys).Count
        limit = $Limit
        rows_affected = 0
        db_reads = $false
        db_writes = $false
        provider_calls = $false
    }
}

Export-ModuleMember -Function Test-MiraDbSqlSafety, Test-MiraDbRequiredParameters, Invoke-MiraDbQuerySafe, Invoke-MiraDbSchemaCheck
