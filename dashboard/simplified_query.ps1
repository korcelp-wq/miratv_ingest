# Navigate to dashboard folder
cd C:\miratv_ingest\dashboard

# Delete the broken file
Remove-Item Query.ps1 -Force

# Create a super simple version
@'
#!/usr/bin/env pwsh
# Simple query tool for dog_open.php

param(
    [string]$Sql,
    [string]$Db = "xpdgxfsp_pcde_memory"
)

# Direct path to module - no Join-Path complexity
$modulePath = "C:\miratv_ingest\modules\DogOpenClient.psm1"

# Import the module
if (Test-Path $modulePath) {
    Import-Module $modulePath -Force
    Write-Host "✅ Module loaded" -ForegroundColor Green
} else {
    Write-Host "❌ Module not found at $modulePath" -ForegroundColor Red
    Write-Host "Please create the module first:" -ForegroundColor Yellow
    Write-Host "New-Item -ItemType Directory -Path C:\miratv_ingest\modules -Force" -ForegroundColor White
    exit 1
}

# If no SQL provided, show help
if ([string]::IsNullOrWhiteSpace($Sql)) {
    Write-Host "`n🐕 MiraTV DogOpen Query Tool" -ForegroundColor Cyan
    Write-Host "============================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage: .\Query.ps1 -Sql ""YOUR SQL HERE"" [-Db database]"
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Yellow
    Write-Host '  .\Query.ps1 -Sql "SELECT * FROM pcde_working_memory"'
    Write-Host '  .\Query.ps1 -Sql "SELECT * FROM pcde_ai_memory" -Db xpdgxfsp_pcde_memory'
    Write-Host '  .\Query.ps1 -Sql "SELECT COUNT(*) FROM pcde_procedure_registry"'
    Write-Host ""
    exit
}

# Run the query
Invoke-DogOpenQuery -Db $Db -Sql $Sql
'@ | Out-File -FilePath Query.ps1 -Encoding utf8

Write-Host "✅ Fixed Query.ps1 created" -ForegroundColor Green