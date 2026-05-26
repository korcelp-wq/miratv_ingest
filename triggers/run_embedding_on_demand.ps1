# On-demand embedding trigger (no scheduler)
# Usage:
#   run_embedding_on_demand.ps1 -TargetDb lake_vector -BatchSize 50
#   run_embedding_on_demand.ps1 -TargetDb i_m_g_vector_context -BatchSize 50

param(
    [Parameter(Mandatory=$false)]
    [string]$TargetDb = "lake_vector",

    [Parameter(Mandatory=$false)]
    [int]$BatchSize = 50
)

$script = "C:\miratv_ingest\workers\embedding_pipeline.ps1"

Write-Host "`nOn-demand embedding trigger" -ForegroundColor Cyan
Write-Host "Target DB: $TargetDb | Batch Size: $BatchSize" -ForegroundColor Gray

powershell.exe -ExecutionPolicy Bypass -File $script -TargetDb $TargetDb -BatchSize $BatchSize

Write-Host "`nOn-demand embedding complete" -ForegroundColor Green
