#!/usr/bin/env pwsh

param(
    [Parameter(Mandatory = $true)]
    [string]$Db,

    [Parameter(Mandatory = $true)]
    [string]$Sql,

    [string]$Endpoint = "https://miratv.club/_workers/api/series/dog_open.php",

    [string]$Token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY",

    [object[]]$Params = @(),

    [int]$TimeoutSec = 30,

    [switch]$Raw,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param(
        [string]$Message,
        [string]$Color = "DarkGray"
    )
    if (-not $Quiet) {
        Write-Host $Message -ForegroundColor $Color
    }
}

try {
    $bodyObject = @{
        token  = $Token
        db     = $Db
        sql    = $Sql
        params = $Params
    }

    $bodyJson = $bodyObject | ConvertTo-Json -Depth 20 -Compress

    Write-Step "[QUERY] Endpoint: $Endpoint"
    Write-Step "[QUERY] DB: $Db"
    Write-Step "[QUERY] SQL: $Sql"

    if (-not $Quiet) {
        Write-Step "[QUERY] JSON Body:"
        Write-Host $bodyJson -ForegroundColor DarkCyan
    }

    $response = Invoke-RestMethod `
        -Uri $Endpoint `
        -Method Post `
        -ContentType "application/json" `
        -Body $bodyJson `
        -TimeoutSec $TimeoutSec

    if ($Raw) {
        if ($response -is [string]) {
            Write-Output $response
        } else {
            $response | ConvertTo-Json -Depth 50
        }
        exit 0
    }

    if ($null -eq $response) {
        Write-Step "[WARN] Response was null." "Yellow"
        exit 0
    }

    if ($response -is [string]) {
        Write-Output $response
        exit 0
    }

    $response | ConvertTo-Json -Depth 50
    exit 0
}
catch {
    Write-Host "[ERROR] Query failed." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red

    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
        Write-Host $_.ErrorDetails.Message -ForegroundColor DarkRed
    }

    exit 1
}