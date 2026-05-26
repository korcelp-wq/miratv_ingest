# Simple Telemetry Helper (No JSON Processing)
# Logs to text files only

function Log-JobStart {
    param([string]$JobName)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $logLine = "$timestamp | START | $JobName"
    Write-Host $logLine -ForegroundColor Cyan
    Add-Content "c:\miratv_ingest\logs\job_trace.log" $logLine
}

function Log-JobComplete {
    param([string]$JobName, [bool]$Success = $true)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $status = if ($Success) { "SUCCESS" } else { "FAIL" }
    $logLine = "$timestamp | $status | $JobName"
    Write-Host $logLine -ForegroundColor $(if ($Success) { "Green" } else { "Red" })
    Add-Content "c:\miratv_ingest\logs\job_trace.log" $logLine
}

function Log-Checkpoint {
    param([string]$CheckpointName)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $logLine = "$timestamp | CHECKPOINT | $CheckpointName"
    Write-Host $logLine -ForegroundColor Yellow
    Add-Content "c:\miratv_ingest\logs\job_trace.log" $logLine
}

Export-ModuleMember -Function Log-JobStart, Log-JobComplete, Log-Checkpoint
