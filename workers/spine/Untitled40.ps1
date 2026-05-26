#!/usr/bin/env pwsh
# Master Control Console for PCDE

# Import modules
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module "$scriptPath\modules\DogOpenClient.psm1" -Force -ErrorAction SilentlyContinue

# Configuration
$script:Services = @{}
$script:Running = $false

function Show-Header {
    Clear-Host
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║     🧠 PCDE MASTER CONTROL CONSOLE                      ║" -ForegroundColor Cyan
    Write-Host "║     Cognitive Systems Command Center                    ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Status {
    Write-Host "📊 SYSTEM STATUS" -ForegroundColor Yellow
    Write-Host "================"
    
    # Check database connectivity
    try {
        $test = Invoke-DogOpenQuery -Sql "SELECT 1 as test" -ErrorAction Stop
        Write-Host "✅ Database: Connected to pcde_memory" -ForegroundColor Green
    } catch {
        Write-Host "❌ Database: Connection failed" -ForegroundColor Red
    }
    
    # Check running services
    $jobs = Get-Job
    Write-Host ""
    Write-Host "🔄 ACTIVE SERVICES:" -ForegroundColor Yellow
    if ($jobs.Count -eq 0) {
        Write-Host "  No services running" -ForegroundColor Gray
    } else {
        foreach ($job in $jobs) {
            $color = if ($job.State -eq 'Running') { 'Green' } else { 'Red' }
            Write-Host "  [$($job.State)] $($job.Name)" -ForegroundColor $color
        }
    }
    
    # Show working memory count
    $wm = Invoke-DogOpenQuery -Sql "SELECT COUNT(*) as count FROM pcde_working_memory WHERE expires_at > NOW()" -ErrorAction SilentlyContinue
    if ($wm.rows) {
        Write-Host ""
        Write-Host "🧠 WORKING MEMORY: $($wm.rows[0].count) active sessions" -ForegroundColor Cyan
    }
}

function Start-Service {
    param([string]$Name, [string]$Path, [array]$Args = @())
    
    if (Test-Path $Path) {
        Write-Host "Starting $Name..." -ForegroundColor Yellow
        $script:Services[$Name] = Start-Job -Name $Name -FilePath $Path -ArgumentList $Args
        Write-Host "✅ $Name started" -ForegroundColor Green
    } else {
        Write-Host "❌ $Name not found at $Path" -ForegroundColor Red
    }
}

function Stop-Service {
    param([string]$Name)
    
    $job = Get-Job -Name $Name -ErrorAction SilentlyContinue
    if ($job) {
        Stop-Job $job
        Remove-Job $job
        Write-Host "✅ $Name stopped" -ForegroundColor Green
    }
}

function Show-Menu {
    Write-Host ""
    Write-Host "🎮 COMMANDS" -ForegroundColor Magenta
    Write-Host "==========="
    Write-Host ""
    Write-Host "  SERVICE CONTROL:" -ForegroundColor White
    Write-Host "    1) Start All Services" 
    Write-Host "    2) Stop All Services"
    Write-Host "    3) Show Service Status"
    Write-Host ""
    Write-Host "  CORE SERVICES:" -ForegroundColor White
    Write-Host "    4) Start Spine Scheduler"
    Write-Host "    5) Start CVI Watcher"
    Write-Host "    6) Start Telemetry"
    Write-Host "    7) Start Spool Uploader"
    Write-Host "    8) Start Embedding Pipeline"
    Write-Host "    9) Start AI Learning Loop"
    Write-Host ""
    Write-Host "  PIPELINE CONTROL:" -ForegroundColor White
    Write-Host "    10) Run Master Runner (One-shot)"
    Write-Host "    11) Run Series Pipeline"
    Write-Host "    12) Run Episode Resolver"
    Write-Host ""
    Write-Host "  AI COMMANDS:" -ForegroundColor White
    Write-Host "    13) Show AI Learnings"
    Write-Host "    14) Show Working Memory"
    Write-Host "    15) Show Active Sessions"
    Write-Host "    16) Run Governance Learner"
    Write-Host ""
    Write-Host "  DATABASE:" -ForegroundColor White
    Write-Host "    17) Run Custom SQL"
    Write-Host "    18) Export AI Memory"
    Write-Host ""
    Write-Host "  99) Exit"
    Write-Host ""
}

function Start-AllServices {
    Write-Host "`n🚀 STARTING ALL SERVICES" -ForegroundColor Cyan
    
    Start-Service -Name "SpineScheduler" -Path "C:\miratv_ingest\workers\spine\spine_scheduler_total.ps1"
    Start-Sleep -Seconds 2
    
    Start-Service -Name "CVIWatcher" -Path "C:\miratv_ingest\watcher_cvi.ps1"
    Start-Sleep -Seconds 1
    
    Start-Service -Name "TelemetryWatcher" -Path "C:\miratv_ingest\workers\telemetry_watcher.ps1"
    Start-Sleep -Seconds 1
    
    Start-Service -Name "SpoolUploader" -Path "C:\miratv_ingest\spool_uploader.ps1" -Args @{Continuous = $true}
    Start-Sleep -Seconds 1
    
    # Start AI Learning Loop as a background job
    $script:AILearning = Start-Job -Name "AILearning" -ScriptBlock {
        while($true) {
            & "C:\miratv_ingest\workers\GovernanceLearner.ps1"
            Start-Sleep -Seconds 300
        }
    }
    Write-Host "✅ AI Learning started" -ForegroundColor Green
}

function Show-AILearnings {
    $result = Invoke-DogOpenQuery -Sql "SELECT id, confidence, key_data, created_at FROM pcde_ai_memory ORDER BY confidence DESC LIMIT 10"
    if ($result.rows) {
        Write-Host "`n🧠 TOP AI LEARNINGS" -ForegroundColor Cyan
        Write-Host "=================="
        foreach ($row in $result.rows) {
            $conf = [double]$row.confidence
            $color = if ($conf -gt 0.9) { 'Green' } elseif ($conf -gt 0.7) { 'Yellow' } else { 'Gray' }
            Write-Host "[$($row.id)] Confidence: $($row.confidence)" -ForegroundColor $color
            Write-Host "    $($row.key_data)" -ForegroundColor White
            Write-Host "    Learned: $($row.created_at)" -ForegroundColor Gray
            Write-Host ""
        }
    }
}

function Show-WorkingMemory {
    $result = Invoke-DogOpenQuery -Sql "SELECT * FROM pcde_working_memory WHERE expires_at > NOW() ORDER BY created_at DESC"
    if ($result.rows) {
        Write-Host "`n🧠 ACTIVE WORKING MEMORY" -ForegroundColor Cyan
        Write-Host "========================"
        foreach ($row in $result.rows) {
            Write-Host "Session: $($row.session_id)" -ForegroundColor Yellow
            Write-Host "  $($row.slot_key) = $($row.slot_value) (conf: $($row.confidence))" -ForegroundColor White
            Write-Host "  Expires: $($row.expires_at)" -ForegroundColor Gray
            Write-Host ""
        }
    } else {
        Write-Host "No active working memory" -ForegroundColor Yellow
    }
}

# Main loop
do {
    Show-Header
    Show-Status
    Show-Menu
    
    $choice = Read-Host "Enter command"
    
    switch ($choice) {
        "1" { Start-AllServices }
        "2" { 
            Get-Job | Stop-Job
            Get-Job | Remove-Job
            Write-Host "✅ All services stopped" -ForegroundColor Green
            Start-Sleep -Seconds 2
        }
        "3" { 
            Get-Job | Format-Table Name, State, HasMoreData -AutoSize
            Read-Host "Press Enter to continue"
        }
        "4" { Start-Service -Name "SpineScheduler" -Path "C:\miratv_ingest\workers\spine\spine_scheduler_total.ps1" }
        "5" { Start-Service -Name "CVIWatcher" -Path "C:\miratv_ingest\watcher_cvi.ps1" }
        "6" { Start-Service -Name "TelemetryWatcher" -Path "C:\miratv_ingest\workers\telemetry_watcher.ps1" }
        "7" { Start-Service -Name "SpoolUploader" -Path "C:\miratv_ingest\spool_uploader.ps1" -Args @{Continuous = $true} }
        "8" { Start-Service -Name "EmbeddingPipeline" -Path "C:\miratv_ingest\workers\embedding_pipeline.ps1" }
        "9" { 
            Start-Job -Name "AILearning" -ScriptBlock {
                while($true) {
                    & "C:\miratv_ingest\workers\GovernanceLearner.ps1"
                    Start-Sleep -Seconds 300
                }
            }
            Write-Host "✅ AI Learning started" -ForegroundColor Green
        }
        "10" { 
            Write-Host "Running master runner..." -ForegroundColor Yellow
            & "C:\miratv_ingest\master_runner2.bat"
            Read-Host "Press Enter to continue"
        }
        "11" { 
            & "C:\miratv_ingest\run_series_pipeline.ps1"
            Read-Host "Press Enter to continue"
        }
        "12" { 
            & "C:\miratv_ingest\triggers\9episode_resolver_trigger.ps1"
            Read-Host "Press Enter to continue"
        }
        "13" { Show-AILearnings; Read-Host "Press Enter to continue" }
        "14" { Show-WorkingMemory; Read-Host "Press Enter to continue" }
        "15" { 
            $result = Invoke-DogOpenQuery -Sql "SELECT * FROM pcde_working_sessions WHERE status = 'active'"
            $result | ConvertTo-Json
            Read-Host "Press Enter to continue"
        }
        "16" { 
            & "C:\miratv_ingest\workers\GovernanceLearner.ps1"
            Read-Host "Press Enter to continue"
        }
        "17" { 
            $sql = Read-Host "Enter SQL"
            $result = Invoke-DogOpenQuery -Sql $sql
            $result | ConvertTo-Json -Depth 10
            Read-Host "Press Enter to continue"
        }
        "18" { 
            $result = Invoke-DogOpenQuery -Sql "SELECT * FROM pcde_ai_memory"
            $result.rows | ConvertTo-Json | Out-File "ai_memory_export_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
            Write-Host "✅ Export complete" -ForegroundColor Green
            Read-Host "Press Enter to continue"
        }
        "99" { 
            Write-Host "Shutting down..." -ForegroundColor Red
            break
        }
        default { 
            Write-Host "Invalid option" -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
} while ($choice -ne "99")