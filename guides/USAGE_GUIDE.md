# Xtream API - Usage Guide

## Quick Start

Your Xtream-compatible API is now available at:
```
https://miratv.club/_workers/ai/player_api.php
```

This endpoint mimics the official Xtream Codes API, so your Android client can connect to it without code changes.

---

## Authentication

All requests require username and password:

```
?username=Marina2025&password=3KY586YR
```

### Test Authentication
```bash
curl "https://miratv.club/_workers/ai/player_api.php?username=Marina2025&password=3KY586YR"
```

**Response:**
```json
{
  "user_info": {
    "username": "Marina2025",
    "auth": 1,
    "status": "Active",
    "exp_date": null,
    "is_trial": "0",
    "max_connections": "1"
  },
  "server_info": {
    "url": "http://uxurwymd.eldervpn.xyz:8080",
    "port": "8080",
    "timezone": "America/New_York"
  }
}
```

---

## Live TV Endpoints

### Get Live Categories
Returns all live TV categories (Sports, News, Entertainment, etc.)

```bash
curl "https://miratv.club/_workers/ai/player_api.php?username=Marina2025&password=3KY586YR&action=get_live_categories"
```

**Response:**
```json
[
  {
    "category_id": "1",
    "category_name": "Sports",
    "parent_id": "0"
  },
  {
    "category_id": "2",
    "category_name": "News",
    "parent_id": "0"
  }
]
```

### Get Live Streams (All Channels)
Returns all live channels across all categories

```bash
curl "https://miratv.club/_workers/ai/player_api.php?username=Marina2025&password=3KY586YR&action=get_live_streams"
```

### Get Live Streams (By Category)
Filter channels by category

```bash
curl "https://miratv.club/_workers/ai/player_api.php?username=Marina2025&password=3KY586YR&action=get_live_streams&category_id=1"
```

**Response:**
```json
[
  {
    "num": 1,
    "name": "ESPN HD",
    "stream_id": "12345",
    "stream_icon": "https://example.com/espn.png",
    "category_id": "1",
    "epg_channel_id": "espn.us",
    "tv_archive": 1,
    "tv_archive_duration": 7
  }
]
```

**Stream URL Format:**
```
https://miratv.club/live/Marina2025/3KY586YR/12345.m3u8
```

---

## VOD (Movies) Endpoints

### Get VOD Categories
Returns all movie categories (Action, Comedy, Drama, etc.)

```bash
curl "https://miratv.club/_workers/ai/player_api.php?username=Marina2025&password=3KY586YR&action=get_vod_categories"
```

### Get VOD Streams (All Movies)
Returns all movies across all categories

```bash
curl "https://miratv.club/_workers/ai/player_api.php?username=Marina2025&password=3KY586YR&action=get_vod_streams"
```

### Get VOD Streams (By Category)
Filter movies by category

```bash
curl "https://miratv.club/_workers/ai/player_api.php?username=Marina2025&password=3KY586YR&action=get_vod_streams&category_id=5"
```

**Response:**
```json
[
  {
    "num": 1,
    "name": "The Matrix",
    "stream_id": "54321",
    "stream_icon": "https://example.com/matrix.jpg",
    "category_id": "5",
    "rating": "8.7",
    "rating_5based": 4.35,
    "container_extension": "mp4"
  }
]
```

**Stream URL Format:**
```
https://miratv.club/movie/Marina2025/3KY586YR/54321.mp4
```

---

## Series (TV Shows) Endpoints

### Get Series Categories
Returns all series categories (Drama, Sci-Fi, Comedy, etc.)

```bash
curl "https://miratv.club/_workers/ai/player_api.php?username=Marina2025&password=3KY586YR&action=get_series_categories"
```

### Get Series List (All Shows)
Returns all TV series across all categories

```bash
curl "https://miratv.club/_workers/ai/player_api.php?username=Marina2025&password=3KY586YR&action=get_series"
```

### Get Series List (By Category)
Filter series by category

```bash
curl "https://miratv.club/_workers/ai/player_api.php?username=Marina2025&password=3KY586YR&action=get_series&category_id=10"
```

**Response:**
```json
[
  {
    "num": 1,
    "name": "Breaking Bad",
    "series_id": "605",
    "cover": "https://example.com/breaking-bad.jpg",
    "plot": "A high school chemistry teacher...",
    "genre": "Crime, Drama, Thriller",
    "rating": "9.5",
    "category_id": "10"
  }
]
```

### Get Series Info (Seasons & Episodes)
Returns detailed information for a specific series, including all seasons and episodes

```bash
curl "https://miratv.club/_workers/ai/player_api.php?username=Marina2025&password=3KY586YR&action=get_series_info&series_id=605"
```

**Response:**
```json
{
  "seasons": [
    {
      "season_number": 1,
      "name": "Season 1",
      "episode_count": 7,
      "air_date": "2008-01-20",
      "cover": "https://example.com/bb-s1.jpg"
    }
  ],
  "info": {
    "name": "Breaking Bad",
    "cover": "https://example.com/breaking-bad.jpg",
    "plot": "A high school chemistry teacher...",
    "genre": "Crime, Drama, Thriller",
    "rating": "9.5"
  },
  "episodes": {
    "1": [
      {
        "id": "98765",
        "episode_num": 1,
        "title": "Pilot",
        "container_extension": "mp4",
        "info": {
          "air_date": "2008-01-20",
          "plot": "Walter White is diagnosed...",
          "duration": "58 min"
        }
      }
    ]
  }
}
```

**Episode Stream URL Format:**
```
https://miratv.club/series/Marina2025/3KY586YR/98765.mp4
```

---

## Android Client Configuration

### Update Base URL in Your App

**File:** `app/src/main/java/com/miratv/app/util/AppConfig.kt` (or wherever base URL is defined)

```kotlin
// Before (using external provider)
private const val BASE_URL = "http://uxurwymd.eldervpn.xyz:8080/"

// After (using your API)
private const val BASE_URL = "https://miratv.club/_workers/ai/"
```

### SessionManager Integration

The API uses the same username/password structure, so your `SessionManager` doesn't need changes:

```kotlin
val username = session.getUsername()  // "Marina2025"
val password = session.getPassword()  // "3KY586YR"
```

### Retrofit Service (No Changes Needed)

Your existing Retrofit interfaces work as-is:

```kotlin
@GET("player_api.php?action=get_live_categories")
suspend fun getLiveCategories(
    @Query("username") username: String,
    @Query("password") password: String
): List<LiveCategory>
```

---

## Testing from PowerShell

Run the included test script:

```powershell
cd c:\Android_Projects\MiraTV_project_PHASES_1_8\server_deploy\_workers\ai
.\test_endpoints.ps1
```

Or test individual endpoints:

```powershell
# Live categories
Invoke-RestMethod "https://miratv.club/_workers/ai/player_api.php?username=Marina2025&password=3KY586YR&action=get_live_categories"

# Series info
Invoke-RestMethod "https://miratv.club/_workers/ai/player_api.php?username=Marina2025&password=3KY586YR&action=get_series_info&series_id=605"
```

---

## Common Use Cases

### 1. Browse Live TV
```
1. GET get_live_categories → Show category list
2. User selects "Sports"
3. GET get_live_streams&category_id=1 → Show channels
4. User selects "ESPN HD" (stream_id=12345)
5. Play: https://miratv.club/live/Marina2025/3KY586YR/12345.m3u8
```

### 2. Browse Movies
```
1. GET get_vod_categories → Show category list
2. User selects "Action"
3. GET get_vod_streams&category_id=5 → Show movies
4. User selects "The Matrix" (stream_id=54321)
5. Play: https://miratv.club/movie/Marina2025/3KY586YR/54321.mp4
```

### 3. Browse TV Series
```
1. GET get_series_categories → Show category list
2. User selects "Drama"
3. GET get_series&category_id=10 → Show series
4. User selects "Breaking Bad" (series_id=605)
5. GET get_series_info&series_id=605 → Show seasons/episodes
6. User selects S01E01 (id=98765)
7. Play: https://miratv.club/series/Marina2025/3KY586YR/98765.mp4
```

---

## Error Responses

### Missing Parameters
```json
{
  "error": "Missing credentials",
  "message": "Username and password are required"
}
```

### Unknown Action
```json
{
  "error": "Unknown action",
  "action": "get_invalid_thing",
  "message": "The specified action is not supported"
}
```

### Database Error
```json
{
  "error": "System error",
  "message": "Unable to process request"
}
```

---

## Rate Limiting & Performance

- **Response Time:** < 100ms for category/list queries
- **Response Time:** < 300ms for series_info (complex nested query)
- **Rate Limit:** Configure in `.htaccess` if needed
- **Caching:** Consider adding Redis/Memcached for high traffic

---

## Security Best Practices

1. **Always use HTTPS** - Never expose credentials over HTTP
2. **Rotate credentials** - Change username/password periodically
3. **Monitor logs** - Watch for unusual access patterns
4. **IP restrictions** - Whitelist known IPs if possible (`.htaccess`)
5. **Token-based auth** - Consider migrating from username/password to tokens

---

## Troubleshooting

### Issue: Empty Results
**Cause:** Database tables are empty  
**Fix:** Verify data exists in `live_categories`, `series`, etc.

### Issue: "Database connection failed"
**Cause:** Wrong credentials in `xtream_db_config.php`  
**Fix:** Update DB username and password

### Issue: 500 Error
**Cause:** Stored procedures not deployed  
**Fix:** Deploy `xtream_api_simulation_procedures.sql` to database

### Issue: Slow responses
**Cause:** Large result sets without pagination  
**Fix:** Add LIMIT clauses or implement pagination

---

## Next Steps

1. ✅ Deploy files to `public_html/_workers/ai/`
2. ✅ Deploy stored procedures to `xpdgxfsp_content` database
3. ✅ Update credentials in `xtream_db_config.php`
4. ✅ Test all endpoints using `test_endpoints.ps1`
5. ✅ Update Android client base URL
6. ✅ Test app end-to-end
7. 🔄 Monitor logs for issues
8. 🔄 Add caching if needed
9. 🔄 Implement proper authentication

---

## Support & Monitoring

**Error Logs:**
```bash
tail -f /home/xpdgxfsp/public_html/_workers/ai/error.log
```

**MySQL Slow Query Log:**
```sql
SHOW VARIABLES LIKE 'slow_query_log%';
```

**Database Query Test:**
```sql
-- Verify procedures exist
SHOW PROCEDURE STATUS WHERE Db = 'xpdgxfsp_content' AND Name LIKE 'sp_xtream%';

-- Test a procedure directly
CALL sp_xtream_get_live_categories('Marina2025', '3KY586YR');
```

---

**API Version:** 1.0  
**Last Updated:** 2026-01-29  
**Compatibility:** Xtream Codes API v2
