<?php
declare(strict_types=1);

// MiraTV DB cleanup guard: release database handles at request shutdown and in top-level finally blocks.
// Keep this local to each endpoint so shared-host MySQL connection slots are not held longer than needed.
if (!function_exists('miratv_release_db_handles')) {
    function miratv_release_db_handles(): void
    {
        foreach (array_keys($GLOBALS) as $name) {
            if (in_array($name, ['GLOBALS', '_SERVER', '_GET', '_POST', '_FILES', '_COOKIE', '_SESSION', '_REQUEST', '_ENV'], true)) {
                continue;
            }

            if (!array_key_exists($name, $GLOBALS)) {
                continue;
            }

            $value = $GLOBALS[$name];

            if ($value instanceof PDOStatement) {
                try {
                    $value->closeCursor();
                } catch (Throwable $ignored) {
                }
                $GLOBALS[$name] = null;
                continue;
            }

            if ($value instanceof PDO) {
                $GLOBALS[$name] = null;
                continue;
            }

            if (class_exists('mysqli_result', false) && $value instanceof mysqli_result) {
                try {
                    $value->free();
                } catch (Throwable $ignored) {
                }
                $GLOBALS[$name] = null;
                continue;
            }

            if (class_exists('mysqli_stmt', false) && $value instanceof mysqli_stmt) {
                try {
                    $value->close();
                } catch (Throwable $ignored) {
                }
                $GLOBALS[$name] = null;
                continue;
            }

            if (class_exists('mysqli', false) && $value instanceof mysqli) {
                try {
                    $value->close();
                } catch (Throwable $ignored) {
                }
                $GLOBALS[$name] = null;
            }
        }
    }

    register_shutdown_function('miratv_release_db_handles');
}

header('Content-Type: application/json; charset=utf-8');

/*
 * MiraTV Step 6B-5F1 - VOD Metadata Queue Processor
 *
 * Target path:
 *   /home/xpdgxfsp/public_html/_workers/ai/api/process_vod_metadata_queue.php
 *
 * Purpose:
 *   Process queued VOD metadata materialization rows from:
 *     xpdgxfsp_ip.content_materialization_queue
 *
 * Supported lane:
 *   content_type = vod
 *   materialization_kind = metadata
 *   trigger_reason = preview_missing_fields
 *
 * Behavior:
 *   - dry_run=1 by default.
 *   - limit is capped at 25.
 *   - queue_id supports exact-row testing.
 *   - only_preview_missing=1 restricts processing to preview_missing_fields.
 *   - Calls materialize_vod_preview.php with local content_id as vod_id.
 *   - Verifies requested fields after materialization.
 *   - Completes when requested fields are repaired.
 *   - Also supports safe partial completion when materializer writes useful metadata
 *     but a non-critical requested field remains unavailable from TMDb/provider data.
 *
 * Confirmed materializer call shape:
 *   materialize_vod_preview.php?vod_id=<local_vod_id>&reason=<reason>
 */

const ENDPOINT_VERSION = '6B-5F1-2026-05-27-vod-preview-missing-queue';

function json_response(array $payload, int $statusCode = 200): void
{
    http_response_code($statusCode);
    echo json_encode($payload, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    exit;
}

function clean($value): string
{
    return trim((string)$value);
}

function first_non_blank(...$values): ?string
{
    foreach ($values as $value) {
        $value = clean($value);
        if ($value !== '') {
            return $value;
        }
    }
    return null;
}

function split_missing_fields($value): array
{
    $value = clean($value);
    if ($value === '') {
        return [];
    }

    $parts = explode(',', $value);
    $out = [];
    foreach ($parts as $part) {
        $part = trim($part);
        if ($part !== '') {
            $out[] = $part;
        }
    }

    return array_values(array_unique($out));
}

function normalize_requested_fields(array $fields): array
{
    $normalized = [];

    foreach ($fields as $field) {
        $field = strtolower(clean($field));

        if ($field === 'image_url' || $field === 'poster' || $field === 'cover_url') {
            $field = 'poster_url';
        } elseif ($field === 'backdrop' || $field === 'tmdb_backdrop_url') {
            $field = 'backdrop_url';
        } elseif ($field === 'runtime' || $field === 'runtime_minutes' || $field === 'length') {
            $field = 'duration';
        } elseif ($field === 'year' || $field === 'release_date') {
            $field = 'release_year';
        } elseif ($field === 'genres' || $field === 'primary_genre') {
            $field = 'genre';
        } elseif ($field === 'overview' || $field === 'description') {
            $field = 'plot';
        }

        if (in_array($field, [
            'tmdb_id',
            'poster_url',
            'backdrop_url',
            'plot',
            'release_year',
            'duration',
            'genre',
            'rating',
            'director',
            'cast',
            'trailer_url',
        ], true)) {
            $normalized[] = $field;
        }
    }

    return array_values(array_unique($normalized));
}

function find_config_file(string $filename): ?string
{
    $candidates = [
        __DIR__ . '/../config/' . $filename,
        __DIR__ . '/../../config/' . $filename,
        __DIR__ . '/../../../config/' . $filename,
        '/home/xpdgxfsp/public_html/_workers/ai/config/' . $filename,
        '/home/xpdgxfsp/public_html/_workers/config/' . $filename,
        '/home/xpdgxfsp/config/' . $filename,
    ];

    foreach ($candidates as $candidate) {
        if (is_file($candidate)) {
            return $candidate;
        }
    }

    return null;
}

function open_pdo(): PDO
{
    $configFile = find_config_file('db.php');
    if (!$configFile) {
        throw new RuntimeException('Unable to locate db.php config file');
    }

    $config = require $configFile;

    if (isset($config['content']['dsn'])) {
        $entry = $config['content'];
    } elseif (isset($config['ip']['dsn'])) {
        $entry = $config['ip'];
    } elseif (isset($config['dsn'])) {
        $entry = $config;
    } else {
        throw new RuntimeException('DB config found, but no usable DSN entry exists');
    }

    $opts = $entry['opts'] ?? [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        PDO::ATTR_EMULATE_PREPARES => false,
    ];

    return new PDO(
        $entry['dsn'],
        $entry['user'] ?? '',
        $entry['pass'] ?? '',
        $opts
    );
}

function table_exists(PDO $pdo, string $schema, string $table): bool
{
    $sql = "
        SELECT COUNT(*) AS c
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = :schema
          AND TABLE_NAME = :table
        LIMIT 1
    ";

    $stmt = $pdo->prepare($sql);
    $stmt->execute([
        ':schema' => $schema,
        ':table' => $table,
    ]);

    $row = $stmt->fetch(PDO::FETCH_ASSOC);
    return ((int)($row['c'] ?? 0)) > 0;
}

function table_columns(PDO $pdo, string $schema, string $table): array
{
    static $cache = [];

    $key = $schema . '.' . $table;
    if (isset($cache[$key])) {
        return $cache[$key];
    }

    if (!table_exists($pdo, $schema, $table)) {
        $cache[$key] = [];
        return [];
    }

    $sql = "
        SELECT COLUMN_NAME
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = :schema
          AND TABLE_NAME = :table
    ";

    $stmt = $pdo->prepare($sql);
    $stmt->execute([
        ':schema' => $schema,
        ':table' => $table,
    ]);

    $cols = [];
    while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
        $cols[(string)$row['COLUMN_NAME']] = true;
    }

    $cache[$key] = $cols;
    return $cols;
}

function has_col(array $columns, string $name): bool
{
    return isset($columns[$name]);
}

function select_expr(array $columns, string $alias, string $column, string $outAlias): ?string
{
    if (!has_col($columns, $column)) {
        return null;
    }

    return $alias . '.' . $column . ' AS ' . $outAlias;
}

function get_queue_rows(PDO $pdo, ?int $queueId, int $limit, bool $onlyPreviewMissing): array
{
    if ($queueId !== null && $queueId > 0) {
        $sql = "
            SELECT *
            FROM xpdgxfsp_ip.content_materialization_queue
            WHERE id = :queue_id
              AND content_type = 'vod'
              AND materialization_kind = 'metadata'
            LIMIT 1
        ";
        $stmt = $pdo->prepare($sql);
        $stmt->execute([':queue_id' => $queueId]);
        return $stmt->fetchAll(PDO::FETCH_ASSOC);
    }

    $reasons = ["'preview_missing_fields'"];

    if (!$onlyPreviewMissing) {
        $reasons = ["'preview_missing_fields'"];
    }

    $sql = "
        SELECT *
        FROM xpdgxfsp_ip.content_materialization_queue
        WHERE content_type = 'vod'
          AND materialization_kind = 'metadata'
          AND status = 'queued'
          AND trigger_reason IN (" . implode(',', $reasons) . ")
          AND attempt_count < max_attempts
        ORDER BY priority ASC, created_at ASC, id ASC
        LIMIT :limit
    ";

    $stmt = $pdo->prepare($sql);
    $stmt->bindValue(':limit', $limit, PDO::PARAM_INT);
    $stmt->execute();

    return $stmt->fetchAll(PDO::FETCH_ASSOC);
}

function load_vod_context(PDO $pdo, array $queueRow): array
{
    $vodColumns = table_columns($pdo, 'xpdgxfsp_content', 'vod');

    if (empty($vodColumns)) {
        throw new RuntimeException('xpdgxfsp_content.vod table not found or has no readable columns');
    }

    $selects = ['v.vod_id AS vod_id'];

    foreach ([
        'provider_vod_id',
        'provider',
        'title',
        'name',
        'clean_search_name',
        'tmdb_search_name',
        'poster_url',
        'cover_url',
        'tmdb_cover_url',
        'provider_cover_url',
        'backdrop_url',
        'tmdb_backdrop_url',
        'provider_backdrop_url',
        'plot',
        'description',
        'rating',
        'release_year',
        'duration',
        'runtime_minutes',
        'genre',
        'primary_genre',
    ] as $col) {
        $expr = select_expr($vodColumns, 'v', $col, $col);
        if ($expr !== null) {
            $selects[] = $expr;
        }
    }

    $sql = "
        SELECT
            " . implode(",\n            ", $selects) . "
        FROM xpdgxfsp_content.vod v
        WHERE v.vod_id = :content_id
           OR v.provider_vod_id = :provider_content_id
        LIMIT 1
    ";

    $stmt = $pdo->prepare($sql);
    $stmt->execute([
        ':content_id' => (int)$queueRow['content_id'],
        ':provider_content_id' => clean($queueRow['provider_content_id'] ?? ''),
    ]);

    $row = $stmt->fetch(PDO::FETCH_ASSOC);

    if (!$row) {
        return [
            'found' => false,
            'vod_id' => (int)$queueRow['content_id'],
            'provider_vod_id' => clean($queueRow['provider_content_id'] ?? ''),
            'provider' => clean($queueRow['provider'] ?? ''),
            'title' => null,
            'clean_search_name' => null,
            'tmdb_search_name' => null,
        ];
    }

    return [
        'found' => true,
        'vod_id' => (int)($row['vod_id'] ?? $queueRow['content_id']),
        'provider_vod_id' => first_non_blank($row['provider_vod_id'] ?? null, $queueRow['provider_content_id'] ?? null),
        'provider' => first_non_blank($row['provider'] ?? null, $queueRow['provider'] ?? null),
        'title' => first_non_blank($row['title'] ?? null, $row['name'] ?? null),
        'clean_search_name' => $row['clean_search_name'] ?? null,
        'tmdb_search_name' => $row['tmdb_search_name'] ?? null,
        'poster_url' => first_non_blank(
            $row['tmdb_cover_url'] ?? null,
            $row['poster_url'] ?? null,
            $row['cover_url'] ?? null,
            $row['provider_cover_url'] ?? null
        ),
        'backdrop_url' => first_non_blank(
            $row['tmdb_backdrop_url'] ?? null,
            $row['backdrop_url'] ?? null,
            $row['provider_backdrop_url'] ?? null
        ),
        'plot' => first_non_blank($row['plot'] ?? null, $row['description'] ?? null),
        'release_year' => first_non_blank($row['release_year'] ?? null),
        'duration' => first_non_blank($row['duration'] ?? null, $row['runtime_minutes'] ?? null),
        'genre' => first_non_blank($row['primary_genre'] ?? null, $row['genre'] ?? null),
        'rating' => first_non_blank($row['rating'] ?? null),
    ];
}

function get_current_vod_state(PDO $pdo, int $vodId): array
{
    $vodColumns = table_columns($pdo, 'xpdgxfsp_content', 'vod');
    $extColumns = table_columns($pdo, 'xpdgxfsp_content', 'vod_metadata_ext');
    $hasExt = !empty($extColumns);

    if (empty($vodColumns)) {
        throw new RuntimeException('xpdgxfsp_content.vod table not found or has no readable columns');
    }

    $selects = ['v.vod_id AS vod_id'];

    foreach ([
        'provider_vod_id',
        'title',
        'name',
        'poster_url',
        'cover_url',
        'tmdb_cover_url',
        'provider_cover_url',
        'backdrop_url',
        'tmdb_backdrop_url',
        'provider_backdrop_url',
        'plot',
        'description',
        'rating',
        'release_year',
        'duration',
        'runtime_minutes',
        'genre',
        'primary_genre',
        'tmdb_id',
    ] as $col) {
        $expr = select_expr($vodColumns, 'v', $col, 'vod_' . $col);
        if ($expr !== null) {
            $selects[] = $expr;
        }
    }

    if ($hasExt) {
        foreach ([
            'tmdb_id',
            'imdb_id',
            'overview',
            'plot',
            'tmdb_poster_url',
            'poster_url',
            'tmdb_backdrop_url',
            'backdrop_url',
            'release_date',
            'release_year',
            'runtime_minutes',
            'duration',
            'rating',
            'vote_average',
            'genres',
            'primary_genre',
            'director',
            'cast',
            'trailer_url',
            'youtube_trailer',
        ] as $col) {
            $expr = select_expr($extColumns, 'ext', $col, 'ext_' . $col);
            if ($expr !== null) {
                $selects[] = $expr;
            }
        }
    }

    $join = '';
    if ($hasExt) {
        $join = 'LEFT JOIN xpdgxfsp_content.vod_metadata_ext ext ON ext.vod_id = v.vod_id';
    }

    $sql = "
        SELECT
            " . implode(",\n            ", $selects) . "
        FROM xpdgxfsp_content.vod v
        $join
        WHERE v.vod_id = :vod_id
        LIMIT 1
    ";

    $stmt = $pdo->prepare($sql);
    $stmt->execute([':vod_id' => $vodId]);
    $row = $stmt->fetch(PDO::FETCH_ASSOC);

    if (!$row) {
        return [
            'vod_id' => $vodId,
            'found' => false,
            'tmdb_id' => null,
            'poster_url' => null,
            'backdrop_url' => null,
            'plot' => null,
            'release_year' => null,
            'duration' => null,
            'genre' => null,
            'rating' => null,
            'director' => null,
            'cast' => null,
            'trailer_url' => null,
            'missing_now' => [
                'tmdb_id',
                'poster_url',
                'backdrop_url',
                'plot',
                'release_year',
                'duration',
                'genre',
                'rating',
            ],
        ];
    }

    $tmdbId = first_non_blank($row['ext_tmdb_id'] ?? null, $row['vod_tmdb_id'] ?? null);
    $poster = first_non_blank(
        $row['ext_tmdb_poster_url'] ?? null,
        $row['ext_poster_url'] ?? null,
        $row['vod_tmdb_cover_url'] ?? null,
        $row['vod_poster_url'] ?? null,
        $row['vod_cover_url'] ?? null,
        $row['vod_provider_cover_url'] ?? null
    );
    $backdrop = first_non_blank(
        $row['ext_tmdb_backdrop_url'] ?? null,
        $row['ext_backdrop_url'] ?? null,
        $row['vod_tmdb_backdrop_url'] ?? null,
        $row['vod_backdrop_url'] ?? null,
        $row['vod_provider_backdrop_url'] ?? null
    );
    $plot = first_non_blank(
        $row['ext_overview'] ?? null,
        $row['ext_plot'] ?? null,
        $row['vod_plot'] ?? null,
        $row['vod_description'] ?? null
    );
    $releaseYear = first_non_blank(
        $row['ext_release_year'] ?? null,
        $row['vod_release_year'] ?? null
    );
    $duration = first_non_blank(
        $row['ext_runtime_minutes'] ?? null,
        $row['ext_duration'] ?? null,
        $row['vod_runtime_minutes'] ?? null,
        $row['vod_duration'] ?? null
    );
    $genre = first_non_blank(
        $row['ext_primary_genre'] ?? null,
        $row['ext_genres'] ?? null,
        $row['vod_primary_genre'] ?? null,
        $row['vod_genre'] ?? null
    );
    $rating = first_non_blank(
        $row['ext_rating'] ?? null,
        $row['ext_vote_average'] ?? null,
        $row['vod_rating'] ?? null
    );
    $director = first_non_blank($row['ext_director'] ?? null);
    $cast = first_non_blank($row['ext_cast'] ?? null);
    $trailer = first_non_blank($row['ext_trailer_url'] ?? null, $row['ext_youtube_trailer'] ?? null);

    $missing = [];
    if ($tmdbId === null || (int)$tmdbId <= 0) {
        $missing[] = 'tmdb_id';
    }
    if ($poster === null) {
        $missing[] = 'poster_url';
    }
    if ($backdrop === null) {
        $missing[] = 'backdrop_url';
    }
    if ($plot === null) {
        $missing[] = 'plot';
    }
    if ($releaseYear === null || (int)$releaseYear <= 0) {
        $missing[] = 'release_year';
    }
    if ($duration === null) {
        $missing[] = 'duration';
    }
    if ($genre === null) {
        $missing[] = 'genre';
    }
    if ($rating === null) {
        $missing[] = 'rating';
    }

    return [
        'vod_id' => $vodId,
        'found' => true,
        'tmdb_id' => $tmdbId !== null ? (int)$tmdbId : null,
        'poster_url' => $poster,
        'backdrop_url' => $backdrop,
        'plot' => $plot,
        'release_year' => $releaseYear,
        'duration' => $duration,
        'genre' => $genre,
        'rating' => $rating,
        'director' => $director,
        'cast' => $cast,
        'trailer_url' => $trailer,
        'missing_now' => $missing,
    ];
}

function requested_fields_repaired(array $requestedFields, array $state): array
{
    $stillMissing = [];

    foreach ($requestedFields as $field) {
        if ($field === 'tmdb_id') {
            $tmdbId = $state['tmdb_id'] ?? null;
            if ($tmdbId === null || (int)$tmdbId <= 0) {
                $stillMissing[] = 'tmdb_id';
            }
            continue;
        }

        if ($field === 'release_year') {
            if (($state[$field] ?? null) === null || (int)$state[$field] <= 0) {
                $stillMissing[] = $field;
            }
            continue;
        }

        if (!array_key_exists($field, $state) || first_non_blank($state[$field] ?? null) === null) {
            $stillMissing[] = $field;
        }
    }

    return [
        'repaired' => empty($stillMissing),
        'still_missing' => array_values(array_unique($stillMissing)),
    ];
}

function materializer_wrote_useful_metadata(array $materializerJson): bool
{
    if (empty($materializerJson['ok'])) {
        return false;
    }

    $written = $materializerJson['written'] ?? null;
    if (!is_array($written)) {
        return false;
    }

    $tmdbId = isset($written['tmdb_id']) ? (int)$written['tmdb_id'] : 0;
    $title = first_non_blank($written['title'] ?? null);
    $poster = first_non_blank($written['poster_url'] ?? null);
    $backdrop = first_non_blank($written['backdrop_url'] ?? null);
    $plot = first_non_blank($written['overview'] ?? null, $written['plot'] ?? null);
    $releaseYear = first_non_blank($written['release_year'] ?? null, $written['release_date'] ?? null);
    $runtime = first_non_blank($written['runtime_minutes'] ?? null, $written['duration'] ?? null);
    $genres = first_non_blank($written['genres'] ?? null, $written['primary_genre'] ?? null);
    $rating = first_non_blank($written['rating'] ?? null);
    $director = first_non_blank($written['director'] ?? null);
    $cast = first_non_blank($written['cast'] ?? null);
    $trailer = first_non_blank($written['trailer_url'] ?? null, $written['youtube_trailer'] ?? null);

    if ($tmdbId > 0 && ($title !== null || $poster !== null || $backdrop !== null)) {
        return true;
    }

    if ($poster !== null || $backdrop !== null || $plot !== null || $releaseYear !== null || $runtime !== null || $genres !== null || $rating !== null || $director !== null || $cast !== null || $trailer !== null) {
        return true;
    }

    return false;
}

function update_queue_started(PDO $pdo, int $queueId): void
{
    $sql = "
        UPDATE xpdgxfsp_ip.content_materialization_queue
        SET status = 'running',
            attempt_count = attempt_count + 1,
            started_at = NOW(),
            updated_at = NOW()
        WHERE id = :queue_id
        LIMIT 1
    ";

    $stmt = $pdo->prepare($sql);
    $stmt->execute([':queue_id' => $queueId]);
}

function update_queue_completed(PDO $pdo, int $queueId): void
{
    $sql = "
        UPDATE xpdgxfsp_ip.content_materialization_queue
        SET status = 'completed',
            last_error = NULL,
            completed_at = NOW(),
            updated_at = NOW()
        WHERE id = :queue_id
        LIMIT 1
    ";

    $stmt = $pdo->prepare($sql);
    $stmt->execute([':queue_id' => $queueId]);
}

function update_queue_retry_or_failed(PDO $pdo, array $queueRow, string $error, bool $preferManualStatus = false): string
{
    $queueId = (int)$queueRow['id'];
    $attemptCount = (int)($queueRow['attempt_count'] ?? 0) + 1;
    $maxAttempts = (int)($queueRow['max_attempts'] ?? 3);

    $newStatus = ($attemptCount >= $maxAttempts) ? 'failed' : 'queued';

    if ($preferManualStatus && $attemptCount >= $maxAttempts) {
        $newStatus = 'needs_manual_match';
    }

    $sql = "
        UPDATE xpdgxfsp_ip.content_materialization_queue
        SET status = :status,
            last_error = :last_error,
            completed_at = NULL,
            updated_at = NOW()
        WHERE id = :queue_id
        LIMIT 1
    ";

    $stmt = $pdo->prepare($sql);
    $stmt->execute([
        ':status' => $newStatus,
        ':last_error' => mb_substr($error, 0, 2000),
        ':queue_id' => $queueId,
    ]);

    return $newStatus;
}

function call_vod_materializer(int $vodId, int $queueId, string $reason): array
{
    $params = [
        'vod_id' => $vodId,
        'reason' => $reason,
        'queue_id' => $queueId,
    ];

    $url = 'https://miratv.club/_workers/ai/api/materialize_vod_preview.php?' . http_build_query($params);

    $body = '';
    $status = 0;
    $error = null;

    if (function_exists('curl_init')) {
        $ch = curl_init($url);
        if ($ch === false) {
            return [
                'url' => $url,
                'http_status' => 0,
                'body_preview' => null,
                'json' => null,
                'error' => 'curl_init failed',
            ];
        }

        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_CONNECTTIMEOUT => 5,
            CURLOPT_TIMEOUT => 30,
            CURLOPT_SSL_VERIFYPEER => true,
            CURLOPT_SSL_VERIFYHOST => 2,
            CURLOPT_HTTPHEADER => [
                'Accept: application/json',
                'User-Agent: MiraTV-VOD-Metadata-Queue/6B-5F',
            ],
        ]);

        $body = curl_exec($ch);
        $status = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
        if ($body === false) {
            $error = curl_error($ch);
            $body = '';
        }
        curl_close($ch);
    } else {
        $context = stream_context_create([
            'http' => [
                'method' => 'GET',
                'timeout' => 30,
                'header' => "Accept: application/json\r\nUser-Agent: MiraTV-VOD-Metadata-Queue/6B-5F\r\n",
            ],
        ]);

        $body = @file_get_contents($url, false, $context);
        $status = 200;
        if ($body === false) {
            $error = 'file_get_contents failed';
            $body = '';
        }
    }

    $json = null;
    if ($body !== '') {
        $decoded = json_decode($body, true);
        if (is_array($decoded)) {
            $json = $decoded;
        }
    }

    return [
        'url' => $url,
        'http_status' => $status,
        'body_preview' => mb_substr($body, 0, 1000),
        'json' => $json,
        'error' => $error,
    ];
}

try {
    $limit = isset($_GET['limit']) ? (int)$_GET['limit'] : 5;
    if ($limit <= 0) {
        $limit = 5;
    }
    if ($limit > 25) {
        $limit = 25;
    }

    $dryRun = (int)($_GET['dry_run'] ?? 1) === 1;
    $queueId = isset($_GET['queue_id']) && clean($_GET['queue_id']) !== '' ? (int)$_GET['queue_id'] : null;
    $onlyPreviewMissing = (int)($_GET['only_preview_missing'] ?? 0) === 1;
    $allowPartialCompletion = (int)($_GET['allow_partial_completion'] ?? 1) === 1;

    $pdo = open_pdo();
    $rows = get_queue_rows($pdo, $queueId, $limit, $onlyPreviewMissing);

    $items = [];
    $completed = 0;
    $failed = 0;
    $requeued = 0;
    $manual = 0;
    $partialCompleted = 0;

    foreach ($rows as $queueRow) {
        $queueIdValue = (int)$queueRow['id'];
        $context = load_vod_context($pdo, $queueRow);
        $requestedFields = normalize_requested_fields(split_missing_fields($queueRow['missing_fields'] ?? ''));

        $vodId = (int)($context['vod_id'] ?? $queueRow['content_id']);
        if ($vodId <= 0) {
            $vodId = (int)$queueRow['content_id'];
        }

        $providerVodId = clean($context['provider_vod_id'] ?? $queueRow['provider_content_id'] ?? '');

        $materializerParams = [
            'vod_id' => $vodId,
            'reason' => 'queue_' . clean($queueRow['trigger_reason'] ?? 'metadata'),
            'queue_id' => $queueIdValue,
        ];

        $item = [
            'queue_id' => $queueIdValue,
            'content_id' => (int)$queueRow['content_id'],
            'provider' => clean($queueRow['provider'] ?? ''),
            'provider_content_id' => clean($queueRow['provider_content_id'] ?? ''),
            'mac_user_id' => (int)($queueRow['mac_user_id'] ?? 0),
            'missing_fields' => clean($queueRow['missing_fields'] ?? ''),
            'requested_fields' => $requestedFields,
            'trigger_reason' => clean($queueRow['trigger_reason'] ?? ''),
            'local_vod_id' => $vodId,
            'provider_vod_id' => $providerVodId,
            'catalog_title' => $context['title'] ?? null,
            'clean_search_name' => $context['clean_search_name'] ?? null,
            'tmdb_search_name' => $context['tmdb_search_name'] ?? null,
            'dry_run' => $dryRun,
            'materializer_url_preview' => 'https://miratv.club/_workers/ai/api/materialize_vod_preview.php?' . http_build_query($materializerParams),
        ];

        if ($dryRun) {
            $item['action'] = 'would_call_materialize_vod_preview_then_verify_requested_fields';
            $items[] = $item;
            continue;
        }

        update_queue_started($pdo, $queueIdValue);

        $call = call_vod_materializer(
            $vodId,
            $queueIdValue,
            'queue_' . clean($queueRow['trigger_reason'] ?? 'metadata')
        );

        $item['http_status'] = $call['http_status'];
        $item['materializer_url'] = $call['url'];
        $item['materializer_ok'] = !empty($call['json']['ok']);
        $item['materializer_response'] = $call['json'] ?: [
            'error' => $call['error'] ?: 'non_json_response',
            'body_preview' => $call['body_preview'] ?? '',
        ];

        if ($call['error'] !== null || $call['http_status'] < 200 || $call['http_status'] >= 300 || !$call['json']) {
            $status = update_queue_retry_or_failed(
                $pdo,
                $queueRow,
                'http_status=' . $call['http_status'] . ' | error=' . ($call['error'] ?: 'non-json or failed materializer')
            );

            if ($status === 'failed' || $status === 'needs_manual_match') {
                $failed++;
                if ($status === 'needs_manual_match') {
                    $manual++;
                }
            } else {
                $requeued++;
            }

            $item['queue_status'] = $status;
            $items[] = $item;
            continue;
        }

        if (empty($call['json']['ok'])) {
            $code = clean($call['json']['code'] ?? 'MATERIALIZER_NOT_OK');
            $err = clean($call['json']['error'] ?? 'materializer returned ok=false');
            $preferManual = in_array($code, ['TMDB_NO_MATCH', 'SAFE_RESOLUTION_FAILED', 'QUEUE_CONTENT_ID_MISMATCH'], true);

            if (stripos($err, 'TMDb match not found') !== false || stripos($err, 'tmdb match not found') !== false) {
                $preferManual = true;
            }

            $status = update_queue_retry_or_failed(
                $pdo,
                $queueRow,
                'http_status=' . $call['http_status'] . ' | code=' . $code . ' | json_error=' . $err,
                $preferManual
            );

            if ($status === 'failed' || $status === 'needs_manual_match') {
                $failed++;
                if ($status === 'needs_manual_match') {
                    $manual++;
                }
            } else {
                $requeued++;
            }

            $item['queue_status'] = $status;
            $items[] = $item;
            continue;
        }

        $state = get_current_vod_state($pdo, $vodId);
        $verification = requested_fields_repaired($requestedFields, $state);

        $item['metadata_state_after'] = $state;
        $item['requested_field_verification'] = $verification;

        if (!$verification['repaired']) {
            $usePartialCompletion = (
                $allowPartialCompletion
                && clean($queueRow['trigger_reason'] ?? '') === 'preview_missing_fields'
                && materializer_wrote_useful_metadata($call['json'])
            );

            if ($usePartialCompletion) {
                update_queue_completed($pdo, $queueIdValue);
                $completed++;
                $partialCompleted++;
                $item['queue_status'] = 'completed';
                $item['completion_policy'] = 'partial_vod_metadata_completed';
                $item['completion_note'] = 'VOD materializer wrote useful metadata but one or more requested fields remain unavailable; completed to prevent endless retry on non-critical provider/TMDb gaps.';
                $items[] = $item;
                continue;
            }

            $status = update_queue_retry_or_failed(
                $pdo,
                $queueRow,
                'materializer_ok_but_requested_fields_still_missing=' . implode(',', $verification['still_missing'])
            );

            if ($status === 'failed' || $status === 'needs_manual_match') {
                $failed++;
                if ($status === 'needs_manual_match') {
                    $manual++;
                }
            } else {
                $requeued++;
            }

            $item['queue_status'] = $status;
            $items[] = $item;
            continue;
        }

        update_queue_completed($pdo, $queueIdValue);
        $completed++;
        $item['queue_status'] = 'completed';
        $items[] = $item;
    }

    json_response([
        'ok' => true,
        'endpoint_version' => ENDPOINT_VERSION,
        'dry_run' => $dryRun,
        'limit' => $limit,
        'queue_id' => $queueId,
        'only_preview_missing' => $onlyPreviewMissing,
        'allow_partial_completion' => $allowPartialCompletion,
        'found_count' => count($rows),
        'completed_count' => $completed,
        'partial_completed_count' => $partialCompleted,
        'failed_count' => $failed,
        'requeued_count' => $requeued,
        'needs_manual_match_count' => $manual,
        'items' => $items,
    ]);
} catch (Throwable $e) {
    json_response([
        'ok' => false,
        'endpoint_version' => ENDPOINT_VERSION,
        'error' => $e->getMessage(),
        'file' => basename($e->getFile()),
        'line' => $e->getLine(),
    ], 500);
} finally {
    miratv_release_db_handles();
}
