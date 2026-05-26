# Smart Governance Learner - Enhanced Edition
$token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$endpoint = "https://miratv.club/_workers/api/series/dog_open.php"

# Function to run SQL
function Run-SQL {
    param([string]$Sql)
    $body = @{ token = $token; db = "pcde_memory"; sql = $Sql; params = @() } | ConvertTo-Json
    try { 
        $response = Invoke-RestMethod -Uri $endpoint -Method Post -Body $body -ContentType "application/json"
        return $response
    }
    catch { return $null }
}

# Function to add learning
function Add-Learning {
    param([string]$Discovery, [float]$Confidence)
    Run-Sql "INSERT INTO pcde_ai_memory (agent_name, memory_type, key_data, confidence, created_at) VALUES ('learner', 'discovery', '$Discovery', $Confidence, NOW())"
    Write-Host "  ✅ Learned: $Discovery" -ForegroundColor Green
}

Write-Host "`n🔍 AI Learner Scanning..." -ForegroundColor Cyan

# ------------------------------------------------------------
# ROUTINE 1: Pattern Detection - Repeated Failures
# ------------------------------------------------------------
$pattern = Run-SQL @"
SELECT 
    error_type,
    COUNT(*) as frequency,
    MIN(created_at) as first_seen,
    MAX(created_at) as last_seen
FROM pcde_procedure_failure 
WHERE created_at > DATE_SUB(NOW(), INTERVAL 7 DAY)
GROUP BY error_type
HAVING frequency > 3
ORDER BY frequency DESC
"@

if ($pattern.rows -and $pattern.rows.Count -gt 0) {
    foreach ($p in $pattern.rows) {
        $discovery = "Pattern detected: '$($p.error_type)' occurred $($p.frequency) times in the last week"
        Add-Learning -Discovery $discovery -Confidence 0.88
    }
}

# ------------------------------------------------------------
# ROUTINE 2: Success Pattern Recognition
# ------------------------------------------------------------
$success = Run-SQL @"
SELECT 
    procedure_name,
    AVG(confidence) as avg_confidence,
    COUNT(*) as learnings
FROM pcde_ai_memory 
WHERE confidence > 0.9
GROUP BY procedure_name
HAVING COUNT(*) > 2
"@

if ($success.rows -and $success.rows.Count -gt 0) {
    foreach ($s in $success.rows) {
        $discovery = "High-confidence cluster: $($s.learnings) reliable learnings about '$($s.procedure_name)' (avg conf: $($s.avg_confidence))"
        Add-Learning -Discovery $discovery -Confidence 0.92
    }
}

# ------------------------------------------------------------
# ROUTINE 3: Anomaly Detection - Unusual Confidence Drops
# ------------------------------------------------------------
$anomaly = Run-SQL @"
SELECT 
    m1.key_data,
    m1.confidence as old_conf,
    m2.confidence as new_conf,
    ABS(m1.confidence - m2.confidence) as drop
FROM pcde_ai_memory m1
JOIN pcde_ai_memory m2 ON m1.key_data = m2.key_data
WHERE m1.created_at < DATE_SUB(NOW(), INTERVAL 1 DAY)
  AND m2.created_at > DATE_SUB(NOW(), INTERVAL 1 HOUR)
  AND m2.confidence < m1.confidence * 0.7
"@

if ($anomaly.rows -and $anomaly.rows.Count -gt 0) {
    foreach ($a in $anomaly.rows) {
        $discovery = "⚠️ Confidence anomaly: Previous belief degraded from $($a.old_conf) to $($a.new_conf)"
        Add-Learning -Discovery $discovery -Confidence 0.75
    }
}

# ------------------------------------------------------------
# ROUTINE 4: Working Memory Cleanup (Auto-maintenance)
# ------------------------------------------------------------
$cleaned = Run-SQL "DELETE FROM pcde_working_memory WHERE expires_at < NOW()"
if ($cleaned.affected -and $cleaned.affected -gt 0) {
    Write-Host "  🧹 Cleaned up $($cleaned.affected) expired working memory entries" -ForegroundColor Yellow
}

# ------------------------------------------------------------
# ROUTINE 5: Learning Progress Tracking
# ------------------------------------------------------------
$progress = Run-SQL @"
SELECT 
    COUNT(*) as total_learnings,
    AVG(confidence) as avg_confidence,
    MAX(created_at) as latest
FROM pcde_ai_memory
WHERE agent_name = 'learner'
  AND created_at > DATE_SUB(NOW(), INTERVAL 1 DAY)
"@

if ($progress.rows) {
    $p = $progress.rows[0]
    $discovery = "Learning progress: $($p.total_learnings) new insights today, avg confidence $($p.avg_confidence)"
    Add-Learning -Discovery $discovery -Confidence 0.98
}

# ------------------------------------------------------------
# ROUTINE 6: Weekly Summary (runs only on Sundays)
# ------------------------------------------------------------
if ((Get-Date).DayOfWeek -eq 'Sunday') {
    $weekly = Run-SQL @"
    SELECT 
        DATE(created_at) as day,
        COUNT(*) as insights
    FROM pcde_ai_memory
    WHERE created_at > DATE_SUB(NOW(), INTERVAL 7 DAY)
    GROUP BY DATE(created_at)
    ORDER BY day
"@
    
    if ($weekly.rows) {
        $summary = "Weekly summary: " + ($weekly.rows | ForEach-Object { "$($_.day): $($_.insights)" }) -join ", "
        Add-Learning -Discovery $summary -Confidence 0.95
    }
}

# ------------------------------------------------------------
# ROUTINE 7: Correlation Detection - What failures lead to what learnings?
# ------------------------------------------------------------
$correlations = Run-SQL @"
SELECT 
    f.error_type,
    COUNT(DISTINCT a.id) as learnings_generated
FROM pcde_procedure_failure f
LEFT JOIN pcde_ai_memory a ON a.key_data LIKE CONCAT('%', f.error_type, '%')
WHERE f.created_at > DATE_SUB(NOW(), INTERVAL 3 DAY)
GROUP BY f.error_type
HAVING learnings_generated > 0
"@

if ($correlations.rows -and $correlations.rows.Count -gt 0) {
    foreach ($c in $correlations.rows) {
        $discovery = "Correlation: '$($c.error_type)' failures generated $($c.learnings_generated) new learnings"
        Add-Learning -Discovery $discovery -Confidence 0.82
    }
}

# Log the run
Run-Sql "INSERT INTO pcde_working_memory (session_id, slot_key, slot_value, value_type, expires_at) VALUES ('learner', 'last_enhanced_run', '$(Get-Date)', 'string', DATE_ADD(NOW(), INTERVAL 1 DAY))"

Write-Host "✅ Enhanced Learner completed at $(Get-Date)" -ForegroundColor Green