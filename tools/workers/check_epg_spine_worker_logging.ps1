<#
.SYNOPSIS
  Validate EPG spine worker logging.

.DESCRIPTION
  Checks that the DB logging objects exist and that latest EPG spine status is visible.
#>

[CmdletBinding()]
param(
    [string]$RepoRoot = "C:\miraTV_ingest_clean"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

cd $RepoRoot

Import-Module ".\tools\common\DbQuery.psm1" -Force

$Sql = @"
SELECT
  table_name
FROM information_schema.tables
WHERE table_schema = 'xpdgxfsp_content'
  AND table_name IN (
    'spine_worker_event_log',
    'v_spine_worker_latest_status',
    'v_spine_worker_epg_status'
  )
ORDER BY table_name;

SHOW PROCEDURE STATUS
WHERE Db = 'xpdgxfsp_content'
  AND Name = 'sp_record_spine_worker_event';

SELECT
  worker_key,
  stage_key,
  status,
  event_type,
  signal_key,
  disposition,
  event_at
FROM xpdgxfsp_content.v_spine_worker_epg_status;
"@

$Result = Invoke-DogOpenProc -DatabaseKey "content" -Sql $Sql -TimeoutSec 120

for ($i = 0; $i -lt $Result.rowsets.Count; $i++) {
    "===== ROWSET $($i + 1) ====="
    $Result.rowsets[$i] | Format-Table -AutoSize
}
