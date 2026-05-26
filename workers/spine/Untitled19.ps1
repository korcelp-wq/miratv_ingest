.\Query.ps1 @"
SELECT p1.procedure_name, p1.source_path as keep, p2.source_path as delete
FROM pcde_procedure_registry p1
JOIN pcde_procedure_registry p2 
WHERE p1.procedure_name = p2.procedure_name
  AND p1.procedure_id < p2.procedure_id
  AND p1.source_path LIKE 'https://miratv.club/%'
  AND p2.source_path NOT LIKE 'https://miratv.club/%'
LIMIT 20
"@