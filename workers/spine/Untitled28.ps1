cd C:\miratv_ingest\dashboard

@'
#!/usr/bin/env pwsh
# Simple standalone query tool for dog_open.php

param(
    [string]$Sql,
    [string]$Db = "pcde_memory"
)

$token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$endpoint = "https://miratv.club/_workers/api/series/dog_open.php"

if ([string]::IsNullOrWhiteSpace($Sql)) {
    Write-Host "`n🐕 MiraTV DogOpen Query Tool" -ForegroundColor Cyan
    Write-Host "============================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage: .\Query.ps1 -Sql ""YOUR SQL HERE"" [-Db database]"
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Yellow
    Write-Host '  .\Query.ps1 -Sql "SELECT * FROM pcde_working_memory"'
    Write-Host '  .\Query.ps1 -Sql "SELECT * FROM pcde_ai_memory"'
    Write-Host ""
    exit
}

$body = @{
    token = $token
    db = $Db
    sql = $Sql
    params = @()
} | ConvertTo-Json

Write-Host "Executing on $Db..." -ForegroundColor Cyan
Write-Host "SQL: $Sql" -ForegroundColor Yellow

try {
    $response = Invoke-RestMethod -Uri $endpoint -Method Post -Body $body -ContentType "application/json" -ErrorAction Stop
    Write-Host "`n✅ Success!" -ForegroundColor Green
    $response | ConvertTo-Json -Depth 10
}
catch {
    Write-Host "`n❌ Error:" -ForegroundColor Red
    Write-Host $_.Exception.Message
    
    # Try to get the actual response
    if ($_.Exception.Response) {
        $stream = $_.Exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $responseBody = $reader.ReadToEnd()
        Write-Host "`nResponse body:" -ForegroundColor Yellow
        Write-Host $responseBody
    }
}
'@ | Out-File -FilePath Query.ps1 -Encoding utf8 -Force

Write-Host "✅ Query.ps1 updated" -ForegroundColor Green