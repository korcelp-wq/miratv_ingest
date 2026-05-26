# WorkingMemory.psm1
# Import CVI client if needed
$script:modulePath = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module "$script:modulePath\CviClient.psm1" -Force -ErrorAction SilentlyContinue

function Start-WorkingSession {
    param(
        [string]$SessionType = 'ai_task',
        [int]$TimeoutMinutes = 15,
        [string]$ParentSession = $null,
        [int]$ProcedureId = $null
    )
    
    $sessionId = [guid]::NewGuid().ToString()
    $expires = (Get-Date).AddMinutes($TimeoutMinutes).ToString('yyyy-MM-dd HH:mm:ss')
    
    Write-Host "📝 Starting working session: $sessionId" -ForegroundColor Cyan
    
    $sql = @"
INSERT INTO pcde_working_sessions 
(session_id, session_type, status, expires_at, parent_session, procedure_id)
VALUES ('$sessionId', '$SessionType', 'active', '$expires', $(if ($ParentSession) { "'$ParentSession'" } else { "NULL" }), $(if ($ProcedureId) { $ProcedureId } else { "NULL" }));
"@
    
    $result = Invoke-CviSql -Database "xpdgxfsp_pcde_memory" -Sql $sql
    
    return $sessionId
}

function Set-WorkingMemory {
    param(
        [string]$SessionId,
        [string]$Key,
        [object]$Value,
        [string]$ValueType = 'string',
        [float]$Confidence = 0.95,
        [int]$ProcedureId = $null,
        [int]$TimeoutMinutes = 15
    )
    
    # Convert value to string based on type
    $stringValue = if ($ValueType -eq 'json') {
        $Value | ConvertTo-Json -Compress
    } elseif ($ValueType -eq 'number') {
        $Value.ToString()
    } else {
        $Value.ToString()
    }
    
    # Escape single quotes for SQL
    $stringValue = $stringValue -replace "'", "''"
    
    $expires = (Get-Date).AddMinutes($TimeoutMinutes).ToString('yyyy-MM-dd HH:mm:ss')
    
    Write-Host "  📌 Setting $Key = $stringValue" -ForegroundColor Gray
    
    $sql = @"
INSERT INTO pcde_working_memory 
(session_id, slot_key, slot_value, value_type, confidence, source_procedure_id, expires_at)
VALUES ('$SessionId', '$Key', '$stringValue', '$ValueType', $Confidence, $(if ($ProcedureId) { $ProcedureId } else { "NULL" }), '$expires')
ON DUPLICATE KEY UPDATE
    slot_value = VALUES(slot_value),
    value_type = VALUES(value_type),
    confidence = VALUES(confidence),
    expires_at = VALUES(expires_at),
    last_accessed = NOW(),
    access_count = access_count + 1;
"@
    
    Invoke-CviSql -Database "xpdgxfsp_pcde_memory" -Sql $sql
    
    # Update session last activity
    $updateSql = "UPDATE pcde_working_sessions SET last_activity = NOW() WHERE session_id = '$SessionId';"
    Invoke-CviSql -Database "xpdgxfsp_pcde_memory" -Sql $updateSql
}

function Get-WorkingMemory {
    param(
        [string]$SessionId,
        [string]$Key = $null
    )
    
    if ($Key) {
        $sql = @"
SELECT slot_key, slot_value, value_type, confidence, created_at, last_accessed, access_count
FROM pcde_working_memory
WHERE session_id = '$SessionId' AND slot_key = '$Key' AND (expires_at IS NULL OR expires_at > NOW());
"@
        $result = Invoke-CviSql -Database "xpdgxfsp_pcde_memory" -Sql $sql
        
        # Update access count
        if ($result -and $result.Count -gt 0) {
            $updateSql = @"
UPDATE pcde_working_memory 
SET last_accessed = NOW(), access_count = access_count + 1 
WHERE session_id = '$SessionId' AND slot_key = '$Key';
"@
            Invoke-CviSql -Database "xpdgxfsp_pcde_memory" -Sql $updateSql
        }
        
        return $result
    } else {
        $sql = @"
SELECT slot_key, slot_value, value_type, confidence, created_at, last_accessed, access_count
FROM pcde_working_memory
WHERE session_id = '$SessionId' AND (expires_at IS NULL OR expires_at > NOW())
ORDER BY created_at;
"@
        return Invoke-CviSql -Database "xpdgxfsp_pcde_memory" -Sql $sql
    }
}

function Clear-WorkingMemory {
    param(
        [string]$SessionId,
        [string]$Key = $null
    )
    
    if ($Key) {
        $sql = "DELETE FROM pcde_working_memory WHERE session_id = '$SessionId' AND slot_key = '$Key';"
        Write-Host "  🧹 Clearing $Key" -ForegroundColor Yellow
    } else {
        $sql = "DELETE FROM pcde_working_memory WHERE session_id = '$SessionId';"
        Write-Host "  🧹 Clearing all memory for session $SessionId" -ForegroundColor Yellow
    }
    
    Invoke-CviSql -Database "xpdgxfsp_pcde_memory" -Sql $sql
}

function End-WorkingSession {
    param(
        [string]$SessionId,
        [string]$Status = 'completed'
    )
    
    Write-Host "🏁 Ending working session: $SessionId (Status: $Status)" -ForegroundColor Cyan
    
    $sql = "UPDATE pcde_working_sessions SET status = '$Status' WHERE session_id = '$SessionId';"
    Invoke-CviSql -Database "xpdgxfsp_pcde_memory" -Sql $sql
    
    # Optionally clear memory or leave for audit
    # Clear-WorkingMemory -SessionId $SessionId
}

function Show-WorkingMemory {
    param(
        [string]$SessionId
    )
    
    $memory = Get-WorkingMemory -SessionId $SessionId
    
    Write-Host "`n📊 Working Memory Contents:" -ForegroundColor Cyan
    Write-Host "═" * 50
    
    if ($memory -and $memory.Count -gt 0) {
        foreach ($item in $memory) {
            $expired = if ($item.expires_at) { " (expires: $($item.expires_at))" } else { "" }
            Write-Host "🔹 $($item.slot_key): $($item.slot_value) [confidence: $($item.confidence)]$expired" -ForegroundColor Green
        }
    } else {
        Write-Host "⚠️ No active memory slots" -ForegroundColor Yellow
    }
    Write-Host "═" * 50
}

Export-ModuleMember -Function Start-WorkingSession, Set-WorkingMemory, Get-WorkingMemory, 
                    Clear-WorkingMemory, End-WorkingSession, Show-WorkingMemory