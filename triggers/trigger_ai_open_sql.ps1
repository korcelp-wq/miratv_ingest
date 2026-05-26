param(
    [string]$Token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY",
    [string]$Db = "content",
    [string]$Sql = "SELECT 1;",
    [string]$Endpoint = "https://miratv.club/_workers/api/series/dog_open.php",
    [string[]]$Params = @()
)

$body = @{
    token  = $Token
    db     = $Db
    sql    = $Sql
    params = $Params
} | ConvertTo-Json -Depth 5

Write-Host "POST $Endpoint" -ForegroundColor Cyan

$response = Invoke-RestMethod -Method Post -Uri $Endpoint -ContentType 'application/json' -Body $body
$response | ConvertTo-Json -Depth 10
