#!/usr/bin/env pwsh
# Enhanced query tool for dog_open.php that prints table names

param(
    [string]$Sql,
    [string]$Db = "pcde_memory"
)

$token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$endpoint = "https://miratv.club/_workers/api/series/dog_open.php"

if ([string]::IsNullOrWhiteSpace($Sql)) {
    Write-Host "`MiraTV DogOpen Query Tool" -ForegroundColor Cyan
    Write-Host "============================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage: .\Query2.ps1 -Sql \"YOUR SQL HERE\" [-Db database]"
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Yellow
    Write-Host '  .\Query2.ps1 -Sql "SELECT * FROM pcde_working_memory"'
    Write-Host '  .\Query2.ps1 -Sql "SELECT * FROM pcde_ai_memory"'
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
    if ($response.rows) {
        Write-Host "`nTables:" -ForegroundColor Cyan
        foreach ($row in $response.rows) {
            foreach ($value in $row.Values) {
                Write-Host $value
            }
        }
    }
}
catch {
    Write-Host "Error:" -ForegroundColor Red
    Write-Host $_.Exception.Message
    if ($_.Exception.Response) {
        $stream = $_.Exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $responseBody = $reader.ReadToEnd()
        Write-Host "`nResponse body:" -ForegroundColor Yellow
        Write-Host $responseBody
    }
}
