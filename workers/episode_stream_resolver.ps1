# =========================================================
# MiraTV Episode Stream Resolver
# =========================================================

Write-Host "========================================="
Write-Host "MiraTV Episode Stream Resolver"
Write-Host "========================================="

# ------------------ CONFIG ------------------

$DB_HOST = "localhost"
$DB_NAME = "xpdgxfsp_content"
$DB_USER = "xpdgxfsp_ingest"
$DB_PASS = "Sy,SX4SQYhpV"

# Xtream Provider Config (authoritative)
$XTREAM_HOST = "http://uxurwymd.silvervpn.net:8080"
$XTREAM_USER = "Marina2025"
$XTREAM_PASS = "3KY586YR"

# ------------------ DB CONNECT ------------------

$connStr = "server=$DB_HOST;database=$DB_NAME;uid=$DB_USER;pwd=$DB_PASS;charset=utf8mb4;"
$conn = New-Object MySql.Data.MySqlClient.MySqlConnection($connStr)
$conn.Open()

# ------------------ FETCH NEXT UNRESOLVED EPISODE ------------------

$sql = @"
SELECT id, series_id, season_number, episode_number, stream_id, container
FROM series_episodes
WHERE stream_url IS NULL
ORDER BY id
LIMIT 1
"@

$cmd = $conn.CreateCommand()
$cmd.CommandText = $sql
$reader = $cmd.ExecuteReader()

if (-not $reader.Read()) {
    Write-Host "âœ… No episodes pending resolution"
    $reader.Close()
    $conn.Close()
    exit 0
}

$episodeId   = $reader["id"]
$seriesId    = $reader["series_id"]
$seasonNum   = $reader["season_number"]
$episodeNum  = $reader["episode_number"]
$streamId    = $reader["stream_id"]
$container   = $reader["container"]

$reader.Close()

Write-Host "ðŸŽž Resolving episode S$seasonNum E$episodeNum (series_id=$seriesId)"

# ------------------ BUILD STREAM URL ------------------

$streamUrl = "$XTREAM_HOST/series/$XTREAM_USER/$XTREAM_PASS/$streamId.$container"

# ------------------ UPDATE EPISODE ------------------

$update = $conn.CreateCommand()
$update.CommandText = @"
UPDATE series_episodes
SET stream_url = @url,
    resolved_at = NOW()
WHERE id = @id
"@

$update.Parameters.AddWithValue("@url",$streamUrl) | Out-Null
$update.Parameters.AddWithValue("@id",$episodeId) | Out-Null
$update.ExecuteNonQuery() | Out-Null

$conn.Close()

Write-Host "âœ… Stream resolved"
Write-Host "ðŸ”— $streamUrl"
Write-Host "ðŸ§Š Done"

