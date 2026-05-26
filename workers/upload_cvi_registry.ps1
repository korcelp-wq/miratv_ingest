$body = @{
    token  = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
    db     = "PCDE_memory"
    sql    = "INSERT INTO pcde_procedure_registry (process_name, domain, topic, unit_type, source_db, source_table, provenance, created_at, status, error_count, vector_count) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);"
    params = @(
        "cvi_registry_instructions",
        "governance",
        "cvi_access",
        "guide",
        "lake_knowledge",
        "dog_open.php",
        "How to use Dog_open.php for direct, governed DB access. POST JSON: token, db, sql, params. SQL must be parameterized. All actions are logged and auditable.",
        "2026-02-02T14:10:00Z",
        "completed",
        "0",
        "1"
    )
} | ConvertTo-Json -Depth 5

$response = Invoke-RestMethod -Method Post -Uri "https://miratv.club/_workers/api/series/dog_open.php" -ContentType 'application/json' -Body $body
Write-Host $response | ConvertTo-Json -Depth 10
