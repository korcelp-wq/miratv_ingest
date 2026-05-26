# Simple Governance Learner
$token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$endpoint = "https://miratv.club/_workers/api/series/dog_open.php"

# Log that we ran
$body = @{
    token = $token
    db = "pcde_memory"
    sql = "INSERT INTO pcde_working_memory (session_id, slot_key, slot_value, value_type, expires_at) VALUES ('learner', 'last_run', '$(Get-Date)', 'string', DATE_ADD(NOW(), INTERVAL 1 DAY))"
    params = @()
} | ConvertTo-Json

try {
    Invoke-RestMethod -Uri $endpoint -Method Post -Body $body -ContentType "application/json"
    Write-Host "✅ Learner ran at $(Get-Date)"
} catch {
    Write-Host "❌ Learner failed: $_"
}
