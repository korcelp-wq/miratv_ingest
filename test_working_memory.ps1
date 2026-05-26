# Test script for working memory
Import-Module C:\miratv_ingest\modules\WorkingMemory.psm1 -Force

Write-Host "🧠 Testing Working Memory System" -ForegroundColor Magenta
Write-Host "=" * 50

# Start a new session
$sessionId = Start-WorkingSession -SessionType 'test' -TimeoutMinutes 5
Write-Host "Session ID: $sessionId" -ForegroundColor Green

# Store some values
Set-WorkingMemory -SessionId $sessionId -Key "current_task" -Value "Testing working memory" -Confidence 1.0
Set-WorkingMemory -SessionId $sessionId -Key "series_id" -Value "4271" -ValueType number -Confidence 0.95
Set-WorkingMemory -SessionId $sessionId -Key "provider" -Value "xtream" -Confidence 0.9

# Store a JSON object
$jsonData = @{
    step = "STEP 8"
    error = "no_embedded_payload"
    attempts = 3
} | ConvertTo-Json
Set-WorkingMemory -SessionId $sessionId -Key "error_context" -Value $jsonData -ValueType json -Confidence 0.85

# Display what we stored
Show-WorkingMemory -SessionId $sessionId

# Retrieve specific value
Write-Host "`n🔍 Retrieving series_id:" -ForegroundColor Yellow
$value = Get-WorkingMemory -SessionId $sessionId -Key "series_id"
if ($value) { $value | Format-Table }

# Retrieve all values
Write-Host "`n📋 All working memory:" -ForegroundColor Yellow
$all = Get-WorkingMemory -SessionId $sessionId
$all | Format-Table -AutoSize

# End the session
End-WorkingSession -SessionId $sessionId -Status 'completed'

Write-Host "`n✅ Test complete!" -ForegroundColor Green