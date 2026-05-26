# Remove exact duplicates keeping the oldest
.\Query.ps1 @"
DELETE m1 FROM pcde_ai_memory m1
INNER JOIN pcde_ai_memory m2 
WHERE m1.memory_id > m2.memory_id 
  AND m1.key_data = m2.key_data
"@

# Check the new counts
.\Query.ps1 "SELECT COUNT(*) as total FROM pcde_ai_memory"