function Start-AISession {
    param([string]$SessionId = (New-Guid).ToString())
    
    Write-Host "`n🚀 Starting AI Session..." -ForegroundColor Yellow
    
    # Insert using the correct column names
    $sql = @"
INSERT INTO pcde_working_sessions (session_id, session_type, status)
VALUES ('$SessionId', 'ai_chat', 'active')
"@
    
    # Try the insert
    $result = Invoke-SQLDirect -Sql $sql
    
    if ($result -ne $null) {
        Write-Host "✅ AI Session started (ID: $($SessionId.Substring(0,8))...)" -ForegroundColor Green
        $script:aiSessionId = $SessionId
    } else {
        # If that failed, try without any timestamp fields
        Write-Host "⚠️ Retrying with minimal insert..." -ForegroundColor Yellow
        $sql2 = "INSERT INTO pcde_working_sessions (session_id) VALUES ('$SessionId')"
        $result2 = Invoke-SQLDirect -Sql $sql2
        
        if ($result2 -ne $null) {
            Write-Host "✅ AI Session started (ID: $($SessionId.Substring(0,8))...)" -ForegroundColor Green
            $script:aiSessionId = $SessionId
        } else {
            Write-Host "⚠️ Could not record session in database, but continuing..." -ForegroundColor Yellow
            $script:aiSessionId = $SessionId
        }
    }
    return $SessionId
}