# Publish Context Reports - Scheduled Trigger
# Purpose: Generate and publish formatted context reports for human review
# Frequency: Can be scheduled daily, weekly, or on-demand
# Status: Published reports are tracked with version and authority

param(
    [Parameter(Mandatory=$false)]
    [string]$Component = "ALL",
    
    [Parameter(Mandatory=$false)]
    [string]$Database = "ops",
    
    [Parameter(Mandatory=$false)]
    [string]$Token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY",
    
    [Parameter(Mandatory=$false)]
    [string]$PublishedBy = "system_scheduled"
)

Write-Host "`n📄 Publishing Context Reports" -ForegroundColor Cyan
Write-Host "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray

$baseUrl = "https://miratv.club/_workers/ai/execute_sql.php"

# List of all components to publish
$components = @(
    "Grinder / Ingest Pipeline",
    "Ops / Orchestration",
    "Database (Authority)",
    "Governance / IGM",
    "CVI / AI Interface",
    "Android Client",
    "Human Operator"
)

if ($Component -ne "ALL") {
    $components = @($Component)
}

# Publish each component's context
foreach ($comp in $components) {
    $sql = "CALL sp_publish_context_report('$comp', '$PublishedBy');"
    
    try {
        $response = Invoke-WebRequest -Uri $baseUrl `
            -Method POST `
            -Headers @{ "Authorization" = "Bearer $Token" } `
            -Body @{
                db = $Database
                sql = $sql
            } `
            -ErrorAction Stop
        
        $result = $response.Content | ConvertFrom-Json
        
        if ($result.error) {
            Write-Host "  ❌ $comp - Error: $($result.message)" -ForegroundColor Red
        } else {
            Write-Host "  ✓ $comp - Published" -ForegroundColor Green
        }
    }
    catch {
        Write-Host "  ❌ $comp - Connection error: $_" -ForegroundColor Red
    }
}

# Get publication status
Write-Host "`n📊 Publication Status:" -ForegroundColor Cyan

$statusSql = "CALL sp_get_publication_status();"

try {
    $response = Invoke-WebRequest -Uri $baseUrl `
        -Method POST `
        -Headers @{ "Authorization" = "Bearer $Token" } `
        -Body @{
            db = $Database
            sql = $statusSql
        } `
        -ErrorAction Stop
    
    $result = $response.Content | ConvertFrom-Json
    
    if ($result.error) {
        Write-Host "Error retrieving status: $($result.message)" -ForegroundColor Red
    } else {
        foreach ($row in $result.rows) {
            $icon = if ($row.report_status -eq "published") { "✓" } else { "⏳" }
            Write-Host "  $icon $($row.component_name): $($row.report_count) $($row.report_status)" -ForegroundColor Gray
        }
    }
}
catch {
    Write-Host "Error: $_" -ForegroundColor Red
}

Write-Host "`n✓ Context publish cycle complete" -ForegroundColor Green
