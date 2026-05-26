# Querys.ps1 - Simple PowerShell SQL Query Runner
# Usage: .\Querys.ps1 -Db <database> -Sql "<query>"
param(
    [Parameter(Mandatory=$true)]
    [string]$Db,
    [Parameter(Mandatory=$true)]
    [string]$Sql
)

# Set your MySQL credentials here (or use a secure method in production)
$MySqlUser = "root"
$MySqlPass = "password"
$MySqlHost = "localhost"

# Build the MySQL command
$cmd = "mysql -h $MySqlHost -u $MySqlUser -p$MySqlPass $Db -e \"$Sql\""

Write-Host "Running: $cmd"

try {
    $output = Invoke-Expression $cmd
    Write-Output $output
} catch {
    Write-Error "Failed to execute query: $_"
}
