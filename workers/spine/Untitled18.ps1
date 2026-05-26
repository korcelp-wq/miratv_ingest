# Fix /mnt/data/ paths to point to your live URLs
$fixMnt = @"
UPDATE pcde_procedure_registry 
SET source_path = REPLACE(source_path, '/mnt/data/', 'https://miratv.club/')
WHERE source_path LIKE '%/mnt/data/%'
"@
.\Query.ps1 -Sql $fixMnt

# Fix the malformed _workers paths
$fixWorkers = @"
UPDATE pcde_procedure_registry 
SET source_path = REPLACE(
    REPLACE(source_path, '_workerstv_ingest', '_workers'),
    '_workersv_ingest', '_workers'
)
WHERE source_path LIKE '%_workerstv_ingest%' OR source_path LIKE '%_workersv_ingest%'
"@
.\Query.ps1 -Sql $fixWorkers

# Fix paths with line breaks
$fixLineBreaks = @"
UPDATE pcde_procedure_registry 
SET source_path = REPLACE(source_path, '
', '')
WHERE source_path LIKE '%'||CHAR(10)||'%' OR source_path LIKE '%'||CHAR(13)||'%'
"@
.\Query.ps1 -Sql $fixLineBreaks