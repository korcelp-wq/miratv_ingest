# MiraTV: Create placeholder routines in all databases using short names
$dbs = @('content','ip','ops','lake_vector','i_m_g_vector_context','inhibitor_govenor_matrix','callosum_matrix','lake_knowledge','cortex')
$routines = @(
  'check_series_1510_data','check_series_exists','cleanup_old_series','count_seasons_episodes','create_reprocess_script','execute_php_code','exec_sql','query_content_db','query_ops_db','query_recent_series_data','query_series_recent','query_series_with_data','record_batch_complete','record_lake_signal','record_ops_event','reset_series_for_reprocess','schema_snapshot_ingestion','sp_ingest_pipeline_health','test_correct_key'
)
foreach ($db in $dbs) {
  foreach ($routine in $routines) {
    $sql = "CREATE PROCEDURE $routine() BEGIN END;"
    try {
      .\Query.ps1 -Db $db -Sql $sql
      Write-Host "[$db] $routine created" -ForegroundColor Green
    } catch {
      Write-Host "[$db] $routine failed: $_" -ForegroundColor Yellow
    }
  }
}