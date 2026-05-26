param(
    [string]$Token = "YOUR_X_INGEST_TOKEN"
)

$fields = @{
    token = $Token
    table = "pcde_procedure_registry"
    process_name = "embedding_pipeline"
    domain = "content_enrichment"
    topic = "embedding_generation"
    unit_type = "vector_record"
    source_db = "lake_vector"
    source_table = "embedding_vectors"
    provenance = "Generated from c:\miratv_ingest\workers\embedding_pipeline.ps1"
    created_at = "2026-02-02T14:00:00Z"
    status = "completed"
    error_count = "0"
    vector_count = "1000"
}

$response = Invoke-WebRequest `
    -Uri "https://miratv.club/_workers/api/series/dog_open.php" `
    -Method Post `
    -Body $fields

Write-Host $response.Content
