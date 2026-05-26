param(
    [string]$Db,
    [string]$Sql
)

# Set MySQL connection parameters (edit as needed)
$MySqlHost = "localhost"
$MySqlUser = "root"
$MySqlPass = ""

if (-not $Db -or -not $Sql) {
    Write-Host "Usage: .\QuerySimple.ps1 -Db <database> -Sql <sql>"
    exit 1
}

$cmd = "mysql -h $MySqlHost -u $MySqlUser $Db -e `"$Sql`""

Write-Host "Executing on $Db..."
Write-Host "SQL: $Sql"

try {
    $output = Invoke-Expression $cmd
    Write-Host $output
    Write-Host "\n✅ Success!"
} catch {
    Write-Host "\n❌ Error:"
    Write-Host $_.Exception.Message
    exit 1
}
