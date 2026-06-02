# MasterControlDb.psm1
# Shared DB logging helpers for MiraTV Master Control.
# Primary path: worker/app -> mc_* database tables.
# Debug files remain optional/fallback artifacts.

Set-StrictMode -Version Latest

function ConvertTo-McColumnName {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Name)

    $col = $Name.Trim()
    $col = $col -replace '[^a-zA-Z0-9_]', '_'
    $col = $col.ToLowerInvariant()

    if ([string]::IsNullOrWhiteSpace($col)) {
        $col = "unnamed_column"
    }

    return $col
}

function ConvertTo-McSqlIdentifier {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Name)

    $tick = [char]96
    $tickText = [string]$tick
    return $tickText + $Name.Replace($tickText, ($tickText + $tickText)) + $tickText
}

function ConvertTo-McSqlLiteral {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return "NULL"
    }

    if ($Value -is [bool]) {
        if ($Value) { return "1" }
        return "0"
    }

    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or
        $Value -is [decimal] -or $Value -is [double] -or $Value -is [single]) {
        return ([string]$Value)
    }

    if ($Value -is [datetime]) {
        return "'" + $Value.ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss") + "'"
    }

    if ($Value -is [System.Array] -or $Value.GetType().Name -eq "PSCustomObject") {
        $Value = ($Value | ConvertTo-Json -Depth 20 -Compress)
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return "NULL"
    }

    $text = $text.Replace("\", "\\")
    $text = $text.Replace("'", "''")

    return "'" + $text + "'"
}

function ConvertTo-McTableNameFromPattern {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$FilePattern)

    $name = $FilePattern
    $name = $name -replace '_TIMESTAMP', ''
    $name = $name -replace '\.json$', ''
    $name = $name -replace '\.csv$', ''
    $name = $name -replace '[^a-zA-Z0-9_]', '_'
    $name = $name.ToLowerInvariant()

    return "mc_$name"
}

function New-McSourceMeta {
    [CmdletBinding()]
    param(
        [string]$SourceFilePath = "",
        [string]$SourceFilePattern = "",
        [string]$SourceFileSha256 = "",
        [string]$SourceFileLastWriteUtc = ""
    )

    $sourceFileName = ""
    if (-not [string]::IsNullOrWhiteSpace($SourceFilePath)) {
        try { $sourceFileName = Split-Path -Path $SourceFilePath -Leaf } catch { $sourceFileName = "" }
    }

    return [ordered]@{
        source_file_path = $SourceFilePath
        source_file_name = $sourceFileName
        source_file_pattern = $SourceFilePattern
        source_file_sha256 = $SourceFileSha256
        source_file_last_write_utc = $SourceFileLastWriteUtc
    }
}

function New-McInsertSql {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$TableName,
        [Parameter(Mandatory=$true)][hashtable]$Values,
        [string]$SchemaName = "xpdgxfsp_content"
    )

    $columns = New-Object System.Collections.Generic.List[string]
    $literals = New-Object System.Collections.Generic.List[string]

    foreach ($key in ($Values.Keys | Sort-Object)) {
        $columnName = ConvertTo-McColumnName -Name ([string]$key)
        $columns.Add((ConvertTo-McSqlIdentifier -Name $columnName))
        $literals.Add((ConvertTo-McSqlLiteral -Value $Values[$key]))
    }

    $schemaSql = ConvertTo-McSqlIdentifier -Name $SchemaName
    $tableSql = ConvertTo-McSqlIdentifier -Name $TableName

    return "INSERT INTO $schemaSql.$tableSql (" + ($columns -join ", ") + ") VALUES (" + ($literals -join ", ") + ");"
}

function Write-McTableRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$TableName,
        [Parameter(Mandatory=$true)][hashtable]$Values,
        [string]$SchemaName = "xpdgxfsp_content",
        [string]$DatabaseKey = "content",
        [switch]$PreviewOnly
    )

    $sql = New-McInsertSql -TableName $TableName -Values $Values -SchemaName $SchemaName

    if ($PreviewOnly) {
        return [pscustomobject]@{
            status = "preview"
            table_name = $TableName
            sql = $sql
            rows_affected = 0
        }
    }

    if (-not (Get-Command Invoke-DogOpenProc -ErrorAction SilentlyContinue)) {
        throw "Invoke-DogOpenProc is not available. Import tools\common\DbQuery.psm1 before writing Master Control rows."
    }

    $result = Invoke-DogOpenProc -DatabaseKey $DatabaseKey -Sql $sql -TimeoutSec 120

    return [pscustomobject]@{
        status = "pass"
        table_name = $TableName
        sql = $sql
        rows_affected = if ($result.PSObject.Properties.Name -contains "rows_affected") { $result.rows_affected } else { $null }
        raw_result = $result
    }
}

function Merge-McValues {
    [CmdletBinding()]
    param(
        [hashtable]$Primary,
        [hashtable]$Secondary
    )

    $values = @{}

    if ($Secondary) {
        foreach ($key in $Secondary.Keys) { $values[$key] = $Secondary[$key] }
    }

    if ($Primary) {
        foreach ($key in $Primary.Keys) { $values[$key] = $Primary[$key] }
    }

    return $values
}

function Write-McProviderSnapshotSpineSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][hashtable]$Summary,
        [hashtable]$SourceMeta = @{},
        [switch]$PreviewOnly
    )

    $values = Merge-McValues -Primary $Summary -Secondary $SourceMeta

    return Write-McTableRow `
        -TableName "mc_provider_snapshot_spine_runner_summary" `
        -Values $values `
        -PreviewOnly:$PreviewOnly
}

function Write-McProviderSnapshotSpineStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][hashtable]$StepRow,
        [hashtable]$SourceMeta = @{},
        [switch]$PreviewOnly
    )

    $values = Merge-McValues -Primary $StepRow -Secondary $SourceMeta

    return Write-McTableRow `
        -TableName "mc_provider_snapshot_spine_runner_report" `
        -Values $values `
        -PreviewOnly:$PreviewOnly
}

function Write-McProviderSnapshotDeltaPlanSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][hashtable]$Summary,
        [hashtable]$SourceMeta = @{},
        [switch]$PreviewOnly
    )

    $values = Merge-McValues -Primary $Summary -Secondary $SourceMeta

    return Write-McTableRow `
        -TableName "mc_provider_snapshot_delta_plan_summary" `
        -Values $values `
        -PreviewOnly:$PreviewOnly
}

function Write-McProviderSnapshotDeltaPlanRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][hashtable]$PlanRow,
        [hashtable]$SourceMeta = @{},
        [switch]$PreviewOnly
    )

    $values = Merge-McValues -Primary $PlanRow -Secondary $SourceMeta

    return Write-McTableRow `
        -TableName "mc_provider_snapshot_delta_plan" `
        -Values $values `
        -PreviewOnly:$PreviewOnly
}


function Write-McProviderSnapshotGovernedImportRunnerSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][hashtable]$Summary,
        [hashtable]$SourceMeta = @{},
        [switch]$PreviewOnly
    )

    $values = Merge-McValues -Primary $Summary -Secondary $SourceMeta

    return Write-McTableRow `
        -TableName "mc_provider_snapshot_governed_import_runner_summary" `
        -Values $values `
        -PreviewOnly:$PreviewOnly
}

function Write-McProviderSnapshotGovernedImportRunnerRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][hashtable]$RunnerRow,
        [hashtable]$SourceMeta = @{},
        [switch]$PreviewOnly
    )

    $values = Merge-McValues -Primary $RunnerRow -Secondary $SourceMeta

    return Write-McTableRow `
        -TableName "mc_provider_snapshot_governed_import_runner" `
        -Values $values `
        -PreviewOnly:$PreviewOnly
}


function Write-McVodStreamsDeltaImportPreviewSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][hashtable]$Summary,
        [hashtable]$SourceMeta = @{},
        [switch]$PreviewOnly
    )

    $values = Merge-McValues -Primary $Summary -Secondary $SourceMeta

    return Write-McTableRow `
        -TableName "mc_vod_streams_delta_import_preview_summary" `
        -Values $values `
        -PreviewOnly:$PreviewOnly
}

function Write-McVodStreamsDeltaImportPreviewRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][hashtable]$PreviewRow,
        [hashtable]$SourceMeta = @{},
        [switch]$PreviewOnly
    )

    $values = Merge-McValues -Primary $PreviewRow -Secondary $SourceMeta

    return Write-McTableRow `
        -TableName "mc_vod_streams_delta_import_preview" `
        -Values $values `
        -PreviewOnly:$PreviewOnly
}

function Get-McDashboardCardSql {
    [CmdletBinding()]
    param()

    return @"
SELECT *
FROM (
  SELECT
    'spine_runner' AS card,
    status,
    component AS lane_or_component,
    provider_label,
    CAST(step_count AS CHAR) AS primary_count,
    CAST(fail_count AS CHAR) AS secondary_count,
    'steps / failures' AS metric_label,
    generated_at_utc AS event_time,
    report_csv AS artifact
  FROM xpdgxfsp_content.mc_provider_snapshot_spine_runner_summary
  ORDER BY ingest_id DESC
  LIMIT 1
) a

UNION ALL

SELECT *
FROM (
  SELECT
    'delta_plan' AS card,
    status,
    component AS lane_or_component,
    provider_label,
    CAST(snapshot_summary_count AS CHAR) AS primary_count,
    CAST(db_writes AS CHAR) AS secondary_count,
    'snapshots / db_writes' AS metric_label,
    generated_at_utc AS event_time,
    plan_csv AS artifact
  FROM xpdgxfsp_content.mc_provider_snapshot_delta_plan_summary
  ORDER BY ingest_id DESC
  LIMIT 1
) b

UNION ALL

SELECT *
FROM (
  SELECT
    'governed_import_runner' AS card,
    status,
    selected_lane AS lane_or_component,
    provider_label,
    CAST(would_write_count AS CHAR) AS primary_count,
    CAST(actual_write_count AS CHAR) AS secondary_count,
    'would_write / actual_write' AS metric_label,
    NULL AS event_time,
    summary_json AS artifact
  FROM xpdgxfsp_content.mc_provider_snapshot_governed_import_runner_summary
  ORDER BY ingest_id DESC
  LIMIT 1
) c

UNION ALL

SELECT *
FROM (
  SELECT
    'vod_preview' AS card,
    status,
    lane_key AS lane_or_component,
    NULL AS provider_label,
    CAST(planned_import_count AS CHAR) AS primary_count,
    CAST(skipped_already_imported_count AS CHAR) AS secondary_count,
    'planned / skipped_imported' AS metric_label,
    NULL AS event_time,
    summary_json AS artifact
  FROM xpdgxfsp_content.mc_vod_streams_delta_import_preview_summary
  ORDER BY ingest_id DESC
  LIMIT 1
) d

UNION ALL

SELECT *
FROM (
  SELECT
    'vod_apply' AS card,
    status,
    selected_lane AS lane_or_component,
    NULL AS provider_label,
    CAST(actual_write_count AS CHAR) AS primary_count,
    CAST(rejected_count AS CHAR) AS secondary_count,
    'actual_write / rejected' AS metric_label,
    NULL AS event_time,
    summary_json AS artifact
  FROM xpdgxfsp_content.mc_vod_streams_delta_limited_apply_summary
  ORDER BY ingest_id DESC
  LIMIT 1
) e;
"@
}

Export-ModuleMember -Function `
    ConvertTo-McColumnName, `
    ConvertTo-McSqlIdentifier, `
    ConvertTo-McSqlLiteral, `
    ConvertTo-McTableNameFromPattern, `
    New-McSourceMeta, `
    New-McInsertSql, `
    Write-McTableRow, `
    Write-McProviderSnapshotSpineSummary, `
    Write-McProviderSnapshotSpineStep, `
    Write-McProviderSnapshotDeltaPlanSummary, `
    Write-McProviderSnapshotDeltaPlanRow, `
    Write-McProviderSnapshotGovernedImportRunnerSummary, `
    Write-McProviderSnapshotGovernedImportRunnerRow, `
    Write-McVodStreamsDeltaImportPreviewSummary, `
    Write-McVodStreamsDeltaImportPreviewRow, `
    Get-McDashboardCardSql
