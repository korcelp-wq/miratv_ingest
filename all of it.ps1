#!/usr/bin/env pwsh
# Master Control - Manages all MiraTV loops and processes
# COMPLETE VERSION - All loops included

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$dashboardQuery = "$scriptPath\dashboard\Query.ps1"
$logDir = "$scriptPath\logs"

# Create log directory if it doesn't exist
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# Configuration
$config = @{
    LearningLoopInterval = 300  # seconds
    AccessoryLoopInterval = 60   # seconds
    RunnerLoopInterval = 120     # seconds
    LogRetentionDays = 7
}

# Job tracking
$jobs = @{}

function Show-Header {
    Clear-Host
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║     🎮 MIRATV MASTER CONTROL                             ║" -ForegroundColor Cyan
    Write-Host "║     Complete Loop Management                             ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Status {
    Write-Host "📊 SYSTEM STATUS" -ForegroundColor Yellow
    Write-Host "================"
    
    # Database connection test
    $test = & $dashboardQuery -Sql "SELECT 1 as test" 2>$null
    if ($test -match "rows") {
        Write-Host "✅ Database: Connected to pcde_memory" -ForegroundColor Green
    } else {
        Write-Host "❌ Database: Connection failed" -ForegroundColor Red
    }
    
    # Show running jobs
    $runningJobs = Get-Job | Where-Object { $_.State -eq 'Running' }
    Write-Host ""
    Write-Host "🔄 RUNNING PROCESSES:" -ForegroundColor Yellow
    if ($runningJobs.Count -eq 0) {
        Write-Host "  No processes running" -ForegroundColor Gray
    } else {
        foreach ($job in $runningJobs) {
            Write-Host "  ✅ $($job.Name) (PID: $($job.Id))" -ForegroundColor Green
        }
    }
    
    # Show latest stats
    Write-Host ""
    Write-Host "📈 LATEST STATS:" -ForegroundColor Yellow
    $memCount = & $dashboardQuery -Sql "SELECT COUNT(*) as c FROM pcde_ai_memory" 2>$null
    if ($memCount -match '"c":\s*(\d+)') {
        Write-Host "  🧠 AI Memories: $($matches[1])" -ForegroundColor Cyan
    }
    $relCount = & $dashboardQuery -Sql "SELECT COUNT(*) as c FROM pcde_procedure_relations" 2>$null
    if ($relCount -match '"c":\s*(\d+)') {
        Write-Host "  🔗 Relations: $($matches[1])" -ForegroundColor Cyan
    }
    $procCount = & $dashboardQuery -Sql "SELECT COUNT(*) as c FROM pcde_procedure_registry" 2>$null
    if ($procCount -match '"c":\s*(\d+)') {
        Write-Host "  📋 Procedures: $($matches[1])" -ForegroundColor Cyan
    }
}

function Start-LearningLoop {
    Write-Host "`n🚀 Starting AI Learning Loop..." -ForegroundColor Yellow
    
    $script = @"
while(`$true) {
    `$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[`$timestamp] 🔍 Running Knowledge Miner..." -ForegroundColor Cyan
    & 'C:\miratv_ingest\workers\KnowledgeMiner.ps1'
    
    Write-Host "[`$timestamp] 🔗 Running Relationship Finder..." -ForegroundColor Cyan
    & 'C:\miratv_ingest\Find-FileRelationships-Final.ps1'
    
    Write-Host "[`$timestamp] 😴 Sleeping for $($config.LearningLoopInterval) seconds..." -ForegroundColor Gray
    Start-Sleep -Seconds $($config.LearningLoopInterval)
}
"@
    
    $jobs['LearningLoop'] = Start-Job -Name "LearningLoop" -ScriptBlock ([scriptblock]::Create($script))
    Write-Host "✅ Learning Loop started" -ForegroundColor Green
}

function Start-AccessoryLoop {
    Write-Host "`n🚀 Starting Accessory Upload Loop..." -ForegroundColor Yellow
    
    $script = @"
while(`$true) {
    `$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[`$timestamp] 📤 Running Accessory Upload..." -ForegroundColor Cyan
    
    # Run the accessory upload loop
    & 'C:\miratv_ingest\MASTER_ACCESSORY_UPLOAD_LOOP.bat'
    
    Write-Host "[`$timestamp] 😴 Sleeping for $($config.AccessoryLoopInterval) seconds..." -ForegroundColor Gray
    Start-Sleep -Seconds $($config.AccessoryLoopInterval)
}
"@
    
    $jobs['AccessoryLoop'] = Start-Job -Name "AccessoryLoop" -ScriptBlock ([scriptblock]::Create($script))
    Write-Host "✅ Accessory Upload Loop started" -ForegroundColor Green
}

function Start-RunnerLoop {
    Write-Host "`n🚀 Starting Master Runner Loop..." -ForegroundColor Yellow
    
    $script = @"
while(`$true) {
    `$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[`$timestamp] 🏃 Running Master Runner..." -ForegroundColor Cyan
    
    # Run the master runner loop
    & 'C:\miratv_ingest\master_runner_loop.bat'
    
    Write-Host "[`$timestamp] 😴 Sleeping for $($config.RunnerLoopInterval) seconds..." -ForegroundColor Gray
    Start-Sleep -Seconds $($config.RunnerLoopInterval)
}
"@
    
    $jobs['RunnerLoop'] = Start-Job -Name "RunnerLoop" -ScriptBlock ([scriptblock]::Create($script))
    Write-Host "✅ Master Runner Loop started" -ForegroundColor Green
}

function Start-AllLoops {
    Write-Host "`n🚀 STARTING ALL LOOPS" -ForegroundColor Magenta
    Write-Host "===================="
    Start-LearningLoop
    Start-AccessoryLoop
    Start-RunnerLoop
    Write-Host "`n✅ All loops started" -ForegroundColor Green
}

function Stop-AllLoops {
    Write-Host "`n🛑 STOPPING ALL LOOPS" -ForegroundColor Red
    Write-Host "==================="
    foreach ($name in $jobs.Keys) {
        if ($jobs[$name]) {
            Stop-Job $jobs[$name]
            Remove-Job $jobs[$name]
            Write-Host "✅ Stopped: $name" -ForegroundColor Green
        }
    }
    $jobs.Clear()
}

function Show-Menu {
    Write-Host ""
    Write-Host "🎮 COMMANDS" -ForegroundColor Magenta
    Write-Host "==========="
    Write-Host ""
    Write-Host "  LOOP CONTROL:" -ForegroundColor White
    Write-Host "    1) Start All Loops"
    Write-Host "    2) Stop All Loops"
    Write-Host "    3) Show Running Loops"
    Write-Host ""
    Write-Host "  INDIVIDUAL LOOPS:" -ForegroundColor White
    Write-Host "    4) Start Learning Loop (AI pattern discovery)"
    Write-Host "    5) Start Accessory Upload Loop"
    Write-Host "    6) Start Master Runner Loop"
    Write-Host ""
    Write-Host "  MONITORING:" -ForegroundColor White
    Write-Host "    7) Show Latest AI Memories"
    Write-Host "    8) Show Recent Relations"
    Write-Host "    9) Show All Procedures"
    Write-Host "   10) Show Logs"
    Write-Host "   11) View Loop Statistics"
    Write-Host ""
    Write-Host "  DATABASE:" -ForegroundColor White
    Write-Host "   12) Run Custom SQL"
    Write-Host "   13) Show Database Stats"
    Write-Host ""
    Write-Host "  CONFIGURATION:" -ForegroundColor White
    Write-Host "   14) Adjust Loop Intervals"
    Write-Host "   15) Clean Old Logs"
    Write-Host ""
    Write-Host "  99) Exit"
    Write-Host ""
}

function Show-LatestMemories {
    & $dashboardQuery -Sql "SELECT memory_id, LEFT(key_data, 100) as preview, confidence, created_at FROM pcde_ai_memory ORDER BY memory_id DESC LIMIT 15"
}

function Show-RecentRelations {
    & $dashboardQuery -Sql "SELECT r.relation_id, p.procedure_name, r.relation_type, r.relation_target, r.created_at 
                           FROM pcde_procedure_relations r
                           JOIN pcde_procedure_registry p ON r.procedure_id = p.procedure_id
                           ORDER BY r.relation_id DESC LIMIT 15"
}

function Show-AllProcedures {
    & $dashboardQuery -Sql "SELECT procedure_id, procedure_name, domain, procedure_type, source_system, created_at 
                           FROM pcde_procedure_registry 
                           ORDER BY procedure_id DESC LIMIT 20"
}

function Show-Logs {
    $logs = Get-ChildItem $logDir -Filter "*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 5
    Write-Host "`n📋 Recent Logs:" -ForegroundColor Cyan
    foreach ($log in $logs) {
        Write-Host "  $($log.Name) - $($log.LastWriteTime)" -ForegroundColor Gray
        Get-Content $log.FullName -Tail 3 | ForEach-Object { Write-Host "    $_" -ForegroundColor White }
        Write-Host ""
    }
}

function Show-Statistics {
    Write-Host "`n📊 LOOP STATISTICS" -ForegroundColor Cyan
    Write-Host "=================="
    
    # Get uptime for each loop
    foreach ($name in $jobs.Keys) {
        $job = $jobs[$name]
        if ($job -and $job.State -eq 'Running') {
            $uptime = (Get-Date) - $job.PSBeginTime
            Write-Host "  ✅ $name - Running for $($uptime.Hours)h $($uptime.Minutes)m" -ForegroundColor Green
        }
    }
    
    # Get cycle counts from logs
    Write-Host ""
    Write-Host "  Cycle Counts (last 24h):" -ForegroundColor Yellow
    $learningCount = (Get-Content "$logDir\learning_loop.log" -ErrorAction SilentlyContinue | Select-String "Learning cycle" | Measure-Object).Count
    $accessoryCount = (Get-Content "$logDir\accessory_loop.log" -ErrorAction SilentlyContinue | Select-String "Accessory" | Measure-Object).Count
    $runnerCount = (Get-Content "$logDir\runner_loop.log" -ErrorAction SilentlyContinue | Select-String "Runner" | Measure-Object).Count
    
    Write-Host "    Learning Loop: $learningCount cycles" -ForegroundColor Gray
    Write-Host "    Accessory Loop: $accessoryCount cycles" -ForegroundColor Gray
    Write-Host "    Runner Loop: $runnerCount cycles" -ForegroundColor Gray
}

function Show-DatabaseStats {
    & $dashboardQuery -Sql "SELECT 'AI Memories' as type, COUNT(*) as count FROM pcde_ai_memory
                            UNION SELECT 'Relations', COUNT(*) FROM pcde_procedure_relations
                            UNION SELECT 'Procedures', COUNT(*) FROM pcde_procedure_registry
                            UNION SELECT 'Working Memory', COUNT(*) FROM pcde_working_memory"
}

function Adjust-Intervals {
    Write-Host "`n⚙️ CURRENT INTERVALS (seconds):" -ForegroundColor Cyan
    Write-Host "  1) Learning Loop: $($config.LearningLoopInterval)" -ForegroundColor White
    Write-Host "  2) Accessory Loop: $($config.AccessoryLoopInterval)" -ForegroundColor White
    Write-Host "  3) Runner Loop: $($config.RunnerLoopInterval)" -ForegroundColor White
    Write-Host ""
    
    $choice = Read-Host "Select interval to change (1-3, or 0 to cancel)"
    switch ($choice) {
        "1" { 
            $new = Read-Host "Enter new interval (seconds)"
            $config.LearningLoopInterval = [int]$new
            Write-Host "✅ Learning Loop interval updated" -ForegroundColor Green
        }
        "2" { 
            $new = Read-Host "Enter new interval (seconds)"
            $config.AccessoryLoopInterval = [int]$new
            Write-Host "✅ Accessory Loop interval updated" -ForegroundColor Green
        }
        "3" { 
            $new = Read-Host "Enter new interval (seconds)"
            $config.RunnerLoopInterval = [int]$new
            Write-Host "✅ Runner Loop interval updated" -ForegroundColor Green
        }
    }
}

function Clean-OldLogs {
    $cutoff = (Get-Date).AddDays(-$config.LogRetentionDays)
    $oldLogs = Get-ChildItem $logDir -Filter "*.log" | Where-Object { $_.LastWriteTime -lt $cutoff }
    $count = $oldLogs.Count
    $oldLogs | Remove-Item -Force
    Write-Host "✅ Removed $count old log files" -ForegroundColor Green
}

function Run-CustomSQL {
    $sql = Read-Host "`nEnter SQL query"
    if ($sql) {
        & $dashboardQuery -Sql $sql
    }
    Read-Host "`nPress Enter to continue"
}

# Main loop
do {
    Show-Header
    Show-Status
    Show-Menu
    
    $choice = Read-Host "Enter command"
    
    switch ($choice) {
        "1" { Start-AllLoops }
        "2" { Stop-AllLoops }
        "3" { 
            Get-Job | Format-Table Name, State, PSBeginTime -AutoSize
            Read-Host "Press Enter to continue"
        }
        "4" { Start-LearningLoop }
        "5" { Start-AccessoryLoop }
        "6" { Start-RunnerLoop }
        "7" { Show-LatestMemories; Read-Host "`nPress Enter to continue" }
        "8" { Show-RecentRelations; Read-Host "`nPress Enter to continue" }
        "9" { Show-AllProcedures; Read-Host "`nPress Enter to continue" }
        "10" { Show-Logs; Read-Host "`nPress Enter to continue" }
        "11" { Show-Statistics; Read-Host "`nPress Enter to continue" }
        "12" { Run-CustomSQL }
        "13" { Show-DatabaseStats; Read-Host "`nPress Enter to continue" }
        "14" { Adjust-Intervals }
        "15" { Clean-OldLogs; Read-Host "Press Enter to continue" }
        "99" { 
            $confirm = Read-Host "Stop all loops before exiting? (y/n)"
            if ($confirm -eq 'y') { Stop-AllLoops }
            Write-Host "Goodbye!" -ForegroundColor Green
            break
        }
        default { 
            Write-Host "Invalid option" -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
} while ($choice -ne "99")