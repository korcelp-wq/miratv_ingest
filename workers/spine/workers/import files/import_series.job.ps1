<#
=========================================================
 MiraTV MASTER JOB WRAPPER — SERIES INGEST
=========================================================

PURPOSE:
- Single execution spine
- OPS-safe
- Stage-gated
- No redesign required later

PHASES:
  PHASE 1 — Entry + Logging
  PHASE 2 — OPS DB (runs, locks, events)
  PHASE 3 — Legacy PS execution
  PHASE 4 — File artifacts
  PHASE 5 — PHP handoff
  PHASE 6 — Repetition / hardening

Only uncomment ONE PHASE at a time.
=========================================================
#>

param(
    [ValidateSet("dev","stage","prod")]
    [string]$Environment = "dev"
)

# =========================================================
# CONSTANTS / PATHS (ALWAYS ACTIVE)
# =========================================================

$JobKey       = "import_series"
$JobClass     = "SAFE"     # SAFE or RISKY
$Base         = "C:\MiraTV"
$LogDir       = Join-Path $Base "logs\jobs"
$LibOpsDb     = Join-Path $Base "ps1\lib\ops_db.ps1"
$LegacyScript = Join-Path $Base "ps1\series_details_worker.ps1"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile = Join-Path $LogDir "${JobKey}_${Environment}_${ts}.log"

function Log-Line {
    param([string]$Msg, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Msg
    Add-Content -Path $LogFile -Value $line
    Write-Host $line
}

Log-Line "Wrapper loaded for job=$JobKey env=$Environment"

# =========================================================
# PHASE 1 — ENTRY CONFIRMATION (ACTIVE FIRST)
# =========================================================

Log-Line "PHASE 1 ACTIVE — entry + logging confirmed"
Start-Sleep -Seconds 1

# EXIT HERE FOR PHASE 1 ONLY
# exit 0


# =========================================================
# PHASE 2 — OPS DB + LOCKING (COMMENTED INITIALLY)
# =========================================================


. $LibOpsDb

$runId = Start-JobRun -JobKey $JobKey -Environment $Environment
Write-JobEvent -RunId $runId -JobKey $JobKey -Environment $Environment `
               -EventType "STARTED" -EventDetail "wrapper_started"

Acquire-JobLock -JobKey $JobKey -Environment $Environment -RunId $runId
Write-JobEvent -RunId $runId -JobKey $JobKey -Environment $Environment `
               -EventType "LOCK_ACQUIRED" -EventDetail "db_lock"

Log-Line "PHASE 2 ACTIVE — OPS DB + lock acquired"
Start-Sleep -Seconds 2


# EXIT HERE FOR PHASE 2 ONLY
# Complete-JobRun -RunId $runId -Status "success" -Summary "PHASE 2 complete"
# Release-JobLock -JobKey $JobKey -Environment $Environment -RunId $runId
# exit 0


# =========================================================
# PHASE 3 — LEGACY POWERSHELL WORKER
# =========================================================

<#
Log-Line "PHASE 3 ACTIVE — invoking legacy PS worker"

& $LegacyScript $Environment 2>&1 |
    Tee-Object -FilePath $LogFile -Append |
    Out-Host

if ($LASTEXITCODE -ne 0) {
    throw "Legacy worker failed with exit code $LASTEXITCODE"
}

Write-JobEvent -RunId $runId -JobKey $JobKey -Environment $Environment `
               -EventType "LEGACY_DONE" -EventDetail "worker_ok"
#>


# =========================================================
# PHASE 4 — FILE ARTIFACT VALIDATION
# =========================================================

<#
Log-Line "PHASE 4 ACTIVE — validating file outputs"
# validate export/json/tmp presence
# no DB writes here
#>


# =========================================================
# PHASE 5 — PHP HANDOFF
# =========================================================

<#
Log-Line "PHASE 5 ACTIVE — calling PHP endpoint"

# Example:
# Invoke-RestMethod http://localhost/import_series.php
# Check HTTP 200
# Record result
#>


# =========================================================
# PHASE 6 — FINALIZATION
# =========================================================

<#
Complete-JobRun -RunId $runId -Status "success" -Summary "Completed all phases"
Write-JobEvent -RunId $runId -JobKey $JobKey -Environment $Environment `
               -EventType "COMPLETED" -EventDetail "all_done"

Release-JobLock -JobKey $JobKey -Environment $Environment -RunId $runId
Log-Line "Job completed successfully"
#>
