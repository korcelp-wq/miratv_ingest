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
 * MiraTV Step 6B-5E10 - Series Metadata Queue Processor
 *
 * Target path:
 *   /home/xpdgxfsp/public_html/_workers/ai/api/process_series_metadata_queue.php
 *
 * Purpose:
 *   Process queued Series metadata/image materialization rows.
 *   Calls materialize_series_preview.php, then verifies that requested image fields
 *   were actually repaired before marking the queue row completed. Uses
 *   xpdgxfsp_content.series image columns only for verification.
 *
 * Important behavior:
 *   - A TMDb match alone is not enough for strict image-repair queue completion.
 *   - If missing_fields includes poster_url, poster/image must exist after materializer.
 *   - If missing_fields includes backdrop_url, backdrop must exist after materializer.
 *   - If requested image fields are still missing, strict rows stay queued until max_attempts.
 *
 * Trigger controls:
 *   - include_preview_missing=1 adds preview_missing_fields to the normal reason list.
 *   - include_unmatched_local=1 adds unmatched_series_local_row_created to the normal reason list.
 *   - only_unmatched_local=1 restricts the processor to only unmatched_series_local_row_created.
 *   - only_series_shelf_missing=1 restricts the processor to only series_shelf_missing_images.
 *   - only_series_port_900_image_repair=1 restricts the processor to only series_port_900_image_repair.
 *
 * Partial completion policy:
 *   - For only_unmatched_local=1 rows, a successful TMDb materialization that writes useful metadata
 *     may complete the queue row even when backdrop_url is unavailable from TMDb.
 *   - TMDB_NO_MATCH still remains queued/failed/manual according to normal retry rules.
 */

const ENDPOINT_VERSION = '6B-5E10-2026-05-27-manual-counter-fix';

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

function is_image_field(string $field): bool
{
    return in_array($field, ['poster_url', 'image_url', 'backdrop_url', 'poster', 'backdrop'], true);
}

function normalize_requested_image_fields(array $fields): array
{
    $normalized = [];
    foreach ($fields as $field) {
        $field = clean($field);
        if ($field === 'poster' || $field === 'image_url') {
            $field = 'poster_url';
        }
        if ($field === 'backdrop') {
            $field = 'backdrop_url';
        }
        if (is_image_field($field)) {
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

function get_queue_rows(
    PDO $pdo,
    ?int $queueId,
    int $limit,
    bool $includePreviewMissing,
    bool $includeUnmatchedLocal,
    bool $onlyUnmatchedLocal,
    bool $onlySeriesShelfMissing,
    bool $onlySeriesPort900ImageRepair
): array {
    if ($queueId !== null && $queueId > 0) {
        $sql = "
            SELECT *
            FROM xpdgxfsp_ip.content_materialization_queue
            WHERE id = :queue_id
              AND content_type = 'series'
              AND materialization_kind = 'metadata'
            LIMIT 1
        ";
        $stmt = $pdo->prepare($sql);
        $stmt->execute([':queue_id' => $queueId]);
        return $stmt->fetchAll(PDO::FETCH_ASSOC);
    }

    if ($onlyUnmatchedLocal) {
        $reasons = ["'unmatched_series_local_row_created'"];
    } elseif ($onlySeriesShelfMissing) {
        $reasons = ["'series_shelf_missing_images'"];
    } elseif ($onlySeriesPort900ImageRepair) {
        $reasons = ["'series_port_900_image_repair'"];
    } else {
        $reasons = ["'missing_series_images_scan'", "'series_shelf_missing_images'"];

        if ($includePreviewMissing) {
            $reasons[] = "'preview_missing_fields'";
        }

        if ($includeUnmatchedLocal) {
            $reasons[] = "'unmatched_series_local_row_created'";
        }
    }

    $sql = "
        SELECT *
        FROM xpdgxfsp_ip.content_materialization_queue
        WHERE content_type = 'series'
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

function load_context(PDO $pdo, array $queueRow): array
{
    $contentId = (int)$queueRow['content_id'];
    $providerContentId = clean($queueRow['provider_content_id'] ?? '');
    $macUserId = (int)($queueRow['mac_user_id'] ?? 0);

    $sql = "
        SELECT
            s.id AS local_series_id,
            s.provider_series_id AS catalog_provider_series_id,
            s.provider AS catalog_provider,
            s.name AS catalog_title,
            s.poster_url AS series_poster_url,
            s.cover_url AS series_cover_url,
            s.tmdb_cover_url AS series_tmdb_cover_url,
            s.provider_cover_url AS series_provider_cover_url,
            s.backdrop_url AS series_backdrop_url,
            s.tmdb_backdrop_url AS series_tmdb_backdrop_url,
            s.provider_backdrop_url AS series_provider_backdrop_url,
            s.clean_search_name,
            s.tmdb_search_name,
            usa.provider AS availability_provider,
            usa.provider_series_id AS availability_provider_series_id,
            usa.provider_series_name,
            usa.provider_series_clean_name,
            usa.local_series_id AS availability_local_series_id
        FROM xpdgxfsp_content.series s
        LEFT JOIN xpdgxfsp_ip.user_series_availability usa
            ON usa.mac_user_id = :mac_user_id
           AND (
                usa.local_series_id = s.id
                OR usa.provider_series_id = :provider_content_id_join
           )
        WHERE s.id = :content_id
        LIMIT 1
    ";

    $stmt = $pdo->prepare($sql);
    $stmt->execute([
        ':mac_user_id' => $macUserId,
        ':provider_content_id_join' => $providerContentId,
        ':content_id' => $contentId,
    ]);

    $row = $stmt->fetch(PDO::FETCH_ASSOC);

    if (!$row) {
        return [
            'found' => false,
            'local_series_id' => $contentId,
            'provider_series_id' => $providerContentId,
            'provider' => clean($queueRow['provider'] ?? ''),
            'catalog_title' => null,
            'clean_search_name' => null,
            'tmdb_search_name' => null,
            'provider_series_name' => null,
            'provider_series_clean_name' => null,
        ];
    }

    $providerSeriesId = first_non_blank(
        $providerContentId,
        $row['availability_provider_series_id'] ?? null,
        $row['catalog_provider_series_id'] ?? null
    );

    return [
        'found' => true,
        'local_series_id' => (int)$row['local_series_id'],
        'provider_series_id' => $providerSeriesId,
        'provider' => first_non_blank($row['availability_provider'] ?? null, $queueRow['provider'] ?? null, $row['catalog_provider'] ?? null),
        'catalog_title' => $row['catalog_title'] ?? null,
        'clean_search_name' => $row['clean_search_name'] ?? null,
        'tmdb_search_name' => $row['tmdb_search_name'] ?? null,
        'provider_series_name' => $row['provider_series_name'] ?? null,
        'provider_series_clean_name' => $row['provider_series_clean_name'] ?? null,
        'poster_url' => first_non_blank(
            $row['series_tmdb_cover_url'] ?? null,
            $row['series_poster_url'] ?? null,
            $row['series_cover_url'] ?? null,
            $row['series_provider_cover_url'] ?? null
        ),
        'backdrop_url' => first_non_blank(
            $row['series_tmdb_backdrop_url'] ?? null,
            $row['series_backdrop_url'] ?? null,
            $row['series_provider_backdrop_url'] ?? null
        ),
    ];
}

function get_current_image_state(PDO $pdo, int $localSeriesId): array
{
    $sql = "
        SELECT
            s.id,
            s.poster_url AS series_poster_url,
            s.cover_url AS series_cover_url,
            s.tmdb_cover_url AS series_tmdb_cover_url,
            s.provider_cover_url AS series_provider_cover_url,
            s.backdrop_url AS series_backdrop_url,
            s.tmdb_backdrop_url AS series_tmdb_backdrop_url,
            s.provider_backdrop_url AS series_provider_backdrop_url
        FROM xpdgxfsp_content.series s
        WHERE s.id = :series_id
        LIMIT 1
    ";

    $stmt = $pdo->prepare($sql);
    $stmt->execute([':series_id' => $localSeriesId]);
    $row = $stmt->fetch(PDO::FETCH_ASSOC);

    if (!$row) {
        return [
            'poster_url' => null,
            'backdrop_url' => null,
            'missing_now' => ['poster_url', 'backdrop_url'],
        ];
    }

    $poster = first_non_blank(
        $row['series_tmdb_cover_url'] ?? null,
        $row['series_poster_url'] ?? null,
        $row['series_cover_url'] ?? null,
        $row['series_provider_cover_url'] ?? null
    );

    $backdrop = first_non_blank(
        $row['series_tmdb_backdrop_url'] ?? null,
        $row['series_backdrop_url'] ?? null,
        $row['series_provider_backdrop_url'] ?? null
    );

    $missing = [];
    if ($poster === null) {
        $missing[] = 'poster_url';
    }
    if ($backdrop === null) {
        $missing[] = 'backdrop_url';
    }

    return [
        'poster_url' => $poster,
        'backdrop_url' => $backdrop,
        'missing_now' => $missing,
    ];
}

function requested_images_repaired(array $requestedImageFields, array $imageState): array
{
    $stillMissing = [];

    foreach ($requestedImageFields as $field) {
        if ($field === 'poster_url' && first_non_blank($imageState['poster_url'] ?? null) === null) {
            $stillMissing[] = 'poster_url';
        }
        if ($field === 'backdrop_url' && first_non_blank($imageState['backdrop_url'] ?? null) === null) {
            $stillMissing[] = 'backdrop_url';
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
    $releaseDate = first_non_blank($written['release_date'] ?? null);
    $genres = first_non_blank($written['genres'] ?? null);
    $primaryGenre = first_non_blank($written['primary_genre'] ?? null);
    $cast = first_non_blank($written['cast'] ?? null);
    $trailer = first_non_blank($written['youtube_trailer'] ?? null);

    if ($tmdbId > 0 && ($title !== null || $poster !== null)) {
        return true;
    }

    if ($poster !== null || $releaseDate !== null || $genres !== null || $primaryGenre !== null || $cast !== null || $trailer !== null) {
        return true;
    }

    return false;
}


function series_shelf_has_usable_artwork_or_metadata(array $imageState, array $materializerJson): bool
{
    $poster = first_non_blank($imageState['poster_url'] ?? null);
    if ($poster !== null) {
        return true;
    }

    $written = $materializerJson['written'] ?? null;
    if (!is_array($written)) {
        return false;
    }

    $posterWritten = first_non_blank($written['poster_url'] ?? null);
    if ($posterWritten !== null) {
        return true;
    }

    return false;
}


function is_port_900_artwork_url(?string $url): bool
{
    $url = first_non_blank($url);
    if ($url === null) {
        return false;
    }

    $lower = strtolower($url);

    if (strpos($lower, ':900/') !== false || strpos($lower, ':9000/') !== false) {
        return true;
    }

    $parts = @parse_url($url);
    if (is_array($parts) && isset($parts['port']) && (int)$parts['port'] === 900) {
        return true;
    }

    return false;
}

function is_known_bad_provider_artwork_url(?string $url): bool
{
    $url = first_non_blank($url);
    if ($url === null) {
        return false;
    }

    $lower = strtolower($url);

    if (is_port_900_artwork_url($lower)) {
        return true;
    }

    // Known provider artwork paths that have proven unavailable/unstable for app display.
    if (preg_match('#^https?://[^/]+/images/#i', $lower) && !is_tmdb_artwork_url($lower)) {
        return true;
    }

    return false;
}

function is_tmdb_artwork_url(?string $url): bool
{
    $url = first_non_blank($url);
    if ($url === null) {
        return false;
    }

    return stripos($url, 'https://image.tmdb.org/') === 0 || stripos($url, 'http://image.tmdb.org/') === 0;
}

function is_safe_replacement_artwork_url(?string $url): bool
{
    $url = first_non_blank($url);
    if ($url === null) {
        return false;
    }

    if (is_known_bad_provider_artwork_url($url)) {
        return false;
    }

    if (is_tmdb_artwork_url($url)) {
        return true;
    }

    // Allow future non-provider HTTPS artwork sources, but do not allow port-900/provider image paths.
    return stripos($url, 'https://') === 0;
}

function series_port_900_has_safe_replacement_artwork(array $imageState, array $materializerJson): bool
{
    if (is_safe_replacement_artwork_url($imageState['poster_url'] ?? null)) {
        return true;
    }

    if (is_safe_replacement_artwork_url($imageState['backdrop_url'] ?? null)) {
        return true;
    }

    $written = $materializerJson['written'] ?? null;
    if (!is_array($written)) {
        return false;
    }

    if (is_safe_replacement_artwork_url($written['poster_url'] ?? null)) {
        return true;
    }

    if (is_safe_replacement_artwork_url($written['backdrop_url'] ?? null)) {
        return true;
    }

    if (is_safe_replacement_artwork_url($written['backdrop_original_url'] ?? null)) {
        return true;
    }

    return false;
}


function fetch_series_artwork_candidates(PDO $pdo, int $seriesId, ?int $queueId = null, int $limit = 10): array
{
    $params = [
        ':content_id' => $seriesId,
    ];

    $queueClause = '';
    if ($queueId !== null && $queueId > 0) {
        $queueClause = ' AND (queue_id = :queue_id OR queue_id IS NULL)';
        $params[':queue_id'] = $queueId;
    }

    $sql = "
        SELECT
            id,
            media_type,
            content_id,
            provider,
            provider_content_id,
            queue_id,
            title,
            clean_search_name,
            candidate_url,
            candidate_kind,
            candidate_source,
            candidate_status,
            confidence_score,
            reason,
            created_at,
            updated_at
        FROM xpdgxfsp_content.content_artwork_candidates
        WHERE media_type = 'series'
          AND content_id = :content_id
          " . $queueClause . "
          AND candidate_status IN ('accepted', 'pending_review')
        ORDER BY
            FIELD(candidate_status, 'accepted', 'pending_review'),
            confidence_score DESC,
            updated_at DESC,
            id DESC
        LIMIT " . max(1, min(25, $limit)) . "
    ";

    $stmt = $pdo->prepare($sql);
    $stmt->execute($params);
    return $stmt->fetchAll(PDO::FETCH_ASSOC) ?: [];
}

function first_safe_series_artwork_candidate(PDO $pdo, int $seriesId, ?int $queueId = null): ?array
{
    $candidates = fetch_series_artwork_candidates($pdo, $seriesId, $queueId, 10);

    foreach ($candidates as $candidate) {
        $url = first_non_blank($candidate['candidate_url'] ?? null);
        if ($url !== null && is_safe_replacement_artwork_url($url)) {
            return $candidate;
        }
    }

    return null;
}

function update_queue_needs_manual_match(PDO $pdo, int $queueId, string $message): void
{
    $stmt = $pdo->prepare("
        UPDATE xpdgxfsp_ip.content_materialization_queue
        SET
            status = 'needs_manual_match',
            last_error = :last_error,
            completed_at = NULL,
            updated_at = NOW()
        WHERE id = :id
        LIMIT 1
    ");
    $stmt->execute([
        ':last_error' => mb_substr($message, 0, 2000),
        ':id' => $queueId,
    ]);
}

function attach_candidate_pending_if_available(
    PDO $pdo,
    array &$item,
    array $queueRow,
    int $queueIdValue,
    bool $onlySeriesPort900ImageRepair,
    string $messagePrefix
): bool {
    if (
        !$onlySeriesPort900ImageRepair
        || clean($queueRow['trigger_reason'] ?? '') !== 'series_port_900_image_repair'
    ) {
        return false;
    }

    $candidate = first_safe_series_artwork_candidate(
        $pdo,
        (int)$queueRow['content_id'],
        $queueIdValue
    );

    if ($candidate === null) {
        return false;
    }

    update_queue_needs_manual_match(
        $pdo,
        $queueIdValue,
        $messagePrefix . '; candidate_id=' . (int)$candidate['id']
    );

    $item['queue_status'] = 'needs_manual_match';
    $item['completion_policy'] = 'candidate_pending_manual_review';
    $item['candidate_pending'] = $candidate;
    $item['completion_note'] = 'Safe non-port-900 artwork candidate exists in content_artwork_candidates. Queue moved to needs_manual_match for review/promotion instead of blind retry.';

    return true;
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

function call_materializer(int $localSeriesId, ?string $providerSeriesId, int $queueId, string $reason): array
{
    $params = [
        'series_id' => $localSeriesId,
        'reason' => $reason,
        'queue_id' => $queueId,
    ];

    if ($providerSeriesId !== null && $providerSeriesId !== '') {
        $params['provider_series_id'] = $providerSeriesId;
    }

    $url = 'https://miratv.club/_workers/ai/api/materialize_series_preview.php?' . http_build_query($params);

    $body = '';
    $status = 0;
    $error = null;

    if (function_exists('curl_init')) {
        $ch = curl_init($url);
        if ($ch === false) {
            return [
                'url' => $url,
                'http_status' => 0,
                'body' => null,
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
                'User-Agent: MiraTV-Series-Metadata-Queue/6B-5E',
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
                'header' => "Accept: application/json\r\nUser-Agent: MiraTV-Series-Metadata-Queue/6B-5E\r\n",
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
    $includePreviewMissing = (int)($_GET['include_preview_missing'] ?? 0) === 1;
    $includeUnmatchedLocal = (int)($_GET['include_unmatched_local'] ?? 0) === 1;
    $onlyUnmatchedLocal = (int)($_GET['only_unmatched_local'] ?? 0) === 1;
    $onlySeriesShelfMissing = (int)($_GET['only_series_shelf_missing'] ?? 0) === 1;
    $onlySeriesPort900ImageRepair = (int)($_GET['only_series_port_900_image_repair'] ?? 0) === 1;

    $pdo = open_pdo();
    $rows = get_queue_rows(
        $pdo,
        $queueId,
        $limit,
        $includePreviewMissing,
        $includeUnmatchedLocal,
        $onlyUnmatchedLocal,
        $onlySeriesShelfMissing,
        $onlySeriesPort900ImageRepair
    );

    $items = [];
    $completed = 0;
    $failed = 0;
    $requeued = 0;
    $manual = 0;
    $partialCompleted = 0;

    foreach ($rows as $queueRow) {
        $queueIdValue = (int)$queueRow['id'];
        $context = load_context($pdo, $queueRow);
        $requestedFields = split_missing_fields($queueRow['missing_fields'] ?? '');
        $requestedImageFields = normalize_requested_image_fields($requestedFields);
        $localSeriesId = (int)($context['local_series_id'] ?? $queueRow['content_id']);
        $providerSeriesId = clean($context['provider_series_id'] ?? $queueRow['provider_content_id'] ?? '');

        $item = [
            'queue_id' => $queueIdValue,
            'content_id' => (int)$queueRow['content_id'],
            'provider' => clean($queueRow['provider'] ?? ''),
            'provider_content_id' => clean($queueRow['provider_content_id'] ?? ''),
            'mac_user_id' => (int)($queueRow['mac_user_id'] ?? 0),
            'missing_fields' => clean($queueRow['missing_fields'] ?? ''),
            'requested_image_fields' => $requestedImageFields,
            'trigger_reason' => clean($queueRow['trigger_reason'] ?? ''),
            'local_series_id' => $localSeriesId,
            'provider_series_id' => $providerSeriesId,
            'catalog_title' => $context['catalog_title'] ?? null,
            'clean_search_name' => $context['clean_search_name'] ?? null,
            'tmdb_search_name' => $context['tmdb_search_name'] ?? null,
            'provider_series_name' => $context['provider_series_name'] ?? null,
            'provider_series_clean_name' => $context['provider_series_clean_name'] ?? null,
            'dry_run' => $dryRun,
            'materializer_url_preview' => 'https://miratv.club/_workers/ai/api/materialize_series_preview.php?' . http_build_query([
                'series_id' => $localSeriesId,
                'reason' => 'queue_' . clean($queueRow['trigger_reason'] ?? 'metadata'),
                'queue_id' => $queueIdValue,
                'provider_series_id' => $providerSeriesId,
            ]),
        ];

        if ($dryRun) {
            $item['action'] = 'would_call_materialize_series_preview_then_verify_requested_images';
            $items[] = $item;
            continue;
        }

        update_queue_started($pdo, $queueIdValue);
        $call = call_materializer(
            $localSeriesId,
            $providerSeriesId !== '' ? $providerSeriesId : null,
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
            if (attach_candidate_pending_if_available(
                $pdo,
                $item,
                $queueRow,
                $queueIdValue,
                $onlySeriesPort900ImageRepair,
                'candidate_pending: materializer http/non-json failure but safe artwork candidate exists; manual review required before catalog promotion'
            )) {
                $manual++;
                $items[] = $item;
                continue;
            }

            $status = update_queue_retry_or_failed(
                $pdo,
                $queueRow,
                'http_status=' . $call['http_status'] . ' | error=' . ($call['error'] ?: 'non-json or failed materializer')
            );
            if ($status === 'failed') {
                $failed++;
            } elseif ($status === 'needs_manual_match') {
                $manual++;
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

            if (attach_candidate_pending_if_available(
                $pdo,
                $item,
                $queueRow,
                $queueIdValue,
                $onlySeriesPort900ImageRepair,
                'candidate_pending: materializer returned ' . $code . ' but safe artwork candidate exists; manual review required before catalog promotion'
            )) {
                $manual++;
                $items[] = $item;
                continue;
            }

            $preferManual = in_array($code, ['TMDB_NO_MATCH', 'SAFE_RESOLUTION_FAILED', 'QUEUE_CONTENT_ID_MISMATCH'], true);
            $status = update_queue_retry_or_failed(
                $pdo,
                $queueRow,
                'http_status=' . $call['http_status'] . ' | code=' . $code . ' | json_error=' . $err,
                $preferManual
            );
            if ($status === 'failed') {
                $failed++;
            } elseif ($status === 'needs_manual_match') {
                $manual++;
            } else {
                $requeued++;
            }
            $item['queue_status'] = $status;
            $items[] = $item;
            continue;
        }

        $imageState = get_current_image_state($pdo, $localSeriesId);
        $verification = requested_images_repaired($requestedImageFields, $imageState);
        $item['image_state_after'] = $imageState;
        $item['requested_image_verification'] = $verification;

        if (!$verification['repaired']) {
            $useUnmatchedPartialCompletion = (
                $onlyUnmatchedLocal
                && clean($queueRow['trigger_reason'] ?? '') === 'unmatched_series_local_row_created'
                && materializer_wrote_useful_metadata($call['json'])
            );

            $useShelfPosterCompletion = (
                $onlySeriesShelfMissing
                && clean($queueRow['trigger_reason'] ?? '') === 'series_shelf_missing_images'
                && series_shelf_has_usable_artwork_or_metadata($imageState, $call['json'])
            );

            $usePort900ReplacementCompletion = (
                $onlySeriesPort900ImageRepair
                && clean($queueRow['trigger_reason'] ?? '') === 'series_port_900_image_repair'
                && series_port_900_has_safe_replacement_artwork($imageState, $call['json'])
            );

            if ($useUnmatchedPartialCompletion || $useShelfPosterCompletion || $usePort900ReplacementCompletion) {
                update_queue_completed($pdo, $queueIdValue);
                $completed++;
                $partialCompleted++;
                $item['queue_status'] = 'completed';

                if ($usePort900ReplacementCompletion) {
                    $item['completion_policy'] = 'partial_port_900_artwork_replaced';
                    $item['completion_note'] = 'Port 900 artwork was treated as replace-only; a safe non-port-900 poster/backdrop replacement was present after materialization, so the row completed even if other requested image fields remain unavailable.';
                } elseif ($useShelfPosterCompletion) {
                    $item['completion_policy'] = 'partial_series_shelf_poster_completed';
                    $item['completion_note'] = 'Series shelf image repair wrote usable poster artwork or useful shelf metadata; completed even though requested backdrop remains unavailable.';
                } else {
                    $item['completion_policy'] = 'partial_unmatched_metadata_completed';
                    $item['completion_note'] = 'TMDb wrote useful metadata but requested images remain missing; completed because only_unmatched_local rows should not retry forever for unavailable backdrop images.';
                }

                $items[] = $item;
                continue;
            }

            if (attach_candidate_pending_if_available(
                $pdo,
                $item,
                $queueRow,
                $queueIdValue,
                $onlySeriesPort900ImageRepair,
                'candidate_pending: materializer did not produce safe replacement artwork but safe artwork candidate exists; manual review required before catalog promotion'
            )) {
                $manual++;
                $items[] = $item;
                continue;
            }

            $preferManualForMissingImages = in_array(clean($queueRow['trigger_reason'] ?? ''), [
                'series_shelf_missing_images',
                'missing_series_images_scan',
                'series_port_900_image_repair',
            ], true);

            $status = update_queue_retry_or_failed(
                $pdo,
                $queueRow,
                'materializer_ok_but_requested_images_still_missing=' . implode(',', $verification['still_missing']),
                $preferManualForMissingImages
            );
            if ($status === 'failed') {
                $failed++;
            } elseif ($status === 'needs_manual_match') {
                $manual++;
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
        'include_preview_missing' => $includePreviewMissing,
        'include_unmatched_local' => $includeUnmatchedLocal,
        'only_unmatched_local' => $onlyUnmatchedLocal,
        'only_series_shelf_missing' => $onlySeriesShelfMissing,
        'only_series_port_900_image_repair' => $onlySeriesPort900ImageRepair,
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
 * MiraTV Step 6B-5E10 - Series Metadata Queue Processor
 *
 * Target path:
 *   /home/xpdgxfsp/public_html/_workers/ai/api/process_series_metadata_queue.php
 *
 * Purpose:
 *   Process queued Series metadata/image materialization rows.
 *   Calls materialize_series_preview.php, then verifies that requested image fields
 *   were actually repaired before marking the queue row completed. Uses
 *   xpdgxfsp_content.series image columns only for verification.
 *
 * Important behavior:
 *   - A TMDb match alone is not enough for strict image-repair queue completion.
 *   - If missing_fields includes poster_url, poster/image must exist after materializer.
 *   - If missing_fields includes backdrop_url, backdrop must exist after materializer.
 *   - If requested image fields are still missing, strict rows stay queued until max_attempts.
 *
 * Trigger controls:
 *   - include_preview_missing=1 adds preview_missing_fields to the normal reason list.
 *   - include_unmatched_local=1 adds unmatched_series_local_row_created to the normal reason list.
 *   - only_unmatched_local=1 restricts the processor to only unmatched_series_local_row_created.
 *   - only_series_shelf_missing=1 restricts the processor to only series_shelf_missing_images.
 *   - only_series_port_900_image_repair=1 restricts the processor to only series_port_900_image_repair.
 *
 * Partial completion policy:
 *   - For only_unmatched_local=1 rows, a successful TMDb materialization that writes useful metadata
 *     may complete the queue row even when backdrop_url is unavailable from TMDb.
 *   - TMDB_NO_MATCH still remains queued/failed/manual according to normal retry rules.
 */

const ENDPOINT_VERSION = '6B-5E10-2026-05-27-manual-counter-fix';

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

function is_image_field(string $field): bool
{
    return in_array($field, ['poster_url', 'image_url', 'backdrop_url', 'poster', 'backdrop'], true);
}

function normalize_requested_image_fields(array $fields): array
{
    $normalized = [];
    foreach ($fields as $field) {
        $field = clean($field);
        if ($field === 'poster' || $field === 'image_url') {
            $field = 'poster_url';
        }
        if ($field === 'backdrop') {
            $field = 'backdrop_url';
        }
        if (is_image_field($field)) {
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

function get_queue_rows(
    PDO $pdo,
    ?int $queueId,
    int $limit,
    bool $includePreviewMissing,
    bool $includeUnmatchedLocal,
    bool $onlyUnmatchedLocal,
    bool $onlySeriesShelfMissing,
    bool $onlySeriesPort900ImageRepair
): array {
    if ($queueId !== null && $queueId > 0) {
        $sql = "
            SELECT *
            FROM xpdgxfsp_ip.content_materialization_queue
            WHERE id = :queue_id
              AND content_type = 'series'
              AND materialization_kind = 'metadata'
            LIMIT 1
        ";
        $stmt = $pdo->prepare($sql);
        $stmt->execute([':queue_id' => $queueId]);
        return $stmt->fetchAll(PDO::FETCH_ASSOC);
    }

    if ($onlyUnmatchedLocal) {
        $reasons = ["'unmatched_series_local_row_created'"];
    } elseif ($onlySeriesShelfMissing) {
        $reasons = ["'series_shelf_missing_images'"];
    } elseif ($onlySeriesPort900ImageRepair) {
        $reasons = ["'series_port_900_image_repair'"];
    } else {
        $reasons = ["'missing_series_images_scan'", "'series_shelf_missing_images'"];

        if ($includePreviewMissing) {
            $reasons[] = "'preview_missing_fields'";
        }

        if ($includeUnmatchedLocal) {
            $reasons[] = "'unmatched_series_local_row_created'";
        }
    }

    $sql = "
        SELECT *
        FROM xpdgxfsp_ip.content_materialization_queue
        WHERE content_type = 'series'
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

function load_context(PDO $pdo, array $queueRow): array
{
    $contentId = (int)$queueRow['content_id'];
    $providerContentId = clean($queueRow['provider_content_id'] ?? '');
    $macUserId = (int)($queueRow['mac_user_id'] ?? 0);

    $sql = "
        SELECT
            s.id AS local_series_id,
            s.provider_series_id AS catalog_provider_series_id,
            s.provider AS catalog_provider,
            s.name AS catalog_title,
            s.poster_url AS series_poster_url,
            s.cover_url AS series_cover_url,
            s.tmdb_cover_url AS series_tmdb_cover_url,
            s.provider_cover_url AS series_provider_cover_url,
            s.backdrop_url AS series_backdrop_url,
            s.tmdb_backdrop_url AS series_tmdb_backdrop_url,
            s.provider_backdrop_url AS series_provider_backdrop_url,
            s.clean_search_name,
            s.tmdb_search_name,
            usa.provider AS availability_provider,
            usa.provider_series_id AS availability_provider_series_id,
            usa.provider_series_name,
            usa.provider_series_clean_name,
            usa.local_series_id AS availability_local_series_id
        FROM xpdgxfsp_content.series s
        LEFT JOIN xpdgxfsp_ip.user_series_availability usa
            ON usa.mac_user_id = :mac_user_id
           AND (
                usa.local_series_id = s.id
                OR usa.provider_series_id = :provider_content_id_join
           )
        WHERE s.id = :content_id
        LIMIT 1
    ";

    $stmt = $pdo->prepare($sql);
    $stmt->execute([
        ':mac_user_id' => $macUserId,
        ':provider_content_id_join' => $providerContentId,
        ':content_id' => $contentId,
    ]);

    $row = $stmt->fetch(PDO::FETCH_ASSOC);

    if (!$row) {
        return [
            'found' => false,
            'local_series_id' => $contentId,
            'provider_series_id' => $providerContentId,
            'provider' => clean($queueRow['provider'] ?? ''),
            'catalog_title' => null,
            'clean_search_name' => null,
            'tmdb_search_name' => null,
            'provider_series_name' => null,
            'provider_series_clean_name' => null,
        ];
    }

    $providerSeriesId = first_non_blank(
        $providerContentId,
        $row['availability_provider_series_id'] ?? null,
        $row['catalog_provider_series_id'] ?? null
    );

    return [
        'found' => true,
        'local_series_id' => (int)$row['local_series_id'],
        'provider_series_id' => $providerSeriesId,
        'provider' => first_non_blank($row['availability_provider'] ?? null, $queueRow['provider'] ?? null, $row['catalog_provider'] ?? null),
        'catalog_title' => $row['catalog_title'] ?? null,
        'clean_search_name' => $row['clean_search_name'] ?? null,
        'tmdb_search_name' => $row['tmdb_search_name'] ?? null,
        'provider_series_name' => $row['provider_series_name'] ?? null,
        'provider_series_clean_name' => $row['provider_series_clean_name'] ?? null,
        'poster_url' => first_non_blank(
            $row['series_tmdb_cover_url'] ?? null,
            $row['series_poster_url'] ?? null,
            $row['series_cover_url'] ?? null,
            $row['series_provider_cover_url'] ?? null
        ),
        'backdrop_url' => first_non_blank(
            $row['series_tmdb_backdrop_url'] ?? null,
            $row['series_backdrop_url'] ?? null,
            $row['series_provider_backdrop_url'] ?? null
        ),
    ];
}

function get_current_image_state(PDO $pdo, int $localSeriesId): array
{
    $sql = "
        SELECT
            s.id,
            s.poster_url AS series_poster_url,
            s.cover_url AS series_cover_url,
            s.tmdb_cover_url AS series_tmdb_cover_url,
            s.provider_cover_url AS series_provider_cover_url,
            s.backdrop_url AS series_backdrop_url,
            s.tmdb_backdrop_url AS series_tmdb_backdrop_url,
            s.provider_backdrop_url AS series_provider_backdrop_url
        FROM xpdgxfsp_content.series s
        WHERE s.id = :series_id
        LIMIT 1
    ";

    $stmt = $pdo->prepare($sql);
    $stmt->execute([':series_id' => $localSeriesId]);
    $row = $stmt->fetch(PDO::FETCH_ASSOC);

    if (!$row) {
        return [
            'poster_url' => null,
            'backdrop_url' => null,
            'missing_now' => ['poster_url', 'backdrop_url'],
        ];
    }

    $poster = first_non_blank(
        $row['series_tmdb_cover_url'] ?? null,
        $row['series_poster_url'] ?? null,
        $row['series_cover_url'] ?? null,
        $row['series_provider_cover_url'] ?? null
    );

    $backdrop = first_non_blank(
        $row['series_tmdb_backdrop_url'] ?? null,
        $row['series_backdrop_url'] ?? null,
        $row['series_provider_backdrop_url'] ?? null
    );

    $missing = [];
    if ($poster === null) {
        $missing[] = 'poster_url';
    }
    if ($backdrop === null) {
        $missing[] = 'backdrop_url';
    }

    return [
        'poster_url' => $poster,
        'backdrop_url' => $backdrop,
        'missing_now' => $missing,
    ];
}

function requested_images_repaired(array $requestedImageFields, array $imageState): array
{
    $stillMissing = [];

    foreach ($requestedImageFields as $field) {
        if ($field === 'poster_url' && first_non_blank($imageState['poster_url'] ?? null) === null) {
            $stillMissing[] = 'poster_url';
        }
        if ($field === 'backdrop_url' && first_non_blank($imageState['backdrop_url'] ?? null) === null) {
            $stillMissing[] = 'backdrop_url';
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
    $releaseDate = first_non_blank($written['release_date'] ?? null);
    $genres = first_non_blank($written['genres'] ?? null);
    $primaryGenre = first_non_blank($written['primary_genre'] ?? null);
    $cast = first_non_blank($written['cast'] ?? null);
    $trailer = first_non_blank($written['youtube_trailer'] ?? null);

    if ($tmdbId > 0 && ($title !== null || $poster !== null)) {
        return true;
    }

    if ($poster !== null || $releaseDate !== null || $genres !== null || $primaryGenre !== null || $cast !== null || $trailer !== null) {
        return true;
    }

    return false;
}


function series_shelf_has_usable_artwork_or_metadata(array $imageState, array $materializerJson): bool
{
    $poster = first_non_blank($imageState['poster_url'] ?? null);
    if ($poster !== null) {
        return true;
    }

    $written = $materializerJson['written'] ?? null;
    if (!is_array($written)) {
        return false;
    }

    $posterWritten = first_non_blank($written['poster_url'] ?? null);
    if ($posterWritten !== null) {
        return true;
    }

    return false;
}


function is_port_900_artwork_url(?string $url): bool
{
    $url = first_non_blank($url);
    if ($url === null) {
        return false;
    }

    $lower = strtolower($url);

    if (strpos($lower, ':900/') !== false || strpos($lower, ':9000/') !== false) {
        return true;
    }

    $parts = @parse_url($url);
    if (is_array($parts) && isset($parts['port']) && (int)$parts['port'] === 900) {
        return true;
    }

    return false;
}

function is_known_bad_provider_artwork_url(?string $url): bool
{
    $url = first_non_blank($url);
    if ($url === null) {
        return false;
    }

    $lower = strtolower($url);

    if (is_port_900_artwork_url($lower)) {
        return true;
    }

    // Known provider artwork paths that have proven unavailable/unstable for app display.
    if (preg_match('#^https?://[^/]+/images/#i', $lower) && !is_tmdb_artwork_url($lower)) {
        return true;
    }

    return false;
}

function is_tmdb_artwork_url(?string $url): bool
{
    $url = first_non_blank($url);
    if ($url === null) {
        return false;
    }

    return stripos($url, 'https://image.tmdb.org/') === 0 || stripos($url, 'http://image.tmdb.org/') === 0;
}

function is_safe_replacement_artwork_url(?string $url): bool
{
    $url = first_non_blank($url);
    if ($url === null) {
        return false;
    }

    if (is_known_bad_provider_artwork_url($url)) {
        return false;
    }

    if (is_tmdb_artwork_url($url)) {
        return true;
    }

    // Allow future non-provider HTTPS artwork sources, but do not allow port-900/provider image paths.
    return stripos($url, 'https://') === 0;
}

function series_port_900_has_safe_replacement_artwork(array $imageState, array $materializerJson): bool
{
    if (is_safe_replacement_artwork_url($imageState['poster_url'] ?? null)) {
        return true;
    }

    if (is_safe_replacement_artwork_url($imageState['backdrop_url'] ?? null)) {
        return true;
    }

    $written = $materializerJson['written'] ?? null;
    if (!is_array($written)) {
        return false;
    }

    if (is_safe_replacement_artwork_url($written['poster_url'] ?? null)) {
        return true;
    }

    if (is_safe_replacement_artwork_url($written['backdrop_url'] ?? null)) {
        return true;
    }

    if (is_safe_replacement_artwork_url($written['backdrop_original_url'] ?? null)) {
        return true;
    }

    return false;
}


function fetch_series_artwork_candidates(PDO $pdo, int $seriesId, ?int $queueId = null, int $limit = 10): array
{
    $params = [
        ':content_id' => $seriesId,
    ];

    $queueClause = '';
    if ($queueId !== null && $queueId > 0) {
        $queueClause = ' AND (queue_id = :queue_id OR queue_id IS NULL)';
        $params[':queue_id'] = $queueId;
    }

    $sql = "
        SELECT
            id,
            media_type,
            content_id,
            provider,
            provider_content_id,
            queue_id,
            title,
            clean_search_name,
            candidate_url,
            candidate_kind,
            candidate_source,
            candidate_status,
            confidence_score,
            reason,
            created_at,
            updated_at
        FROM xpdgxfsp_content.content_artwork_candidates
        WHERE media_type = 'series'
          AND content_id = :content_id
          " . $queueClause . "
          AND candidate_status IN ('accepted', 'pending_review')
        ORDER BY
            FIELD(candidate_status, 'accepted', 'pending_review'),
            confidence_score DESC,
            updated_at DESC,
            id DESC
        LIMIT " . max(1, min(25, $limit)) . "
    ";

    $stmt = $pdo->prepare($sql);
    $stmt->execute($params);
    return $stmt->fetchAll(PDO::FETCH_ASSOC) ?: [];
}

function first_safe_series_artwork_candidate(PDO $pdo, int $seriesId, ?int $queueId = null): ?array
{
    $candidates = fetch_series_artwork_candidates($pdo, $seriesId, $queueId, 10);

    foreach ($candidates as $candidate) {
        $url = first_non_blank($candidate['candidate_url'] ?? null);
        if ($url !== null && is_safe_replacement_artwork_url($url)) {
            return $candidate;
        }
    }

    return null;
}

function update_queue_needs_manual_match(PDO $pdo, int $queueId, string $message): void
{
    $stmt = $pdo->prepare("
        UPDATE xpdgxfsp_ip.content_materialization_queue
        SET
            status = 'needs_manual_match',
            last_error = :last_error,
            completed_at = NULL,
            updated_at = NOW()
        WHERE id = :id
        LIMIT 1
    ");
    $stmt->execute([
        ':last_error' => mb_substr($message, 0, 2000),
        ':id' => $queueId,
    ]);
}

function attach_candidate_pending_if_available(
    PDO $pdo,
    array &$item,
    array $queueRow,
    int $queueIdValue,
    bool $onlySeriesPort900ImageRepair,
    string $messagePrefix
): bool {
    if (
        !$onlySeriesPort900ImageRepair
        || clean($queueRow['trigger_reason'] ?? '') !== 'series_port_900_image_repair'
    ) {
        return false;
    }

    $candidate = first_safe_series_artwork_candidate(
        $pdo,
        (int)$queueRow['content_id'],
        $queueIdValue
    );

    if ($candidate === null) {
        return false;
    }

    update_queue_needs_manual_match(
        $pdo,
        $queueIdValue,
        $messagePrefix . '; candidate_id=' . (int)$candidate['id']
    );

    $item['queue_status'] = 'needs_manual_match';
    $item['completion_policy'] = 'candidate_pending_manual_review';
    $item['candidate_pending'] = $candidate;
    $item['completion_note'] = 'Safe non-port-900 artwork candidate exists in content_artwork_candidates. Queue moved to needs_manual_match for review/promotion instead of blind retry.';

    return true;
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

function call_materializer(int $localSeriesId, ?string $providerSeriesId, int $queueId, string $reason): array
{
    $params = [
        'series_id' => $localSeriesId,
        'reason' => $reason,
        'queue_id' => $queueId,
    ];

    if ($providerSeriesId !== null && $providerSeriesId !== '') {
        $params['provider_series_id'] = $providerSeriesId;
    }

    $url = 'https://miratv.club/_workers/ai/api/materialize_series_preview.php?' . http_build_query($params);

    $body = '';
    $status = 0;
    $error = null;

    if (function_exists('curl_init')) {
        $ch = curl_init($url);
        if ($ch === false) {
            return [
                'url' => $url,
                'http_status' => 0,
                'body' => null,
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
                'User-Agent: MiraTV-Series-Metadata-Queue/6B-5E',
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
                'header' => "Accept: application/json\r\nUser-Agent: MiraTV-Series-Metadata-Queue/6B-5E\r\n",
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
    $includePreviewMissing = (int)($_GET['include_preview_missing'] ?? 0) === 1;
    $includeUnmatchedLocal = (int)($_GET['include_unmatched_local'] ?? 0) === 1;
    $onlyUnmatchedLocal = (int)($_GET['only_unmatched_local'] ?? 0) === 1;
    $onlySeriesShelfMissing = (int)($_GET['only_series_shelf_missing'] ?? 0) === 1;
    $onlySeriesPort900ImageRepair = (int)($_GET['only_series_port_900_image_repair'] ?? 0) === 1;

    $pdo = open_pdo();
    $rows = get_queue_rows(
        $pdo,
        $queueId,
        $limit,
        $includePreviewMissing,
        $includeUnmatchedLocal,
        $onlyUnmatchedLocal,
        $onlySeriesShelfMissing,
        $onlySeriesPort900ImageRepair
    );

    $items = [];
    $completed = 0;
    $failed = 0;
    $requeued = 0;
    $manual = 0;
    $partialCompleted = 0;

    foreach ($rows as $queueRow) {
        $queueIdValue = (int)$queueRow['id'];
        $context = load_context($pdo, $queueRow);
        $requestedFields = split_missing_fields($queueRow['missing_fields'] ?? '');
        $requestedImageFields = normalize_requested_image_fields($requestedFields);
        $localSeriesId = (int)($context['local_series_id'] ?? $queueRow['content_id']);
        $providerSeriesId = clean($context['provider_series_id'] ?? $queueRow['provider_content_id'] ?? '');

        $item = [
            'queue_id' => $queueIdValue,
            'content_id' => (int)$queueRow['content_id'],
            'provider' => clean($queueRow['provider'] ?? ''),
            'provider_content_id' => clean($queueRow['provider_content_id'] ?? ''),
            'mac_user_id' => (int)($queueRow['mac_user_id'] ?? 0),
            'missing_fields' => clean($queueRow['missing_fields'] ?? ''),
            'requested_image_fields' => $requestedImageFields,
            'trigger_reason' => clean($queueRow['trigger_reason'] ?? ''),
            'local_series_id' => $localSeriesId,
            'provider_series_id' => $providerSeriesId,
            'catalog_title' => $context['catalog_title'] ?? null,
            'clean_search_name' => $context['clean_search_name'] ?? null,
            'tmdb_search_name' => $context['tmdb_search_name'] ?? null,
            'provider_series_name' => $context['provider_series_name'] ?? null,
            'provider_series_clean_name' => $context['provider_series_clean_name'] ?? null,
            'dry_run' => $dryRun,
            'materializer_url_preview' => 'https://miratv.club/_workers/ai/api/materialize_series_preview.php?' . http_build_query([
                'series_id' => $localSeriesId,
                'reason' => 'queue_' . clean($queueRow['trigger_reason'] ?? 'metadata'),
                'queue_id' => $queueIdValue,
                'provider_series_id' => $providerSeriesId,
            ]),
        ];

        if ($dryRun) {
            $item['action'] = 'would_call_materialize_series_preview_then_verify_requested_images';
            $items[] = $item;
            continue;
        }

        update_queue_started($pdo, $queueIdValue);
        $call = call_materializer(
            $localSeriesId,
            $providerSeriesId !== '' ? $providerSeriesId : null,
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
            if (attach_candidate_pending_if_available(
                $pdo,
                $item,
                $queueRow,
                $queueIdValue,
                $onlySeriesPort900ImageRepair,
                'candidate_pending: materializer http/non-json failure but safe artwork candidate exists; manual review required before catalog promotion'
            )) {
                $manual++;
                $items[] = $item;
                continue;
            }

            $status = update_queue_retry_or_failed(
                $pdo,
                $queueRow,
                'http_status=' . $call['http_status'] . ' | error=' . ($call['error'] ?: 'non-json or failed materializer')
            );
            if ($status === 'failed') {
                $failed++;
            } elseif ($status === 'needs_manual_match') {
                $manual++;
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

            if (attach_candidate_pending_if_available(
                $pdo,
                $item,
                $queueRow,
                $queueIdValue,
                $onlySeriesPort900ImageRepair,
                'candidate_pending: materializer returned ' . $code . ' but safe artwork candidate exists; manual review required before catalog promotion'
            )) {
                $manual++;
                $items[] = $item;
                continue;
            }

            $preferManual = in_array($code, ['TMDB_NO_MATCH', 'SAFE_RESOLUTION_FAILED', 'QUEUE_CONTENT_ID_MISMATCH'], true);
            $status = update_queue_retry_or_failed(
                $pdo,
                $queueRow,
                'http_status=' . $call['http_status'] . ' | code=' . $code . ' | json_error=' . $err,
                $preferManual
            );
            if ($status === 'failed') {
                $failed++;
            } elseif ($status === 'needs_manual_match') {
                $manual++;
            } else {
                $requeued++;
            }
            $item['queue_status'] = $status;
            $items[] = $item;
            continue;
        }

        $imageState = get_current_image_state($pdo, $localSeriesId);
        $verification = requested_images_repaired($requestedImageFields, $imageState);
        $item['image_state_after'] = $imageState;
        $item['requested_image_verification'] = $verification;

        if (!$verification['repaired']) {
            $useUnmatchedPartialCompletion = (
                $onlyUnmatchedLocal
                && clean($queueRow['trigger_reason'] ?? '') === 'unmatched_series_local_row_created'
                && materializer_wrote_useful_metadata($call['json'])
            );

            $useShelfPosterCompletion = (
                $onlySeriesShelfMissing
                && clean($queueRow['trigger_reason'] ?? '') === 'series_shelf_missing_images'
                && series_shelf_has_usable_artwork_or_metadata($imageState, $call['json'])
            );

            $usePort900ReplacementCompletion = (
                $onlySeriesPort900ImageRepair
                && clean($queueRow['trigger_reason'] ?? '') === 'series_port_900_image_repair'
                && series_port_900_has_safe_replacement_artwork($imageState, $call['json'])
            );

            if ($useUnmatchedPartialCompletion || $useShelfPosterCompletion || $usePort900ReplacementCompletion) {
                update_queue_completed($pdo, $queueIdValue);
                $completed++;
                $partialCompleted++;
                $item['queue_status'] = 'completed';

                if ($usePort900ReplacementCompletion) {
                    $item['completion_policy'] = 'partial_port_900_artwork_replaced';
                    $item['completion_note'] = 'Port 900 artwork was treated as replace-only; a safe non-port-900 poster/backdrop replacement was present after materialization, so the row completed even if other requested image fields remain unavailable.';
                } elseif ($useShelfPosterCompletion) {
                    $item['completion_policy'] = 'partial_series_shelf_poster_completed';
                    $item['completion_note'] = 'Series shelf image repair wrote usable poster artwork or useful shelf metadata; completed even though requested backdrop remains unavailable.';
                } else {
                    $item['completion_policy'] = 'partial_unmatched_metadata_completed';
                    $item['completion_note'] = 'TMDb wrote useful metadata but requested images remain missing; completed because only_unmatched_local rows should not retry forever for unavailable backdrop images.';
                }

                $items[] = $item;
                continue;
            }

            if (attach_candidate_pending_if_available(
                $pdo,
                $item,
                $queueRow,
                $queueIdValue,
                $onlySeriesPort900ImageRepair,
                'candidate_pending: materializer did not produce safe replacement artwork but safe artwork candidate exists; manual review required before catalog promotion'
            )) {
                $manual++;
                $items[] = $item;
                continue;
            }

            $preferManualForMissingImages = in_array(clean($queueRow['trigger_reason'] ?? ''), [
                'series_shelf_missing_images',
                'missing_series_images_scan',
                'series_port_900_image_repair',
            ], true);

            $status = update_queue_retry_or_failed(
                $pdo,
                $queueRow,
                'materializer_ok_but_requested_images_still_missing=' . implode(',', $verification['still_missing']),
                $preferManualForMissingImages
            );
            if ($status === 'failed') {
                $failed++;
            } elseif ($status === 'needs_manual_match') {
                $manual++;
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
        'include_preview_missing' => $includePreviewMissing,
        'include_unmatched_local' => $includeUnmatchedLocal,
        'only_unmatched_local' => $onlyUnmatchedLocal,
        'only_series_shelf_missing' => $onlySeriesShelfMissing,
        'only_series_port_900_image_repair' => $onlySeriesPort900ImageRepair,
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
