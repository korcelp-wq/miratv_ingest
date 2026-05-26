# Get all affected records
$records = .\Query.ps1 @"
SELECT procedure_id, source_path 
FROM pcde_procedure_registry 
WHERE source_path LIKE '%Users\Korce\Downloads%' OR source_path LIKE '%/mnt/data/%'
"@

# Update each one individually
foreach ($row in $records.rows) {
    $oldPath = $row.source_path
    $newPath = $oldPath -replace 'C:\\Users\\Korce\\Downloads\\public_html \(2\)\\public_html', 'https://miratv.club'
    $newPath = $newPath -replace '\\', '/'
    $newPath = $newPath -replace '/mnt/data/', 'https://miratv.club/'
    
    $updateSql = "UPDATE pcde_procedure_registry SET source_path = '$newPath' WHERE procedure_id = $($row.procedure_id)"
    .\Query.ps1 -Sql $updateSql
    Write-Host "Updated: $($row.procedure_id) -> $newPath" -ForegroundColor Green
}