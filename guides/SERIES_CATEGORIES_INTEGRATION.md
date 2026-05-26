# Series Categories Integration Guide

## Quick Start (TL;DR)

**For production deployment, follow these 3 steps:**

1. **Upload and execute schema** (on server):
   ```bash
   scp AI_WORKERS/sql/series_categories_schema.sql xpdgxfsp@miratv.club:~/
   ssh xpdgxfsp@miratv.club
   mysql -u xpdgxfsp_content -p xpdgxfsp_content < series_categories_schema.sql
   ```

2. **Populate data** (execute these procedures):
   ```sql
   CALL sp_populate_category_concepts();
   CALL sp_map_series_to_categories();
   CALL sp_auto_map_category_concepts();
   ```

3. **Verify** (check data exists):
   ```sql
   SELECT COUNT(*) FROM category_concepts;  -- Should be > 0
   SELECT COUNT(*) FROM series_category_map; -- Should be > 0
   CALL sp_get_series_categories();          -- Should return categories
   ```

Then continue with [Server Deployment](#server-deployment) and [Android Integration](#android-integration) below.

---

## Overview
This guide documents the end-to-end integration of series categories from stored procedure to Android UI.

## Architecture Flow
```
MySQL Stored Procedure
  ↓ (sp_get_series_categories)
PHP Endpoint
  ↓ (_workers/api/series/concepts.php)
Retrofit Service
  ↓ (WorkersSeriesService.getSeriesConcepts)
Repository
  ↓ (XtreamRepository.getCategories)
Activity
  ↓ (SeriesCategoriesActivity)
RecyclerView Adapter
  ↓ (SeriesCategoriesAdapter)
User Interface
```

## Database Setup

### Automated Deployment (PowerShell)

Use the provided deployment script for automated setup:

```powershell
# From project root
.\deploy_series_categories.ps1

# Or skip SCP upload if file already on server
.\deploy_series_categories.ps1 -SkipUpload
```

The script will:
1. Upload schema file via SCP
2. Execute schema deployment
3. Run all setup procedures
4. Verify data was populated

### Real Endpoints

The API is accessible at:

**Get Categories:**
```
https://miratv.club/_workers/api/series/concepts.php?token=WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY
```

**Get Series by Category:**
```
https://miratv.club/_workers/api/series/by_concepts.php?token=WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY&category_id=1&limit=20&offset=0
```

---

### Manual Deployment (Step-by-Step)

If you prefer manual steps, follow below:

### Step 1: Upload Schema File to Server

Copy `AI_WORKERS/sql/series_categories_schema.sql` to your shared hosting:

**Option A: SCP (Recommended)**
```powershell
scp AI_WORKERS/sql/series_categories_schema.sql \
  xpdgxfsp@miratv.club:/home/xpdgxfsp/series_categories_schema.sql
```

**Option B: Upload via FTP/File Manager**
1. Connect to `miratv.club` via FTP
2. Upload `series_categories_schema.sql` to `/home/xpdgxfsp/`
3. SSH/Terminal will access it from there

### Step 2: Deploy Schema and Stored Procedures

SSH into your shared hosting and run:

```bash
# Login to server
ssh xpdgxfsp@miratv.club

# Navigate to home directory
cd ~

# Execute schema deployment
mysql -u xpdgxfsp_content -p xpdgxfsp_content < series_categories_schema.sql

# When prompted, enter your MySQL password
```

This creates:
- ✅ `category_concepts` table (stores Drama, Comedy, Action, etc.)
- ✅ `series_category_map` table (many-to-many series ↔ categories)
- ✅ `category_concept_map` table (concept relationships)
- ✅ `sp_get_series_categories()` stored procedure
- ✅ `sp_get_series_by_category(id, limit, offset)` stored procedure
- ✅ Setup procedures for automated population

### Step 3: Verify Schema Deployment

Confirm tables were created:

```bash
mysql -u xpdgxfsp_content -p xpdgxfsp_content << EOF
SHOW TABLES LIKE 'category%';
SHOW PROCEDURES LIKE 'sp_get_series%';
EOF
```

Expected output:
```
Tables_in_xpdgxfsp_content (category%)
category_concepts
category_concept_map
series_category_map

Procedures (sp_get_series%)
sp_get_series_categories
sp_get_series_by_category
```

### Step 4: Populate Categories from Existing Series Data

The series table already contains genre/category data. Run the setup procedures to extract and map:

```bash
mysql -u xpdgxfsp_content -p xpdgxfsp_content << EOF
-- 1. Extract unique genres from series table as category concepts
CALL sp_populate_category_concepts();

-- 2. Map each series to its corresponding category
CALL sp_map_series_to_categories();

-- 3. Create concept-to-category relationships
CALL sp_auto_map_category_concepts();
EOF
```

**What these do:**
- `sp_populate_category_concepts()` → Extracts `DISTINCT genre` from `series` table, inserts into `category_concepts`
- `sp_map_series_to_categories()` → Joins series.genre with category_concepts.display_name, populates `series_category_map`
- `sp_auto_map_category_concepts()` → Creates 1:1 mapping in `category_concept_map` for simple queries

Each procedure returns `ROW_COUNT()` showing how many rows were inserted:
```
concepts_added: 15
mappings_added: 892
concept_mappings_added: 15
```

### Step 5: Verify Data Population

Check that categories were populated:

```sql
-- Count categories
SELECT COUNT(*) AS total_categories FROM category_concepts;

-- List all categories
SELECT id, display_name FROM category_concepts ORDER BY display_name;

-- Check series mappings
SELECT COUNT(*) AS total_mappings FROM series_category_map;

-- Spot check: Get first category with series count
SELECT 
  cc.id,
  cc.display_name,
  COUNT(scm.series_id) AS series_count
FROM category_concepts cc
LEFT JOIN series_category_map scm ON scm.category_id = cc.id
GROUP BY cc.id
ORDER BY series_count DESC
LIMIT 5;
```

Expected output (example):
```
id | display_name | series_count
1  | Drama        | 287
2  | Action       | 156
3  | Comedy       | 89
4  | Thriller     | 72
5  | Documentary  | 45
```

### Step 6: Test Stored Procedures

Run a quick test to ensure procedures return data:

```sql
-- Test: Get all categories
CALL sp_get_series_categories();

-- Test: Get series in first category (ID = 1)
CALL sp_get_series_by_category(1, 5, 0);
```

You should see categories and series results.

---

## Deployment Checklist

Before moving to PHP/Android integration:

- [ ] SQL schema deployed to `xpdgxfsp_content` database
- [ ] All 6 tables exist: `category_concepts`, `series_category_map`, `category_concept_map`, etc.
- [ ] All stored procedures created: `sp_get_series_categories()`, `sp_get_series_by_category()`, setup procedures
- [ ] Setup procedures executed:
  - [ ] `sp_populate_category_concepts()` completed
  - [ ] `sp_map_series_to_categories()` completed
  - [ ] `sp_auto_map_category_concepts()` completed
- [ ] Category count > 0: `SELECT COUNT(*) FROM category_concepts;`
- [ ] Series mappings > 0: `SELECT COUNT(*) FROM series_category_map;`
- [ ] Test procedures return data: `CALL sp_get_series_categories();`

## Server Deployment

### 1. Upload PHP Endpoints

Upload both endpoint files to your server:

```bash
scp server_files/_workers/api/series/concepts.php \
  xpdgxfsp@miratv.club:/home/xpdgxfsp/public_html/_workers/api/series/

scp server_files/_workers/api/series/by_concepts.php \
  xpdgxfsp@miratv.club:/home/xpdgxfsp/public_html/_workers/api/series/
```

Ensure correct permissions:
```bash
chmod 644 /home/xpdgxfsp/public_html/_workers/api/series/*.php
```

### 2. Verify Endpoints

Test both endpoints:

**Get Categories:**
```bash
curl "https://miratv.club/_workers/api/series/concepts.php?token=WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
```

Expected response:
```json
[
  {"id": 1, "name": "Drama"},
  {"id": 2, "name": "Comedy"},
  {"id": 3, "name": "Action"}
]
```

**Get Series by Category (ID=1):**
```bash
curl "https://miratv.club/_workers/api/series/by_concepts.php?token=WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY&category_id=1&limit=5&offset=0"
```

Expected response:
```json
[
  {"id": 42, "name": "Breaking Bad", "poster": "http://..."},
  {"id": 43, "name": "The Crown", "poster": "http://..."}
]
```

### 3. Configure Token

Token is set to `WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY` in:
- `concepts.php` (line 16)
- `by_concepts.php` (line 16)
- `XtreamRepository.kt` (line 13)

Update token in:
- `concepts.php` (line 16): `$valid_token = 'WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY';`
- `by_concepts.php` (line 16): `$valid_token = 'WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY';`
- `XtreamRepository.kt` (line 13): `private const val WORKERS_API_TOKEN = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"`

**Production**: If token needs to change, update all three locations.

## Android Integration

### Components Updated

1. **WorkersSeriesService.kt** (interface)
   - Defines Retrofit endpoint for `/_workers/api/series/concepts.php`
   - Returns `List<AppModels.SeriesCategory>`

2. **XtreamRepository.kt** (data layer)
   - Added `workersApi: WorkersSeriesService` parameter
   - Implemented `getCategories()` calling `workersApi.getSeriesConcepts()`
   - Added `companion object` with `create()` factory method

3. **SeriesCategoriesActivity.kt** (UI layer)
   - Creates repository via `XtreamRepository.create(session)`
   - Calls `repo.getCategories()` in coroutine
   - Submits results to adapter

### Data Flow Mapping

**Database → API:**
```sql
sp_get_series_categories()
→ SELECT id, display_name FROM category_concepts
```

**API → JSON:**
```php
$categories = $stmt->fetchAll(PDO::FETCH_ASSOC);
return [
  'id' => (int)$row['id'],
  'name' => $row['display_name']
];
```

**JSON → Kotlin:**
```kotlin
data class SeriesCategory(
    val id: Int,
    val name: String
)
```

## Testing

### End-to-End Test

1. **Database Test:**
   ```sql
   CALL sp_get_series_categories();
   -- Should return at least 3 categories
   ```

2. **API Test:**
   ```bash
   curl -i "https://miratv.club/_workers/api/series/concepts.php?token=miratv_worker_token_2025"
   # Should return HTTP 200 with JSON array
   ```

3. **Android Test:**
   - Launch app
   - Navigate to Series → Categories
   - Verify categories display in RecyclerView
   - Click category → should navigate to SeriesListActivity with `catId`

### Debugging

**No Categories Display:**
- Check LogCat for exceptions in `SeriesCategoriesActivity`
- Verify network permission in AndroidManifest.xml
- Test API endpoint directly with curl
- Check token matches in both PHP and Kotlin

**HTTP 401 Unauthorized:**
- Token mismatch between `concepts.php` and `XtreamRepository`
- Token parameter not passed correctly (`?token=VALUE`)

**HTTP 500 Error:**
- Check PHP error logs: `/home/xpdgxfsp/public_html/_workers/api/series/error_log`
- Verify stored procedure exists: `SHOW PROCEDURE STATUS WHERE Name = 'sp_get_series_categories';`
- Check database connection in `db_sql.php`

**Empty Result:**
- Run setup procedures: `CALL sp_populate_category_concepts();`
- Check categories exist: `SELECT COUNT(*) FROM category_concepts;`

## Security Considerations

### Token Management

**Current:** Hardcoded token in source files (development only)

**Production:**
- Store token in `local.properties` (excluded from git)
- Load via `BuildConfig.WORKERS_API_TOKEN`
- Rotate monthly
- Implement token expiration on server

### API Security

**Current:** Simple token authentication

**Production:**
- Add HTTPS-only enforcement
- Implement rate limiting (max 100 req/min per token)
- Add CORS headers if web client needed
- Log all requests with timestamp and IP

### Data Validation

**Current:** Direct SQL execution

**Production:**
- Add input sanitization for future endpoints with parameters
- Validate category_id in `sp_get_series_by_category()`
- Implement pagination limits (max 100 per page)

## Future Enhancements

### Phase 1: Series Drill-Down
- Implement `sp_get_series_by_category()` integration
- Update `SeriesListActivity` to filter by `catId`
- Add "All Series" option (catId = 0)

### Phase 2: Caching
- Add Room database caching
- Implement cache expiration (24h)
- Background sync with WorkManager

### Phase 3: Advanced Features
- Search within categories
- Sort options (A-Z, Recently Added, Popular)
- Category icons/posters
- Multi-select category filters

## Troubleshooting Checklist

Before asking for help, verify:

- [ ] Database schema deployed successfully
- [ ] Stored procedure exists and returns data
- [ ] PHP endpoint accessible via curl
- [ ] Token matches in PHP and Kotlin
- [ ] Network permission in AndroidManifest
- [ ] Session has valid credentials
- [ ] LogCat shows no compilation errors
- [ ] Adapter receives non-empty list

## Related Files

**Database:**
- `AI_WORKERS/sql/series_categories_schema.sql`

**Server:**
- `server_files/_workers/api/series/concepts.php`
- `public_html/db_sql.php` (database connection)

**Android:**
- `app/src/main/java/com/miratv/app/api/WorkersSeriesService.kt`
- `app/src/main/java/com/miratv/app/xtream/XtreamRepository.kt`
- `app/src/main/java/com/miratv/app/ui/series/SeriesCategoriesActivity.kt`
- `app/src/main/java/com/miratv/app/models/AppModels.kt`

## Contact

For issues or questions, reference this guide and provide:
- SQL test results (`CALL sp_get_series_categories();`)
- Curl test results (API endpoint)
- LogCat output (Android errors)
- Specific error message

## Changelog

- 2025-01-28: Initial integration completed
  - Created stored procedure
  - Created PHP endpoint
  - Updated Android repository and activity
  - Added factory method for easy instantiation
