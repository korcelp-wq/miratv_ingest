cd C:\miratv_ingest\dashboard
.\Query.ps1 @"
SELECT memory_id, LEFT(key_data, 100) as preview, confidence 
FROM pcde_ai_memory 
ORDER BY confidence DESC 
LIMIT 25
"@