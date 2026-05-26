#!/usr/bin/env pwsh
# Simple query tool for dog_open.php

param(
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Args
)

# Import the module
$modulePath = Join-Path $PSScriptRoot "modules" "DogOpenClient.psm1"
if (Test-Path $modulePath) {
    Import-Module $modulePath -Force
} else {
    Write-Host "⚠️ Module not found at $modulePath" -ForegroundColor Yellow
    Write-Host "Please create the DogOpenClient module first." -ForegroundColor Yellow
    exit 1
}

# If no arguments, show interactive menu
if ($Args.Count -eq 0) {
    do {
        Clear-Host
        Write-Host "`n🐕 MiraTV DogOpen Query Tool" -ForegroundColor Cyan
        Write-Host "=============================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "1) View Working Memory" -ForegroundColor Yellow
        Write-Host "2) View AI Learnings" -ForegroundColor Yellow
        Write-Host "3) View Procedures" -ForegroundColor Yellow
        Write-Host "4) Show Tables" -ForegroundColor Yellow
        Write-Host "5) Custom Query" -ForegroundColor Yellow
        Write-Host "6) Watch Working Memory" -ForegroundColor Yellow
        Write-Host "7) Exit" -ForegroundColor Red
        Write-Host ""
        
        $choice = Read-Host "Select option"
        
        switch ($choice) {
            "1" {
                Invoke-DogOpenQuery -Sql "SELECT * FROM pcde_working_memory ORDER BY created_at DESC"
            }
            "2" {
                Invoke-DogOpenQuery -Sql "SELECT * FROM pcde_ai_memory ORDER BY confidence DESC"
            }
            "3" {
                Invoke-DogOpenQuery -Sql "SELECT procedure_id, procedure_name, domain FROM pcde_procedure_registry ORDER BY procedure_id"
            }
            "4" {
                Show-DogOpenTables
            }
            "5" {
                $sql = Read-Host "Enter SQL"
                $db = Read-Host "Database (Enter for default)"
                if ([string]::IsNullOrWhiteSpace($db)) { 
                    $db = "xpdgxfsp_pcde_memory" 
                }
                Invoke-DogOpenQuery -Db $db -Sql $sql
            }
            "6" {
                Watch-DogOpenWorkingMemory
            }
            "7" {
                Write-Host "Goodbye!" -ForegroundColor Green
                exit
            }
            default {
                Write-Host "Invalid option" -ForegroundColor Red
                Read-Host "Press Enter to continue"
            }
        }
        
        if ($choice -ne "7") {
            Read-Host "`nPress Enter to continue"
        }
    } while ($choice -ne "7")
} else {
    # Command line mode: .\Query.ps1 "SELECT * FROM table"
    $sql = $Args -join " "
    Invoke-DogOpenQuery -Sql $sql
}