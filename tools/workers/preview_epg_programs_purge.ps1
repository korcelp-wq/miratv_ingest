[CmdletBinding()]
param(
    [string]$Environment = "dev",
    [string]$Provider = "default",
    [int]$RetentionHours = 48
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$WorkerName = "preview_epg_programs_purge"
$Component = "epg_programs_purge_preview"
$DatabaseKey = "content"

$RepoRoot = (Resolve-Path ".").Path
$Stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$RunId = "$WorkerName-$Stamp"

$OutDir = Join-Path $RepoRoot "runtime\reports\epg_programs_purge_preview"
$LogDir = Join-Path $RepoRoot "runtime\logs\epg_programs_purge_preview"

New-Item -ItemType Directory -Force $OutDir | Out-Null
New-Item -ItemType Directory -Force $LogDir | Out-Null

$SummaryPath = Join-Path $OutDir "epg_programs_purge_preview_summary_$Stamp.json"
$LogPath = Join-Path $LogDir "$WorkerName-$((Get-Date).ToUniversalTime().ToString('yyyyMMdd')).jsonl"

function Write-Event {
    param([hashtable]$Event)
    $Event.run_id = $RunId
    $Event.worker_name = $WorkerName
    $Event.component = $Component
    $Event.environment = $Environment
    $Event.provider = $Provider
    $Event.timestamp = (Get-Date).ToUniversalTime().ToString("o")
    ($Event | ConvertTo-Json -Depth 10 -Compress) | Add-Content -Path $LogPath -Encoding UTF8
}

function Invoke-ReadSql {
    param([string]$Sql)

    $modulePath = Join-Path $RepoRoot "tools\common\DbQuery.psm1"
    Import-Module $modulePath -Force
    return Invoke-DogOpenProc -DatabaseKey $DatabaseKey -Sql $Sql -TimeoutSec 60
}

$cutoffExpression = "DATE_SUB(NOW(), INTERVAL $RetentionHours HOUR)"

$sql = @"
SELECT
  COUNT(*) AS total_programs,
  MIN(start_time) AS oldest_start,
  MAX(end_time) AS newest_end,
  SUM(CASE WHEN end_time < $cutoffExpression THEN 1 ELSE 0 END) AS purge_candidate_count,
  MIN(CASE WHEN end_time < $cutoffExpression THEN start_time ELSE NULL END) AS purge_oldest_start,
  MAX(CASE WHEN end_time < $cutoffExpression THEN end_time ELSE NULL END) AS purge_newest_end
FROM epg_programs;
"@

Write-Event @{
    event_type = "job_started"
    status = "started"
    retention_hours = $RetentionHours
    db_writes = $false
    provider_calls = $false
}

$result = Invoke-ReadSql -Sql $sql
$row = @($result.rows)[0]

$summary = [pscustomobject][ordered]@{
    run_id = $RunId
    provider = $Provider
    retention_hours = $RetentionHours
    total_programs = [int64]$row.total_programs
    oldest_start = [string]$row.oldest_start
    newest_end = [string]$row.newest_end
    purge_candidate_count = [int64]$row.purge_candidate_count
    purge_oldest_start = [string]$row.purge_oldest_start
    purge_newest_end = [string]$row.purge_newest_end
    db_writes = $false
    provider_calls = $false
    status = "pass"
}

$summary | ConvertTo-Json -Depth 8 | Set-Content -Path $SummaryPath -Encoding UTF8

Write-Event @{
    event_type = "job_completed"
    status = "pass"
    purge_candidate_count = $summary.purge_candidate_count
    db_writes = $false
    provider_calls = $false
    summary_path = $SummaryPath
}

Write-Output "OK: EPG purge preview completed. candidates=$($summary.purge_candidate_count) retention_hours=$RetentionHours summary=$SummaryPath"
