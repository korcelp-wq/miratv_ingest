# ============================================
# Master Control 8 (Enhanced - Stable)
# ============================================

Clear-Host

# ============================================
# GLOBALS
# ============================================
$queryScript = "C:\miratv_ingest\query.ps1"
$script:aiSessionId = $null

# ============================================
# SAFE SQL QUERY WRAPPER
# ============================================
function Safe-SqlQuery {
    param([string]$Sql)

    if (Test-Path $queryScript) {
        try {
            return & $queryScript -Sql $Sql
        } catch {
            Write-Host "SQL Error: $_" -ForegroundColor Red
        }
    } else {
        Write-Host "Query script not found." -ForegroundColor Yellow
    }
}

# ============================================
# AI FUNCTION (SAFE)
# ============================================
function Ask-AI {
    param([string]$Question)

    if (-not $script:aiSessionId) {
        $script:aiSessionId = "session_$(Get-Date -Format 'yyyyMMddHHmmss')"
    }

    $formattedResponse = "AI received: $Question"

    $qId = "q_$(Get-Random -Maximum 9999)"
    $aId = "a_$(Get-Random -Maximum 9999)"

    $escapedQuestion = $Question -replace "'", "''"
    $escapedResponse = $formattedResponse -replace "'", "''"

    $sql = @"
INSERT INTO pcde_working_memory (session_id, slot_key, slot_value)
VALUES ('$script:aiSessionId', '$qId', '$escapedQuestion'),
       ('$script:aiSessionId', '$aId', '$escapedResponse')
"@

    Safe-SqlQuery $sql | Out-Null

    return $formattedResponse
}

# ============================================
# SERVICE RUNNER (SAFE)
# ============================================
function Run-ServiceCommand {
    param([string]$input)

    $serviceMap = @{
        "spine" = "C:\miratv_ingest\workers\spine\spine_scheduler_total.ps1"
        "cvi" = "C:\miratv_ingest\watcher_cvi.ps1"
        "telemetry" = "C:\miratv_ingest\workers\telemetry_watcher.ps1"
        "spool" = "C:\miratv_ingest\spool_uploader.ps1"
        "ai learning" = "C:\miratv_ingest\workers\GovernanceLearner.ps1"
        "relationship finder" = "C:\miratv_ingest\Find-FileRelationships.ps1"
    }

    foreach ($key in $serviceMap.Keys) {
        if ($input -like "*$key*") {
            $path = $serviceMap[$key]

            if (Test-Path $path) {
                Start-Job -Name $key -FilePath $path | Out-Null
                return "Started $key"
            } else {
                return "Script not found: $path"
            }
        }
    }

    return "Unknown service"
}

# ============================================
# MENU DISPLAY
# ============================================
function Show-Menu {
    Clear-Host
    Write-Host "===================================" -ForegroundColor Cyan
    Write-Host " MiraTV Master Control (Stable)" -ForegroundColor Cyan
    Write-Host "===================================" -ForegroundColor Cyan

    Write-Host " 1) Run Custom SQL"
    Write-Host " 2) Export AI Memory"
    Write-Host " 50) Ask AI"
    Write-Host " 99) Exit"

    Write-Host ""
}

# ============================================
# MAIN LOOP
# ============================================
do {
    Show-Menu
    $choice = Read-Host "Select option"

    switch ($choice) {

        "1" {
            $sql = Read-Host "Enter SQL"
            $result = Safe-SqlQuery $sql
            $result
            Read-Host "Press Enter"
        }

        "2" {
            $sql = "SELECT * FROM pcde_working_memory"
            $result = Safe-SqlQuery $sql

            $path = "C:\miratv_ingest\exports\ai_memory_$(Get-Date -Format 'yyyyMMddHHmmss').txt"
            $result | Out-File $path

            Write-Host "Exported to $path" -ForegroundColor Green
            Read-Host "Press Enter"
        }

        "50" {
            $q = Read-Host "Ask AI"

            if ($q -match "run|start") {
                $result = Run-ServiceCommand $q
                Write-Host $result -ForegroundColor Cyan
            } else {
                $result = Ask-AI $q
                Write-Host $result -ForegroundColor Green
            }

            Read-Host "Press Enter"
        }

        "99" {
            Write-Host "Shutting down..." -ForegroundColor Red
        }

        default {
            Write-Host "Invalid option" -ForegroundColor Red
            Start-Sleep 1
        }
    }

} while ($choice -ne "99")