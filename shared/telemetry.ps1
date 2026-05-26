# ==================================================
# MiraTV Universal Telemetry Module (PowerShell)
# Purpose: Track all jobs, triggers, workers, batches
# ==================================================

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Module-level state
$script:TelemetryConfig = $null
$script:CurrentJob = $null
$script:EventBuffer = @()

# ==================================================
# Initialize-Telemetry
# Purpose: Load config, prepare module
# ==================================================
function Initialize-Telemetry {
    if ($script:TelemetryConfig) { return } # Already loaded

    $configPath = Join-Path $PSScriptRoot "..\telemetry_config.json"
    
    if (-not (Test-Path $configPath)) {
        Write-Warning "[Telemetry] Config not found: $configPath"
        $script:TelemetryConfig = @{ enabled = $false }
        return
    }

    try {
        $script:TelemetryConfig = Get-Content $configPath -Raw | ConvertFrom-Json
        if (-not $script:TelemetryConfig.telemetry.enabled) {
            Write-Host "[Telemetry] Disabled via config"
        }
    }
    catch {
        Write-Warning "[Telemetry] Config load failed: $_"
        $script:TelemetryConfig = @{ enabled = $false }
    }
}

# ==================================================
# Start-JobTelemetry
# Purpose: Begin tracking a job/trigger/worker
# ==================================================
function Start-JobTelemetry {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Component,  # e.g., "grinder", "trigger", "master"
        
        [Parameter(Mandatory=$true)]
        [string]$JobName,    # e.g., "series_normalize", "00_series_pipeline_trigger"
        
        [hashtable]$Metadata = @{}
    )

    Initialize-Telemetry

    if (-not $script:TelemetryConfig.telemetry.enabled) { return }

    $script:CurrentJob = @{
        component = $Component
        job_name = $JobName
        start_time = Get-Date
        metadata = $Metadata
        checkpoints = @()
        errors = @()
    }

    $event = @{
        event_type = "start"
        component = $Component
        job_name = $JobName
        message = "Job started"
        timestamp = (Get-Date).ToUniversalTime().ToString("o")
        metadata = $Metadata
    }

    Add-ToBuffer $event
    Write-Host "[Telemetry] Job started: $Component/$JobName"
}

# ==================================================
# Record-TelemetryCheckpoint
# Purpose: Mark progress within a job
# ==================================================
function Record-TelemetryCheckpoint {
    param(
        [Parameter(Mandatory=$true)]
        [string]$CheckpointName,
        
        [hashtable]$Data = @{}
    )

    if (-not $script:CurrentJob) { return }
    if (-not $script:TelemetryConfig.telemetry.enabled) { return }

    $checkpoint = @{
        name = $CheckpointName
        timestamp = Get-Date
        data = $Data
    }

    $script:CurrentJob.checkpoints += $checkpoint

    $event = @{
        event_type = "checkpoint"
        component = $script:CurrentJob.component
        job_name = $script:CurrentJob.job_name
        message = $CheckpointName
        timestamp = (Get-Date).ToUniversalTime().ToString("o")
        metadata = $Data
    }

    Add-ToBuffer $event
    Write-Host "[Telemetry] Checkpoint: $CheckpointName"
}

# ==================================================
# Complete-JobTelemetry
# Purpose: Finalize job tracking (success)
# ==================================================
function Complete-JobTelemetry {
    param(
        [bool]$Success = $true,
        [hashtable]$Stats = @{}
    )

    if (-not $script:CurrentJob) { return }
    if (-not $script:TelemetryConfig.telemetry.enabled) { return }

    $duration = (Get-Date) - $script:CurrentJob.start_time

    $event = @{
        event_type = if ($Success) { "success" } else { "failure" }
        component = $script:CurrentJob.component
        job_name = $script:CurrentJob.job_name
        message = if ($Success) { "Job completed successfully" } else { "Job failed" }
        timestamp = (Get-Date).ToUniversalTime().ToString("o")
        metadata = @{
            duration_ms = [math]::Round($duration.TotalMilliseconds, 2)
            checkpoints = $script:CurrentJob.checkpoints.Count
            errors = $script:CurrentJob.errors.Count
        } + $Stats
    }

    Add-ToBuffer $event
    Flush-TelemetryBuffer
    
    Write-Host "[Telemetry] Job completed: $($script:CurrentJob.component)/$($script:CurrentJob.job_name) ($($duration.TotalSeconds)s)"
    
    $script:CurrentJob = $null
}

# ==================================================
# Record-TelemetryError
# Purpose: Log errors with context
# ==================================================
function Record-TelemetryError {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ErrorMessage,
        
        [string]$ErrorType = "unknown",
        [hashtable]$Context = @{}
    )

    if (-not $script:CurrentJob) {
        # Error occurred outside tracked job
        Initialize-Telemetry
        if (-not $script:TelemetryConfig.telemetry.enabled) { return }
        
        $event = @{
            event_type = "error"
            component = "unknown"
            job_name = "unknown"
            message = $ErrorMessage
            timestamp = (Get-Date).ToUniversalTime().ToString("o")
            metadata = @{
                error_type = $ErrorType
            } + $Context
        }
        
        Add-ToBuffer $event
        Flush-TelemetryBuffer
        return
    }

    $script:CurrentJob.errors += @{
        message = $ErrorMessage
        type = $ErrorType
        timestamp = Get-Date
        context = $Context
    }

    $event = @{
        event_type = "error"
        component = $script:CurrentJob.component
        job_name = $script:CurrentJob.job_name
        message = $ErrorMessage
        timestamp = (Get-Date).ToUniversalTime().ToString("o")
        metadata = @{
            error_type = $ErrorType
        } + $Context
    }

    Add-ToBuffer $event
    Write-Host "[Telemetry] Error recorded: $ErrorMessage" -ForegroundColor Red
}

# ==================================================
# Invoke-WithTelemetry
# Purpose: Wrapper for existing scripts/blocks
# ==================================================
function Invoke-WithTelemetry {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Component,
        
        [Parameter(Mandatory=$true)]
        [string]$JobName,
        
        [Parameter(Mandatory=$true)]
        [scriptblock]$ScriptBlock,
        
        [hashtable]$Metadata = @{}
    )

    Start-JobTelemetry -Component $Component -JobName $JobName -Metadata $Metadata

    try {
        & $ScriptBlock
        Complete-JobTelemetry -Success $true
    }
    catch {
        Record-TelemetryError -ErrorMessage $_.Exception.Message -ErrorType "script_error"
        Complete-JobTelemetry -Success $false
        throw
    }
}

# ==================================================
# Internal: Add-ToBuffer
# ==================================================
function Add-ToBuffer {
    param([hashtable]$Event)
    
    $script:EventBuffer += $Event
    
    $batchSize = if ($script:TelemetryConfig.telemetry.batch_size) { 
        $script:TelemetryConfig.telemetry.batch_size 
    } else { 
        10 
    }
    
    if ($script:EventBuffer.Count -ge $batchSize) {
        Flush-TelemetryBuffer
    }
}

# ==================================================
# Flush-TelemetryBuffer
# Purpose: Send events to server (async)
# ==================================================
function Flush-TelemetryBuffer {
    if ($script:EventBuffer.Count -eq 0) { return }
    if (-not $script:TelemetryConfig.telemetry.enabled) { return }

    $endpoint = $script:TelemetryConfig.telemetry.endpoint
    $token = $script:TelemetryConfig.telemetry.token

    if (-not $endpoint) {
        Write-Warning "[Telemetry] No endpoint configured"
        $script:EventBuffer = @()
        return
    }

    $payload = @{
        token = $token
        events = $script:EventBuffer
    } | ConvertTo-Json -Depth 10 -Compress

    # Clear buffer immediately (don't wait for network)
    $eventsToSend = $script:EventBuffer.Count
    $script:EventBuffer = @()

    # Async send (fire-and-forget)
    try {
        $job = Start-Job -ScriptBlock {
            param($Url, $Body)
            
            try {
                Invoke-RestMethod -Uri $Url `
                    -Method POST `
                    -ContentType "application/json" `
                    -Body $Body `
                    -TimeoutSec 5 `
                    -ErrorAction Stop | Out-Null
            }
            catch {
                # Silent fail (telemetry should never break pipeline)
            }
        } -ArgumentList $endpoint, $payload

        # Don't wait for completion
        Write-Verbose "[Telemetry] Sent $eventsToSend events (async)"
    }
    catch {
        # Silent fail
    }
}

# ==================================================
# Export functions
# ==================================================
Export-ModuleMember -Function @(
    'Initialize-Telemetry',
    'Start-JobTelemetry',
    'Record-TelemetryCheckpoint',
    'Complete-JobTelemetry',
    'Record-TelemetryError',
    'Invoke-WithTelemetry',
    'Flush-TelemetryBuffer'
)
