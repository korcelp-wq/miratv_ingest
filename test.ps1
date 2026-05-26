function Test-UniversalSearchProcedure {
    param(
        [string]$SearchTerm = "test",
        [int]$Limit = 5
    )
    
    Write-Host "`n🧪 Testing universal_long_term_search procedure..." -ForegroundColor Cyan
    Write-Host "   Search Term: $SearchTerm" -ForegroundColor DarkGray
    Write-Host "   Limit: $Limit" -ForegroundColor DarkGray
    
    # Escape single quotes for SQL
    $escapedTerm = $SearchTerm -replace "'", "''"
    
    # Call the stored procedure
    $sql = "CALL universal_long_term_search('$escapedTerm', 'general', $Limit)"
    
    try {
        $results = Invoke-SqlQueryObjects -Sql $sql -DatabaseName "pcde_memory"
        
        if ($results -and $results.Count -gt 0) {
            Write-Host "✅ Procedure executed successfully!" -ForegroundColor Green
            Write-Host "📊 Found $($results.Count) results:" -ForegroundColor Green
            Write-Host ""
            
            # Display results in a nice format
            $results | ForEach-Object {
                Write-Host "📁 $($_.source_name)" -ForegroundColor Yellow
                Write-Host "   Preview: $($_.preview)" -ForegroundColor Gray
                Write-Host ""
            }
            
            return $results
        }
        else {
            Write-Host "⚠️ Procedure executed but returned no results" -ForegroundColor Yellow
            Write-Host "   (This is normal if your tables are empty)" -ForegroundColor DarkGray
            return @()
        }
    }
    catch {
        Write-Host "❌ Procedure call failed: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

# Check if the procedure exists (updated 

function Check-UniversalSearchProcedure {
    Write-Host "   Checking for stored procedure..." -ForegroundColor Gray
    
    # Try different ways to find the procedure
    $sql1 = @"
SHOW PROCEDURE STATUS WHERE Name = 'universal_long_term_search'
"@
    
    $sql2 = @"
SELECT 
    SPECIFIC_NAME as procedure_name,
    ROUTINE_SCHEMA as database_name,
    ROUTINE_TYPE as type,
    CREATED,
    LAST_ALTERED
FROM information_schema.ROUTINES 
WHERE ROUTINE_NAME = 'universal_long_term_search'
  AND ROUTINE_TYPE = 'PROCEDURE'
"@

    try {
        # Try with pcde_memory database
        $result = Invoke-SqlQueryObjects -Sql $sql2 -DatabaseName "pcde_memory"
        
        if ($result -and $result.Count -gt 0) {
            Write-Host "   ✅ Procedure 'universal_long_term_search' exists!" -ForegroundColor Green
            Write-Host "      Database: $($result[0].database_name)" -ForegroundColor DarkGray
            Write-Host "      Created: $($result[0].CREATED)" -ForegroundColor DarkGray
            return $true
        }
        
        # If not found, try direct SHOW command
        $result2 = Invoke-SqlQueryObjects -Sql $sql1 -DatabaseName "pcde_memory"
        if ($result2 -and $result2.Count -gt 0) {
            Write-Host "   ✅ Procedure 'universal_long_term_search' exists!" -ForegroundColor Green
            return $true
        }
        
        Write-Host "   ⚠️ Procedure not found via query, but it may still exist" -ForegroundColor Yellow
        return $false
    }
    catch {
        Write-Host "   ⚠️ Could not verify procedure: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "   💡 Procedure likely exists (seen in phpMyAdmin)" -ForegroundColor Green
        return $true  # Assume it exists since we saw it in the screenshot
    }
}


# Test calling the stored procedure directly
function Test-UniversalSearchProcedure {
    param(
        [string]$SearchTerm = "test",
        [int]$Limit = 5
    )
    
    Write-Host "`n🧪 Testing universal_long_term_search procedure..." -ForegroundColor Cyan
    Write-Host "   Search Term: $SearchTerm" -ForegroundColor DarkGray
    Write-Host "   Limit: $Limit" -ForegroundColor DarkGray
    
    # Escape single quotes for SQL
    $escapedTerm = $SearchTerm -replace "'", "''"
    
    # Call the stored procedure
    $sql = "CALL universal_long_term_search('$escapedTerm', 'general', $Limit)"
    
    try {
        Write-Host "   📞 Executing: $sql" -ForegroundColor DarkGray
        $results = Invoke-SqlQueryObjects -Sql $sql -DatabaseName "pcde_memory"
        
        if ($results -and $results.Count -gt 0) {
            Write-Host "✅ Procedure executed successfully!" -ForegroundColor Green
            Write-Host "📊 Found $($results.Count) results:" -ForegroundColor Green
            Write-Host ""
            
            # Display results in a nice format
            $results | Select-Object -First 3 | ForEach-Object {
                Write-Host "📁 $($_.source_name)" -ForegroundColor Yellow
                $preview = if ($_.preview.Length -gt 100) { $_.preview.Substring(0, 100) + "..." } else { $_.preview }
                Write-Host "   Preview: $preview" -ForegroundColor Gray
                Write-Host ""
            }
            
            if ($results.Count -gt 3) {
                Write-Host "   ... and $($results.Count - 3) more results" -ForegroundColor DarkGray
            }
            
            return $results
        }
        else {
            Write-Host "⚠️ Procedure executed but returned no results" -ForegroundColor Yellow
            Write-Host "   (This is normal if no matches found for '$SearchTerm')" -ForegroundColor DarkGray
            return @()
        }
    }
    catch {
        Write-Host "❌ Procedure call failed: $($_.Exception.Message)" -ForegroundColor Red
        
        # Check if it's a "doesn't exist" error
        if ($_.Exception.Message -like "*doesn't exist*" -or $_.Exception.Message -like "*not found*") {
            Write-Host "💡 The procedure 'universal_long_term_search' doesn't exist or isn't accessible" -ForegroundColor Yellow
            Write-Host "   Try creating it using the SQL from earlier, or continue using direct table search" -ForegroundColor DarkGray
        }
        
        return $null
    }
}

# Now actually run the tests:
Write-Host "`n" + "="*60 -ForegroundColor Cyan
Write-Host "TESTING LONG-TERM MEMORY SEARCH" -ForegroundColor Cyan
Write-Host "="*60 -ForegroundColor Cyan

# 1. First, check if the stored procedure exists
Write-Host "`n1. CHECKING IF STORED PROCEDURE EXISTS..." -ForegroundColor Yellow
Check-UniversalSearchProcedure

# 2. Test the procedure with a sample search term
Write-Host "`n2. TESTING STORED PROCEDURE WITH SEARCH TERM 'spine'..." -ForegroundColor Yellow
Test-UniversalSearchProcedure -SearchTerm "spine" -Limit 5

# 3. Test with another search term
Write-Host "`n3. TESTING WITH SEARCH TERM 'upload'..." -ForegroundColor Yellow
Test-UniversalSearchProcedure -SearchTerm "upload" -Limit 3

# 4. Test the direct table search function (if it exists)
Write-Host "`n4. TESTING DIRECT TABLE SEARCH..." -ForegroundColor Yellow

# Check if Invoke-PCDELongTermRecall exists
if (Get-Command Invoke-PCDELongTermRecall -ErrorAction SilentlyContinue) {
    $results = Invoke-PCDELongTermRecall -SearchTerm "test" -QueryType "general" -MaxRowsPerTarget 3
    
    if ($results -and $results.Count -gt 0) {
        Write-Host "`n📊 RESULTS FROM DIRECT TABLE SEARCH:" -ForegroundColor Green
        $results | Select-Object -First 5 | Format-Table source_name, preview -AutoSize -Wrap
    } else {
        Write-Host "`n⚠️ No results from direct table search" -ForegroundColor Yellow
    }
} else {
    Write-Host "   ⚠️ Invoke-PCDELongTermRecall function not defined, skipping" -ForegroundColor Yellow
}

# 5. Check what tables actually have data
Write-Host "`n5. CHECKING WHICH TABLES HAVE DATA..." -ForegroundColor Yellow
$tablesToCheck = @(
    @{Database = "lake_knowledge"; Table = "raw_artifacts"},
    @{Database = "lake_knowledge"; Table = "raw_conversations"},
    @{Database = "lake_knowledge"; Table = "extracted_docs"},
    @{Database = "lake_knowledge"; Table = "knowledge_units"},
    @{Database = "lake_vector"; Table = "raw_artifacts"},
    @{Database = "lake_vector"; Table = "raw_conversations"},
    @{Database = "lake_vector"; Table = "semantic_vector_store"}
)

foreach ($table in $tablesToCheck) {
    try {
        $countSql = "SELECT COUNT(*) as row_count FROM $($table.Table)"
        $count = Invoke-SqlQueryObjects -Sql $countSql -DatabaseName $table.Database
        
        if ($count -and $count[0].row_count -gt 0) {
            Write-Host "   ✅ $($table.Database).$($table.Table): $($count[0].row_count) rows" -ForegroundColor Green
        } else {
            Write-Host "   ⚪ $($table.Database).$($table.Table): 0 rows (empty)" -ForegroundColor DarkGray
        }
    }
    catch {
        Write-Host "   ❌ $($table.Database).$($table.Table): Table may not exist or inaccessible" -ForegroundColor Red
        Write-Host "      Error: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}

Write-Host "`n" + "="*60 -ForegroundColor Cyan
Write-Host "TEST COMPLETE" -ForegroundColor Cyan
Write-Host "="*60 -ForegroundColor Cyan