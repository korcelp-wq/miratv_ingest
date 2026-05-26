<?php
// Reprocess Series from Processed Directory
// Purpose: Batch reprocess series files with INSERT ... ON DUPLICATE KEY UPDATE
// Location: Upload to public_html/_workers/

header('Content-Type: text/plain; charset=utf-8');

$TOKEN = 'WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY';
$provided_token = $_GET['token'] ?? $_POST['token'] ?? $_SERVER['HTTP_X_INGEST_TOKEN'] ?? '';

if ($provided_token !== $TOKEN) {
    http_response_code(403);
    die("❌ Unauthorized\n");
}

require_once('/home/xpdgxfsp/public_html/db_sql.php');

$PROCESSED_DIR = '/home/xpdgxfsp/public_html/automated/raw_store/processed';
$series_id = $_GET['series_id'] ?? null;

echo "=================================================\n";
echo "Reprocess Series from Processed Directory\n";
echo "=================================================\n";
echo "Directory: $PROCESSED_DIR\n";

if (!is_dir($PROCESSED_DIR)) {
    die("❌ Directory not found: $PROCESSED_DIR\n");
}

// Get list of series to process
if ($series_id) {
    $series_list = [(int)$series_id];
    echo "Mode: Single series ($series_id)\n\n";
} else {
    $files = glob("$PROCESSED_DIR/series_*_series.json");
    $series_list = [];
    foreach ($files as $file) {
        if (preg_match('/series_(\d+)_series\.json$/', basename($file), $m)) {
            $series_list[] = (int)$m[1];
        }
    }
    sort($series_list);
    echo "Mode: Batch (" . count($series_list) . " series found)\n\n";
}

$processed = 0;
$failed = 0;

foreach ($series_list as $sid) {
    echo "=================================================\n";
    echo "▶ Processing series_$sid\n";
    
    // File paths
    $series_file = "$PROCESSED_DIR/series_{$sid}_series.json";
    $series_ext_file = "$PROCESSED_DIR/series_{$sid}_series_ext.json";
    $seasons_file = "$PROCESSED_DIR/series_{$sid}_seasons.json";
    $season_ext_file = "$PROCESSED_DIR/series_{$sid}_season_ext.json";
    $episodes_file = "$PROCESSED_DIR/series_{$sid}_episodes.json";
    
    // Check if series file exists
    if (!file_exists($series_file)) {
        echo "  ⚠ Skipped: series file not found\n";
        continue;
    }
    
    // 1. Process series_details
    $series_data = json_decode(file_get_contents($series_file), true);
    if ($series_data && isset($series_data['series_id'])) {
        $stmt = $conn->prepare("
            INSERT INTO series_details (series_id, name, cover, plot, cast, director, genre, releaseDate, rating, backdrop_path, youtube_trailer, episode_run_time)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE
                name = VALUES(name),
                cover = VALUES(cover),
                plot = VALUES(plot),
                cast = VALUES(cast),
                director = VALUES(director),
                genre = VALUES(genre),
                releaseDate = VALUES(releaseDate),
                rating = VALUES(rating),
                backdrop_path = VALUES(backdrop_path),
                youtube_trailer = VALUES(youtube_trailer),
                episode_run_time = VALUES(episode_run_time)
        ");
        $stmt->bind_param('issssssssssi',
            $series_data['series_id'],
            $series_data['name'] ?? null,
            $series_data['cover'] ?? null,
            $series_data['plot'] ?? null,
            $series_data['cast'] ?? null,
            $series_data['director'] ?? null,
            $series_data['genre'] ?? null,
            $series_data['releaseDate'] ?? null,
            $series_data['rating'] ?? null,
            $series_data['backdrop_path'] ?? null,
            $series_data['youtube_trailer'] ?? null,
            $series_data['episode_run_time'] ?? 0
        );
        $stmt->execute();
        echo "  ✔ series_details updated\n";
    }
    
    // 2. Process seasons
    if (file_exists($seasons_file)) {
        $seasons_data = json_decode(file_get_contents($seasons_file), true);
        if ($seasons_data && is_array($seasons_data)) {
            $season_count = 0;
            foreach ($seasons_data as $season) {
                $stmt = $conn->prepare("
                    INSERT INTO series_seasons (series_id, season_number, name, air_date, episode_count, overview, cover, cover_big)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON DUPLICATE KEY UPDATE
                        name = VALUES(name),
                        air_date = VALUES(air_date),
                        episode_count = VALUES(episode_count),
                        overview = VALUES(overview),
                        cover = VALUES(cover),
                        cover_big = VALUES(cover_big)
                ");
                $stmt->bind_param('iissssss',
                    $sid,
                    $season['season_number'] ?? 0,
                    $season['name'] ?? null,
                    $season['air_date'] ?? null,
                    $season['episode_count'] ?? 0,
                    $season['overview'] ?? null,
                    $season['cover'] ?? null,
                    $season['cover_big'] ?? null
                );
                $stmt->execute();
                $season_count++;
            }
            echo "  ✔ series_seasons updated ($season_count seasons)\n";
        }
    }
    
    // 3. Process episodes
    if (file_exists($episodes_file)) {
        $episodes_data = json_decode(file_get_contents($episodes_file), true);
        if ($episodes_data && is_array($episodes_data)) {
            $episode_count = 0;
            foreach ($episodes_data as $episode) {
                // Get season_id from series_seasons
                $season_num = $episode['season_number'] ?? 0;
                $result = $conn->query("SELECT id FROM series_seasons WHERE series_id = $sid AND season_number = $season_num LIMIT 1");
                if ($result && $row = $result->fetch_assoc()) {
                    $season_id = $row['id'];
                    
                    $stmt = $conn->prepare("
                        INSERT INTO series_episodes (season_id, episode_num, title, container_extension, air_date, crew, rating, plot, duration_secs, duration, movie_image, stream_url)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON DUPLICATE KEY UPDATE
                            title = VALUES(title),
                            container_extension = VALUES(container_extension),
                            air_date = VALUES(air_date),
                            crew = VALUES(crew),
                            rating = VALUES(rating),
                            plot = VALUES(plot),
                            duration_secs = VALUES(duration_secs),
                            duration = VALUES(duration),
                            movie_image = VALUES(movie_image),
                            stream_url = VALUES(stream_url)
                    ");
                    $stmt->bind_param('iissssssssss',
                        $season_id,
                        $episode['episode_num'] ?? 0,
                        $episode['title'] ?? null,
                        $episode['container_extension'] ?? null,
                        $episode['air_date'] ?? null,
                        $episode['crew'] ?? null,
                        $episode['rating'] ?? null,
                        $episode['plot'] ?? null,
                        $episode['duration_secs'] ?? null,
                        $episode['duration'] ?? null,
                        $episode['movie_image'] ?? null,
                        $episode['stream_url'] ?? null
                    );
                    $stmt->execute();
                    $episode_count++;
                }
            }
            echo "  ✔ series_episodes updated ($episode_count episodes)\n";
        }
    }
    
    // 4. Update series flags
    $conn->query("UPDATE series SET details_ingested = 1, details_state = 'COMPLETE' WHERE series_id = $sid");
    echo "  ✔ series flags updated (details_ingested=1, state=COMPLETE)\n";
    
    $processed++;
}

echo "\n=================================================\n";
echo "✅ Reprocessing complete\n";
echo "   Processed: $processed\n";
echo "   Failed: $failed\n";
echo "=================================================\n";

$conn->close();
?>
