# Series Categories Deployment Troubleshooting

## Issues During Database Setup

### Issue: "mysql: command not found"
**Symptom:** SSH to server returns `mysql: command not found`

**Cause:** MySQL client not in PATH or not installed

**Solution:**
```bash
# Try full path
/usr/bin/mysql -u xpdgxfsp_content -p xpdgxfsp_content < series_categories_schema.sql

# Or check if available
which mysql
which mariadb
```

---

### Issue: "Access denied for user 'xpdgxfsp_content'"
**Symptom:** `ERROR 1045 (28000): Access denied for user 'xpdgxfsp_content'@'localhost'`

**Cause:** Wrong password or wrong database user

**Solution:**
```bash
# Use cPanel credentials (may be different from xpdgxfsp)
# Check cPanel → Database Access or phpmyadmin

# Try with root if you have it
mysql -u root -p -e "USE xpdgxfsp_content; SHOW TABLES;"

# Or check what databases you have
mysql -u xpdgxfsp_content -p -e "SHOW DATABASES;"
```

---

### Issue: "Table 'xpdgxfsp_content.category_concepts' doesn't exist"
**Symptom:** Procedures exist but running them gives table not found error

**Cause:** Schema deployment didn't complete successfully

**Solution:**
```sql
-- Check what tables exist
SHOW TABLES;

-- If missing, re-run schema file
-- Or manually create one table:
CREATE TABLE `category_concepts` (
  `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `display_name` VARCHAR(128) NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_display_name` (`display_name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

---

### Issue: "Procedure sp_populate_category_concepts does not exist"
**Symptom:** `ERROR 1305 (42000): PROCEDURE ... does not exist`

**Cause:** Schema deployment didn't create procedures (delimiter issues)

**Solution:**
1. Check if procedures exist:
   ```sql
   SHOW PROCEDURES LIKE 'sp_%';
   ```

2. If empty, manually create procedure:
   ```sql
   DELIMITER $$
   CREATE PROCEDURE `sp_populate_category_concepts`()
   BEGIN
     INSERT IGNORE INTO category_concepts (display_name)
     SELECT DISTINCT TRIM(genre) AS display_name
     FROM series
     WHERE genre IS NOT NULL AND genre != ''
     ORDER BY genre;
     
     SELECT ROW_COUNT() AS concepts_added;
   END$$
   DELIMITER ;
   ```

---

### Issue: "Procedures executed but categories_concepts is empty"
**Symptom:** Tables created, procedures run, but no data in category_concepts

**Cause:** Series table doesn't have genre data, or genre field has different name

**Solution:**
```sql
-- Check if series table exists and has genre field
SHOW COLUMNS FROM series;

-- If genre doesn't exist, check what fields do
-- Common alternatives: category, type, classification, tag

-- If genre has data, manually insert a test category:
INSERT INTO category_concepts (display_name) VALUES ('Drama');
INSERT INTO category_concepts (display_name) VALUES ('Comedy');

-- Then run mapping procedure
CALL sp_map_series_to_categories();
```

---

## Issues During PHP Endpoint Deployment

### Issue: "HTTP 401 Unauthorized"
**Symptom:** Endpoint returns 401 when called

**Cause:** Token mismatch between PHP and client

**Solution:**
```php
// In concepts.php, verify token line 14:
$valid_token = 'miratv_worker_token_2025';

// Make sure you're calling with matching token:
curl "https://miratv.club/_workers/api/series/concepts.php?token=miratv_worker_token_2025"

// Check if token is passed correctly
```

---

### Issue: "HTTP 500 Internal Server Error"
**Symptom:** Endpoint returns 500 error

**Cause:** PHP error, database connection, or stored procedure issue

**Solution:**
```bash
# Check PHP error log on server
tail -f /home/xpdgxfsp/public_html/_workers/api/series/error_log

# Or check general error log
tail -f /home/xpdgxfsp/public_html/error_log

# Manually test stored procedure in MySQL:
mysql -u xpdgxfsp_content -p xpdgxfsp_content -e "CALL sp_get_series_categories();"
```

---

### Issue: "HTTP 200 but empty response: []"
**Symptom:** Endpoint returns 200 status but empty JSON array

**Cause:** No categories in database or procedure not returning data

**Solution:**
```sql
-- Verify categories exist
SELECT COUNT(*) FROM category_concepts;

-- If empty, run population procedures
CALL sp_populate_category_concepts();

-- Test procedure returns data
CALL sp_get_series_categories();

-- Should return rows like:
-- id | display_name
-- 1  | Drama
-- 2  | Comedy
```

---

## Issues During Android Integration

### Issue: "SeriesCategoriesActivity crashes: NullPointerException"
**Symptom:** App crashes with NPE in SeriesCategoriesActivity

**Cause:** Repository or API call failed

**Solution:**
```kotlin
// Add detailed logging in SeriesCategoriesActivity
lifecycleScope.launch {
    try {
        Log.d("SeriesCategories", "Fetching categories...")
        val categories = repo.getCategories()
        Log.d("SeriesCategories", "Got ${categories.size} categories")
        adapter.submitList(categories)
    } catch (t: Throwable) {
        Log.e("SeriesCategories", "Error: ${t.message}", t)
        t.printStackTrace()
    }
}
```

Then check LogCat for actual error message.

---

### Issue: "API call returns 404"
**Symptom:** Retrofit returns 404 when calling endpoint

**Cause:** Wrong base URL or endpoint path

**Solution:**
```kotlin
// In XtreamRepository.create():
val baseUrl = session.getXtreamBaseUrl() ?: "https://cpanel.miratv.club/"

// Verify full URL:
// Base: https://cpanel.miratv.club/
// Endpoint: _workers/api/series/concepts.php?token=TOKEN
// Full: https://cpanel.miratv.club/_workers/api/series/concepts.php?token=TOKEN

// Test in browser:
// https://miratv.club/_workers/api/series/concepts.php?token=miratv_worker_token_2025
```

---

### Issue: "WorkersSeriesService not found"
**Symptom:** Compilation error: Unresolved reference: WorkersSeriesService

**Cause:** Missing interface definition

**Solution:**
```kotlin
// Create if missing: 
// app/src/main/java/com/miratv/app/api/WorkersSeriesService.kt

package com.miratv.app.api

import com.miratv.app.models.AppModels
import retrofit2.http.GET
import retrofit2.http.Query

interface WorkersSeriesService {
    @GET("_workers/api/series/concepts.php")
    suspend fun getSeriesConcepts(
        @Query("token") token: String
    ): List<AppModels.SeriesCategory>
}
```

---

## Verification Checklist

Before assuming there's a problem, verify:

- [ ] MySQL schema deployed: `SHOW TABLES LIKE 'category%';`
- [ ] Procedures created: `SHOW PROCEDURES LIKE 'sp_get_series%';`
- [ ] Category data exists: `SELECT COUNT(*) FROM category_concepts;` > 0
- [ ] Series mappings exist: `SELECT COUNT(*) FROM series_category_map;` > 0
- [ ] Procedure returns data: `CALL sp_get_series_categories();` has rows
- [ ] PHP endpoint accessible: `curl https://miratv.club/_workers/api/series/concepts.php?token=...`
- [ ] PHP endpoint returns JSON: `curl -H "Content-Type: application/json" ...`
- [ ] Token matches in PHP and Kotlin
- [ ] Network permission in AndroidManifest.xml
- [ ] Session has valid credentials before API call

---

## Support Information

When reporting issues, provide:

1. **Database status:**
   ```sql
   SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES 
   WHERE TABLE_SCHEMA = 'xpdgxfsp_content' 
   AND TABLE_NAME LIKE 'category%' OR TABLE_NAME LIKE 'series_category%';
   ```

2. **Procedure status:**
   ```sql
   SHOW PROCEDURES LIKE 'sp_%';
   ```

3. **Data counts:**
   ```sql
   SELECT 
     (SELECT COUNT(*) FROM category_concepts) AS categories,
     (SELECT COUNT(*) FROM series_category_map) AS mappings;
   ```

4. **API response:**
   ```bash
   curl -v "https://miratv.club/_workers/api/series/concepts.php?token=TOKEN"
   ```

5. **LogCat output (Android):**
   ```
   adb logcat | grep SeriesCategories
   ```

Include all of this when asking for help!
