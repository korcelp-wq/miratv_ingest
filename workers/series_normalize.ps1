# =========================================================
# MiraTV Series Normalizer (SERIES + SEASONS + EPISODES)
# =========================================================

Write-Host "========================================="
Write-Host "MiraTV Series Normalizer"
Write-Host "========================================="




# ------------------ LOAD MYSQL DRIVER ------------------

$mysqlDll = "C:\Program Files (x86)\MySQL\MySQL Connector NET 8.4\MySql.Data.dll"

if (!(Test-Path $mysqlDll)) {
    Write-Error "❌ MySql.Data.dll not found at expected path"
    exit 1
}

Add-Type -Path $mysqlDll
# Add-Type -Path "C:\Program Files (x86)\MySQL\MySQL Connector NET 8.4\MySql.Data.dll"
# ------------------ DB CONFIG ------------------

$DB_HOST = "localhost"
$DB_NAME = "xpdgxfsp_content"
$DB_USER = "xpdgxfsp_ingest"
$DB_PASS = "Sy,SX4SQYhpV"

$connStr = "server=$DB_HOST;database=$DB_NAME;uid=$DB_USER;pwd=$DB_PASS;charset=utf8mb4;"

$conn = New-Object MySql.Data.MySqlClient.MySqlConnection($connStr)
$conn.Open()

# =========================================================
# MAIN LOOP
# =========================================================

while ($true) {

    # ------------------ FETCH NEXT RAW PAYLOAD ------------------

    $fetch = $conn.CreateCommand()
    $fetch.CommandText = @"
SELECT id, internal_series_id, provider_series_id, raw_provider_json
FROM series_details_raw
WHERE parsed = 0
ORDER BY id
LIMIT 1
"@

    $reader = $fetch.ExecuteReader()

    if (-not $reader.Read()) {
        $reader.Close()
        Write-Host "✅ No raw payloads remaining"
        break
    }

    $rawId      = [int]$reader["id"]
    $seriesId   = [int]$reader["internal_series_id"]
    $providerId = [int]$reader["provider_series_id"]
    $rawJson    = $reader["raw_provider_json"]

    $reader.Close()

    Write-Host "🎬 Normalizing series internal_id=$seriesId provider_id=$providerId"

    # ------------------ PARSE JSON ------------------

    try {
        $data = $rawJson | ConvertFrom-Json
    } catch {
        $err = $_.Exception.Message
        Write-Error "❌ JSON parse failed for raw_id=$rawId"

        $fail = $conn.CreateCommand()
        $fail.CommandText = "UPDATE series_details_raw SET parse_error=@e WHERE id=@id"
        $fail.Parameters.AddWithValue("@e", $err) | Out-Null
        $fail.Parameters.AddWithValue("@id", $rawId) | Out-Null
        $fail.ExecuteNonQuery() | Out-Null
        continue
    }

    $info = $data.info

    # ------------------ UPSERT series_details ------------------

    $details = $conn.CreateCommand()
    $details.CommandText = @"
INSERT INTO series_details (
    series_id, plot, genre, rating, release_date,
    backdrop_url, cover_url, updated_at
) VALUES (
    @sid, @plot, @genre, @rating, @release,
    @backdrop, @cover, NOW()
)
ON DUPLICATE KEY UPDATE
    plot=VALUES(plot),
    genre=VALUES(genre),
    rating=VALUES(rating),
    release_date=VALUES(release_date),
    backdrop_url=VALUES(backdrop_url),
    cover_url=VALUES(cover_url),
    updated_at=NOW()
"@

    $details.Parameters.AddWithValue("@sid", $seriesId) | Out-Null
    $details.Parameters.AddWithValue("@plot", $info.plot) | Out-Null
    $details.Parameters.AddWithValue("@genre", $info.genre) | Out-Null
    $details.Parameters.AddWithValue("@rating", $info.rating) | Out-Null
    $details.Parameters.AddWithValue("@release", $info.releaseDate) | Out-Null
    $details.Parameters.AddWithValue("@backdrop", ($info.backdrop_path | Select-Object -First 1)) | Out-Null
    $details.Parameters.AddWithValue("@cover", $info.cover) | Out-Null
    $details.ExecuteNonQuery() | Out-Null

    # ------------------ SEASONS ------------------

    foreach ($s in $data.seasons) {

        $season = $conn.CreateCommand()
        $season.CommandText = @"
INSERT INTO series_seasons (
    series_id, season_number, name, episode_count, air_date, cover
) VALUES (
    @sid,@num,@name,@cnt,@air,@cover
)
ON DUPLICATE KEY UPDATE
    name=VALUES(name),
    episode_count=VALUES(episode_count),
    air_date=VALUES(air_date),
    cover=VALUES(cover)
"@

        $season.Parameters.AddWithValue("@sid", $seriesId) | Out-Null
        $season.Parameters.AddWithValue("@num", $s.season_number) | Out-Null
        $season.Parameters.AddWithValue("@name", $s.name) | Out-Null
        $season.Parameters.AddWithValue("@cnt", $s.episode_count) | Out-Null
        $season.Parameters.AddWithValue("@air", $s.air_date) | Out-Null
        $season.Parameters.AddWithValue("@cover", $s.cover) | Out-Null
        $season.ExecuteNonQuery() | Out-Null
    }

    # ------------------ EPISODES ------------------

    foreach ($seasonKey in $data.episodes.PSObject.Properties.Name) {
        foreach ($ep in $data.episodes.$seasonKey) {

            $episode = $conn.CreateCommand()
            $episode.CommandText = @"
INSERT INTO series_episodes (
    series_id, season_number, episode_number,
    title, stream_id, container
) VALUES (
    @sid,@season,@epnum,@title,@stream,@ext
)
ON DUPLICATE KEY UPDATE
    title=VALUES(title),
    stream_id=VALUES(stream_id),
    container=VALUES(container)
"@

            $episode.Parameters.AddWithValue("@sid", $seriesId) | Out-Null
            $episode.Parameters.AddWithValue("@season", [int]$seasonKey) | Out-Null
            $episode.Parameters.AddWithValue("@epnum", $ep.episode_num) | Out-Null
            $episode.Parameters.AddWithValue("@title", $ep.title) | Out-Null
            $episode.Parameters.AddWithValue("@stream", $ep.id) | Out-Null
            $episode.Parameters.AddWithValue("@ext", $ep.container_extension) | Out-Null
            $episode.ExecuteNonQuery() | Out-Null
        }
    }

    # ------------------ FLIP FLAGS ------------------

    $final = $conn.CreateCommand()
    $final.CommandText = @"
UPDATE series_details_raw
SET parsed = 1, parsed_at = NOW()
WHERE id = @rid;

UPDATE series
SET details_ingested = 1,
    details_ingested_at = NOW(),
    is_dirty = 0
WHERE id = @sid;
"@

    $final.Parameters.AddWithValue("@rid", $rawId) | Out-Null
    $final.Parameters.AddWithValue("@sid", $seriesId) | Out-Null
    $final.ExecuteNonQuery() | Out-Null

    Write-Host "✅ Series $seriesId normalized successfully"
}

$conn.Close()

Write-Host "========================================="
Write-Host "Normalizer complete"
Write-Host "========================================="
