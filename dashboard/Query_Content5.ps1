#!/usr/bin/env pwsh
# Simple standalone query tool for dog_open.php

param(
    [string]$Sql,
    [string]$Db = "content"
)

$token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$endpoint = "https://miratv.club/_workers/api/series/dog_open.php"

if ([string]::IsNullOrWhiteSpace($Sql)) {
    Write-Host "`n🐕 MiraTV DogOpen Query Tool" -ForegroundColor Cyan
    Write-Host "============================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage: .\Query_Content.ps1 -Sql `"YOUR SQL HERE`" [-Db database]"
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Yellow
    Write-Host '  .\Query_Content.ps1 -Sql "SELECT * FROM series LIMIT 5"'
    Write-Host '  .\Query_Content.ps1 -Sql "SELECT * FROM vod LIMIT 5"'
    Write-Host ""
    exit
}

$body = @{
    token  = $token
    db     = $Db
    sql    = $Sql
    params = @()
} | ConvertTo-Json

Write-Host "Executing on $Db..." -ForegroundColor Cyan
Write-Host "SQL: $Sql" -ForegroundColor Yellow

try {
    $response = Invoke-RestMethod `
        -Uri $endpoint `
        -Method Post `
        -Body $body `
        -ContentType "application/json" `
        -ErrorAction Stop

    Write-Host "`n✅ Success!" -ForegroundColor Green

    if ($null -eq $response) {
        return
    }

    # If dog_open.php returns rows directly
    if ($response -is [System.Collections.IEnumerable] -and $response -isnot [string]) {
        $response
        return
    }

    # Common wrapped shapes
    if ($response.PSObject.Properties.Name -contains 'rows') {
        $response.rows
        return
    }

    if ($response.PSObject.Properties.Name -contains 'data') {
        $response.data
        return
    }

    if ($response.PSObject.Properties.Name -contains 'result') {
        $response.result
        return
    }

    # Fallback: emit raw response object
    $response
}
catch {
    Write-Host "`n❌ Error:" -ForegroundColor Red
    Write-Host $_.Exception.Message

    if ($_.Exception.Response) {
        $stream = $_.Exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $responseBody = $reader.ReadToEnd()
        Write-Host "`nResponse body:" -ForegroundColor Yellow
        Write-Host $responseBody
    }
}