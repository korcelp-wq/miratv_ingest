# Test AI with local resources
$token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$endpoint = "https://miratv.club/_workers/api/series/dog_open.php"

# Function to query your database
function Query-DB {
    param([string]$Sql)
    $body = @{ token = $token; db = "pcde_memory"; sql = $Sql; params = @() } | ConvertTo-Json
    return Invoke-RestMethod -Uri $endpoint -Method Post -Body $body -ContentType "application/json"
}

# Get some context from your AI memory
$context = Query-Db "SELECT key_data FROM pcde_ai_memory WHERE confidence > 0.9 LIMIT 3"
Write-Host "`n📚 Context from AI Memory:" -ForegroundColor Cyan
$context.rows | ForEach-Object { Write-Host "  - $($_.key_data)" }

# Build prompt with context
$prompt = @"
Based on this knowledge about MiraTV:
$($context.rows | ForEach-Object { "- $($_.key_data)" })

Answer this question: What is the EPG pipeline?
"@

# Send to Ollama
$body = @{
    model = "llama3.2:3b"
    prompt = $prompt
    stream = $false
} | ConvertTo-Json

Write-Host "`n🤔 Asking AI with context..." -ForegroundColor Yellow
$response = Invoke-RestMethod -Uri "http://localhost:11434/api/generate" `
    -Method Post `
    -Body $body `
    -ContentType "application/json"

Write-Host "`n🤖 AI Response:" -ForegroundColor Green
$response.response