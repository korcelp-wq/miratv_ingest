# Run embeddings now (no scheduler)
param(
    [int]$BatchSize = 50
)

$script = "C:\miratv_ingest\workers\embedding_pipeline.ps1"

Write-Host "`nEmbedding now: lake_vector" -ForegroundColor Cyan
powershell.exe -ExecutionPolicy Bypass -File $script -TargetDb lake_vector -BatchSize $BatchSize

Write-Host "`nEmbedding now: i_m_g_vector_context" -ForegroundColor Cyan
powershell.exe -ExecutionPolicy Bypass -File $script -TargetDb i_m_g_vector_context -BatchSize $BatchSize

Write-Host "`nEmbedding runs complete" -ForegroundColor Green
