# Smart Governance Learner
$token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$endpoint = "https://miratv.club/_workers/api/series/dog_open.php"

# Function to run SQL
function Run-SQL {
    param([string]$Sql)
    $body = @{ token = $token; db = "pcde_memory"; sql = $Sql; params = @() } | ConvertTo-Json
    try { return Invoke-RestMethod -Uri $endpoint -Method Post -Body $body -ContentType "application/json" }
    catch { return $null }
}

# 1. Check for new failures to learn from
$failures = Run-SQL "SELECT COUNT(*) as count FROM pcde_procedure_failure WHERE created_at > DATE_SUB(NOW(), INTERVAL 1 HOUR)"
if ($failures.rows[0].count -gt 0) {
    $learning = "Detected $($failures.rows[0].count) new failures in the last hour"
    Run-Sql "INSERT INTO pcde_ai_memory (agent_name, memory_type, key_data, confidence, created_at) VALUES ('learner', 'discovery', '$learning', 0.85, NOW())"
}

# 2. Check working memory trends
$active = Run-SQL "SELECT COUNT(*) as count FROM pcde_working_memory WHERE expires_at > NOW()"
if ($active.rows[0].count -gt 0) {
    $learning = "Currently tracking $($active.rows[0].count) active working memory sessions"
    Run-Sql "INSERT INTO pcde_ai_memory (agent_name, memory_type, key_data, confidence, created_at) VALUES ('learner', 'observation', '$learning', 0.9, NOW())"
}

# 3. Log the run
Run-Sql "INSERT INTO pcde_working_memory (session_id, slot_key, slot_value, value_type, expires_at) VALUES ('learner', 'last_smart_run', '$(Get-Date)', 'string', DATE_ADD(NOW(), INTERVAL 1 DAY))"

Write-Host "✅ Smart Learner ran at $(Get-Date)"