# Create a clean module file
$cleanModule = @'
# DogOpenClient.psm1
# Simple, reliable client for dog_open.php

$script:DefaultToken = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
$script:Endpoint = "https://miratv.club/_workers/api/series/dog_open.php"

function Invoke-DogOpenQuery {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Sql,
        
        [string]$Db = "xpdgxfsp_pcde_memory",
        
        [array]$Params = @(),
        
        [string]$Token = $script:DefaultToken
    )
    
    $body = @{
        token = $Token
        db = $Db
        sql = $Sql
        params = $Params
    } | ConvertTo-Json
    
    Write-Host "Executing on $Db..." -ForegroundColor Cyan
    Write-Host "SQL: $Sql" -ForegroundColor Yellow
    
    try {
        $response = Invoke-RestMethod -Uri $script:Endpoint -Method Post -Body $body -ContentType "application/json" -ErrorAction Stop
        Write-Host "Success!" -ForegroundColor Green
        return $response
    }
    catch {
        Write-Host "Error: $_" -ForegroundColor Red
        if ($_.Exception.Response) {
            $stream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $responseBody = $reader.ReadToEnd()
            Write-Host "Response body: $responseBody" -ForegroundColor Yellow
        }
        throw
    }
}

function Show-DogOpenTables {
    param([string]$Db = "xpdgxfsp_pcde_memory")
    $result = Invoke-DogOpenQuery -Db $Db -Sql "SHOW TABLES"
    if ($result.rows) {
        Write-Host "`nTables in $Db:" -ForegroundColor Cyan
        $result.rows | ForEach-Object { 
            $_.values[0]
        }
    }
    return $result
}

Export-ModuleMember -Function Invoke-DogOpenQuery, Show-DogOpenTables
'@

$cleanModule | Out-File -FilePath C:\miratv_ingest\modules\DogOpenClient.psm1 -Encoding utf8 -Force

Write-Host "✅ Module fixed" -ForegroundColor Green