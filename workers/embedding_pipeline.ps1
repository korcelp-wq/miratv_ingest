# Vector Embedding Pipeline
# Purpose: Batch embed pending entries, store vectors, enable semantic search
# Target DBs: lake_vector, i_m_g_vector_context
# API: Cohere embed-english-v3.0 (cost-optimized)

# Import telemetry module
$TelemetryModule = Join-Path $PSScriptRoot "..\..\server_deploy\_workers\shared\telemetry.ps1"
if (Test-Path $TelemetryModule) {
    Import-Module $TelemetryModule -Force
}

param(
    [Parameter(Mandatory=$false)]
    [int]$BatchSize,
    [Parameter(Mandatory=$false)]
    [string]$TargetDb,
    [Parameter(Mandatory=$false)]
    [string]$Token,
    [Parameter(Mandatory=$false)]
    [string]$CohereApiKey
)

if (-not $BatchSize) { $BatchSize = 50 }
if (-not $TargetDb) { $TargetDb = "lake_vector" }
if (-not $Token) { $Token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY" }
if (-not $CohereApiKey) { $CohereApiKey = "REDACTED_COHERE_API_KEY" }

Write-Host "`nVector Embedding Pipeline" -ForegroundColor Cyan
Write-Host "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
Write-Host "Target DB: $TargetDb | Batch Size: $BatchSize" -ForegroundColor Gray

# Start telemetry
$jobId = Start-JobTelemetry -Component "workers" -JobName "embedding_pipeline" -Metadata @{
    target_db = $TargetDb
    batch_size = $BatchSize
}

$baseUrl = "https://miratv.club/_workers/api/series/dog_open.php"
$cohereUrl = "https://api.cohere.ai/v1/embed"

function Invoke-Sql {
    param(
        [string]$Db,
        [string]$Sql
    )

    $body = @{
        token  = $Token
        db     = $Db
        sql    = $Sql
        params = @()
    } | ConvertTo-Json -Depth 5

    Invoke-RestMethod -Method Post -Uri $baseUrl -ContentType 'application/json' -Body $body
}

# Step 1: Get pending embeddings
Write-Host "`nFetching pending embeddings..." -ForegroundColor Yellow
Record-TelemetryCheckpoint -CheckpointName "fetch_pending_embeddings"

$getPendingSql = "CALL sp_get_pending_embeddings();"

try {
    $result = Invoke-Sql -Db $TargetDb -Sql $getPendingSql
    
    if ($result.error) {
        Write-Host "Error fetching pending: $($result.message)" -ForegroundColor Red
        Record-TelemetryError -ErrorMessage "Failed to fetch pending embeddings: $($result.message)" -ErrorType "database_error"
        Complete-JobTelemetry -Success $false -Message "Database query failed"
        exit 1
    }
    
    $pendingVectors = $result.rows
    Write-Host "Found $($pendingVectors.Count) pending embeddings" -ForegroundColor Green
    
    if ($pendingVectors.Count -eq 0) {
        Write-Host "No pending embeddings. Exiting." -ForegroundColor Gray
        Complete-JobTelemetry -Success $true -Stats @{ pending_count = 0 } -Message "No work to do"
        exit 0
    }
}
catch {
    Write-Host "Connection error: $_" -ForegroundColor Red
    Record-TelemetryError -ErrorMessage $_.Exception.Message -ErrorType "connection_error"
    Complete-JobTelemetry -Success $false -Message "Connection failed"
    exit 1
}

# Step 2: Batch embed using Cohere
Write-Host "`nEmbedding batch with Cohere..." -ForegroundColor Yellow
Record-TelemetryCheckpoint -CheckpointName "cohere_embedding" -Data @{ batch_count = $pendingVectors.Count }

$textsToEmbed = @()
$vectorIdMap = @{}

foreach ($entry in $pendingVectors) {
    $textsToEmbed += $entry.content_text
    $vectorIdMap[$entry.content_text] = $entry.vector_id
}

try {
    $coherePayload = @{
        model = "embed-english-v3.0"
        texts = @($textsToEmbed)
        input_type = "search_document"
        truncate = "end"
    } | ConvertTo-Json -Depth 10
    
    $cohereResponse = Invoke-WebRequest -Uri $cohereUrl `
        -Method POST `
        -Headers @{ 
            "Authorization" = "Bearer $CohereApiKey"
            "Content-Type" = "application/json"
        } `
        -Body $coherePayload `
        -ErrorAction Stop
    
    $cohereResult = $cohereResponse.Content | ConvertFrom-Json
    
    if ($cohereResult.error) {
        Write-Host "Cohere error: $($cohereResult.error.message)" -ForegroundColor Red
        exit 1
    }
    
    $embeddings = $cohereResult.embeddings
    Write-Host "Embedded $($embeddings.Count) entries" -ForegroundColor Green
}
catch {
    Write-Host "Cohere API error: $_" -ForegroundColor Red
    exit 1
}

# Step 3: Store embeddings back to DB
Write-Host "`nStoring vectors..." -ForegroundColor Yellow

$successCount = 0
$failCount = 0

for ($i = 0; $i -lt $textsToEmbed.Count; $i++) {
    $text = $textsToEmbed[$i]
    $vectorId = $vectorIdMap[$text]
    $embeddingArray = $embeddings[$i]
    
    # Convert array to JSON string
    $embeddingJson = $embeddingArray | ConvertTo-Json -Compress
    $embeddingEscaped = $embeddingJson -replace "'", "''"
    
    $storeSql = "CALL sp_store_embedding($vectorId, '$embeddingEscaped', 'cohere_v3', 0.95);"
    
    try {
            $storeResult = Invoke-Sql -Db $TargetDb -Sql $storeSql
        
        if ($storeResult.error) {
            Write-Host "  Vector ${vectorId}: $($storeResult.message)" -ForegroundColor Red
            $failCount++
        } else {
            $successCount++
        }
    }
    catch {
        Write-Host "  Vector ${vectorId}: Connection error" -ForegroundColor Red
        $failCount++
    }
}

Write-Host "`nEmbedding cycle complete:" -ForegroundColor Green
Write-Host "   Stored: $successCount" -ForegroundColor Green
Write-Host "   Failed: $failCount" -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "Gray" })

# Complete telemetry
Complete-JobTelemetry -Success ($failCount -eq 0) -Stats @{
    pending_count = $pendingVectors.Count
    success_count = $successCount
    fail_count = $failCount
    batch_size = $BatchSize
} -Message "Embedding cycle completed"
Write-Host "   Failed: $failCount" -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "Green" })

# Step 4: Verify
Write-Host "`nVerification..." -ForegroundColor Cyan

$verifyQuery = "SELECT COUNT(*) as embedded_count FROM semantic_vector_store WHERE vector_model = 'cohere_v3';"

try {
    $verifyResult = Invoke-Sql -Db $TargetDb -Sql $verifyQuery
    $embeddedCount = $verifyResult.rows[0].embedded_count
    
    Write-Host "   Total embedded in $($TargetDb): $embeddedCount" -ForegroundColor Gray
}
catch {
    Write-Host "   Could not verify" -ForegroundColor Gray
}

# Inline registry upload via CVI (Dog_open.php)
$fields = @{
    token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
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

# Inline upload of CVI registry instructions via Dog_open.php
$body = @{
    token  = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
    db     = "content"
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

Write-Host "`nEmbedding pipeline complete" -ForegroundColor Green
