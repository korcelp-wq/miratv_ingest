# validate_master_control_db_module.ps1
# Validates MasterControlDb.psm1 without writing rows by default.

[CmdletBinding()]
param(
    [switch]$WriteTestRow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $RepoRoot

Import-Module ".\tools\common\DbQuery.psm1" -Force
Import-Module ".\tools\common\MasterControlDb.psm1" -Force

$preview = Write-McProviderSnapshotSpineSummary `
    -PreviewOnly `
    -SourceMeta (New-McSourceMeta -SourceFilePath "C:\miraTV_ingest_clean\runtime\debug\module_self_test.json" -SourceFilePattern "module_self_test") `
    -Summary @{
        run_id = "module-self-test-preview"
        worker_name = "validate_master_control_db_module"
        component = "master_control_db"
        environment = "dev"
        provider_calls = $false
        db_imported = $false
        db_writes = $false
        mac_user_id = 6
        provider_label = "self_test"
        step_count = 1
        executed_count = 1
        pass_count = 1
        fail_count = 0
        status = "preview"
        report_csv = "C:\miraTV_ingest_clean\runtime\debug\module_self_test.csv"
        generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    }

if ($preview.sql -match '\$TableName' -or $preview.sql -match '\$Col') {
    throw "Preview SQL contains unresolved generator variables."
}

if ($preview.sql -notmatch 'C:\\\\miraTV_ingest_clean') {
    throw "Preview SQL does not appear to preserve escaped Windows path backslashes."
}

$cardSql = Get-McDashboardCardSql
$result = Invoke-DogOpenProc -DatabaseKey "content" -Sql $cardSql -TimeoutSec 120

if ($null -eq $result.rows -or @($result.rows).Count -lt 1) {
    throw "Dashboard card SQL returned no rows."
}

$writeResult = $null

if ($WriteTestRow) {
    $writeResult = Write-McProviderSnapshotSpineSummary `
        -SourceMeta (New-McSourceMeta -SourceFilePath "C:\miraTV_ingest_clean\runtime\debug\module_self_test.json" -SourceFilePattern "module_self_test") `
        -Summary @{
            run_id = "module-self-test-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
            worker_name = "validate_master_control_db_module"
            component = "master_control_db"
            environment = "dev"
            provider_calls = $false
            db_imported = $false
            db_writes = $true
            mac_user_id = 6
            provider_label = "self_test"
            step_count = 1
            executed_count = 1
            pass_count = 1
            fail_count = 0
            status = "pass"
            report_csv = "C:\miraTV_ingest_clean\runtime\debug\module_self_test.csv"
            generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        }
}

[pscustomobject]@{
    status = "pass"
    module_loaded = $true
    preview_sql_ok = $true
    dashboard_rows = @($result.rows).Count
    write_test_row = [bool]$WriteTestRow
    write_result_status = if ($writeResult) { $writeResult.status } else { "" }
}
