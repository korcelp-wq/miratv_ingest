# Updated Master_Control37.ps1 (Phase 2 integrated)

param(
    [string]$UserQuestion
)

$ErrorActionPreference = 'Stop'

# Paths
$queryScript = "C:\miratv_ingest\dashboard\Query.ps1"
$rulesPath   = "C:\miratv_ingest\pcde_reasoning_rules.yaml"

# Build SQL call (you likely already do this dynamically)
$sql = "CALL pcde_long_term_memory_recall('$UserQuestion','definition',25)"

# Call Query.ps1 to get Ollama payload
$payload = & $queryScript `
    -Sql $sql `
    -UserQuestion $UserQuestion `
    -RulesPath $rulesPath `
    -BuildOllamaPayload

# Extract messages
$messages = $payload.messages

# Call Ollama
$ollamaBody = @{
    model = $payload.model
    messages = $messages
} | ConvertTo-Json -Depth 10

$response = Invoke-RestMethod `
    -Uri "http://localhost:11434/api/chat" `
    -Method Post `
    -Body $ollamaBody `
    -ContentType "application/json"

# Output final answer
$response
