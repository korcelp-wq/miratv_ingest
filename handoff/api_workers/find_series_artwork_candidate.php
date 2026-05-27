<?php
declare(strict_types=1);

/**
 * MiraTV - Find Series Artwork Candidate
 *
 * Endpoint version:
 *   6B-5G1-2026-05-27-series-artwork-candidate-finder
 *
 * Purpose:
 *   Looks up existing artwork candidates and, when configured, can query
 *   Google Custom Search for image candidates. If Google is not configured,
 *   it returns safe Google/manual search queries for controlled review.
 *
 * Target server path:
 *   /home/xpdgxfsp/public_html/_workers/ai/api/find_series_artwork_candidate.php
 *
 * Required input:
 *   series_id
 *
 * Optional input:
 *   queue_id
 *   store=1                      Store discovered Google candidates as pending_review.
 *   google=1                     Attempt Google Custom Search if config exists.
 *   candidate_kind=poster|backdrop|unknown
 *   limit=1..10
 *
 * Safety:
 *   - Does not overwrite xpdgxfsp_content.series artwork fields.
 *   - Rejects/stops port-900 URLs as candidates.
 *   - Stores only pending_review candidates unless explicitly accepted later.
 */

const ENDPOINT_VERSION = '6B-5G1-2026-05-27-series-artwork-candidate-finder';
const DB_CONTENT = 'xpdgxfsp_content';
const DB_IP = 'xpdgxfsp_ip';

header('Content-Type: application/json; charset=utf-8');

function json_out(array $payload, int $status = 200): void
{
    http_response_code($status);
    echo json_encode($payload, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
    exit;
}

function clean($value): string
{
    if ($value === null) {
        return '';
    }
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

function read_request_input(): array
{
    $input = $_GET + $_POST;

    $raw = file_get_contents('php://input');
    if (is_string($raw) && trim($raw) !== '') {
        $json = json_decode($raw, true);
        if (is_array($json)) {
            $input = $json + $input;
        }
    }

    return $input;
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

function load_config(): array
{
    $configFile = find_config_file('db.php');
    if (!$configFile) {
        throw new RuntimeException('Unable to locate db.php config file');
    }

    $config = require $configFile;
    if (!is_array($config)) {
        throw new RuntimeException('db.php did not return an array config');
    }

    return $config;
}

function open_pdo(array $config): PDO
{
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
    return is_array($parts) && isset($parts['port']) && (int)$parts['port'] === 900;
}

function is_candidate_url_safe(?string $url): bool
{
    $url = first_non_blank($url);
    if ($url === null) {
        return false;
    }

    if (!preg_match('#^https?://#i', $url)) {
        return false;
    }

    if (is_port_900_artwork_url($url)) {
        return false;
    }

    return true;
}

function normalize_candidate_kind(string $kind): string
{
    $kind = strtolower(clean($kind));
    if (in_array($kind, ['poster', 'backdrop', 'unknown'], true)) {
        return $kind;
    }
    return 'unknown';
}

function strip_provider_title_junk(string $title): string
{
    $title = preg_replace('/^\s*[A-Z]{2}\s*\|\s*/i', '', $title) ?? $title;
    $title = preg_replace('/\[(MULTI[-\s]?SUB|MULTISUB|SUBS?|SUB|DUAL AUDIO|4K|FHD|HD|SD)\]/i', '', $title) ?? $title;
    $title = preg_replace('/\s+/', ' ', $title) ?? $title;
    return trim($title);
}

function fetch_series(PDO $pdo, int $seriesId): ?array
{
    $stmt = $pdo->prepare("
        SELECT
            id,
            provider_series_id,
            name,
            clean_search_name,
            tmdb_search_name,
            poster_url,
            backdrop_url
        FROM " . DB_CONTENT . ".series
        WHERE id = :id
        LIMIT 1
    ");
    $stmt->execute([':id' => $seriesId]);
    $row = $stmt->fetch(PDO::FETCH_ASSOC);
    return is_array($row) ? $row : null;
}

function fetch_queue(PDO $pdo, ?int $queueId): ?array
{
    if ($queueId === null || $queueId <= 0) {
        return null;
    }

    $stmt = $pdo->prepare("
        SELECT
            id,
            content_id,
            provider,
            provider_content_id,
            mac_user_id,
            trigger_reason,
            missing_fields,
            status
        FROM " . DB_IP . ".content_materialization_queue
        WHERE id = :id
        LIMIT 1
    ");
    $stmt->execute([':id' => $queueId]);
    $row = $stmt->fetch(PDO::FETCH_ASSOC);
    return is_array($row) ? $row : null;
}

function fetch_availability(PDO $pdo, ?int $macUserId, ?string $provider, ?string $providerSeriesId, int $seriesId): ?array
{
    if (!$macUserId && !$providerSeriesId) {
        return null;
    }

    $where = [];
    $params = [];

    if ($macUserId && $macUserId > 0) {
        $where[] = 'mac_user_id = :mac_user_id';
        $params[':mac_user_id'] = $macUserId;
    }

    if ($provider !== null && $provider !== '') {
        $where[] = 'provider = :provider';
        $params[':provider'] = $provider;
    }

    if ($providerSeriesId !== null && $providerSeriesId !== '') {
        $where[] = 'provider_series_id = :provider_series_id';
        $params[':provider_series_id'] = $providerSeriesId;
    } else {
        $where[] = 'local_series_id = :local_series_id';
        $params[':local_series_id'] = $seriesId;
    }

    $sql = "
        SELECT
            mac_user_id,
            provider,
            provider_series_id,
            provider_series_name,
            provider_series_clean_name,
            local_series_id,
            provider_category_id,
            provider_category_name
        FROM " . DB_IP . ".user_series_availability
        WHERE " . implode(' AND ', $where) . "
        ORDER BY last_seen_at DESC, id DESC
        LIMIT 1
    ";

    $stmt = $pdo->prepare($sql);
    $stmt->execute($params);
    $row = $stmt->fetch(PDO::FETCH_ASSOC);
    return is_array($row) ? $row : null;
}

function fetch_existing_candidates(PDO $pdo, int $seriesId, int $limit): array
{
    $stmt = $pdo->prepare("
        SELECT *
        FROM " . DB_CONTENT . ".content_artwork_candidates
        WHERE media_type = 'series'
          AND content_id = :content_id
        ORDER BY
            FIELD(candidate_status, 'accepted', 'pending_review', 'rejected'),
            confidence_score DESC,
            updated_at DESC,
            id DESC
        LIMIT " . (int)$limit . "
    ");
    $stmt->execute([':content_id' => $seriesId]);
    return $stmt->fetchAll(PDO::FETCH_ASSOC) ?: [];
}

function build_search_terms(array $series, ?array $availability): array
{
    $baseTitle = first_non_blank(
        $series['tmdb_search_name'] ?? null,
        $series['clean_search_name'] ?? null,
        $availability['provider_series_clean_name'] ?? null,
        $series['name'] ?? null,
        $availability['provider_series_name'] ?? null
    );

    $cleanTitle = strip_provider_title_junk((string)$baseTitle);
    $providerClean = $availability ? strip_provider_title_junk((string)($availability['provider_series_clean_name'] ?? '')) : '';
    $providerRawClean = $availability ? strip_provider_title_junk((string)($availability['provider_series_name'] ?? '')) : '';

    $terms = [];
    foreach ([$cleanTitle, $providerClean, $providerRawClean] as $term) {
        $term = clean($term);
        if ($term !== '' && !in_array($term, $terms, true)) {
            $terms[] = $term;
        }
    }

    return $terms;
}

function build_google_queries(array $terms, string $kind): array
{
    $queries = [];

    foreach ($terms as $term) {
        if ($kind === 'backdrop') {
            $queries[] = $term . ' TV series backdrop';
            $queries[] = $term . ' TV series still';
        } elseif ($kind === 'poster') {
            $queries[] = $term . ' TV series poster';
            $queries[] = $term . ' series poster TMDb';
        } else {
            $queries[] = $term . ' TV series poster';
            $queries[] = $term . ' TV series backdrop';
        }
    }

    return array_values(array_unique($queries));
}

function extract_google_config(array $config): ?array
{
    $candidates = [
        $config['google_custom_search'] ?? null,
        $config['google_cse'] ?? null,
        $config['google']['custom_search'] ?? null,
        $config['google'] ?? null,
    ];

    foreach ($candidates as $candidate) {
        if (!is_array($candidate)) {
            continue;
        }

        $apiKey = first_non_blank($candidate['api_key'] ?? null, $candidate['key'] ?? null);
        $cx = first_non_blank($candidate['cx'] ?? null, $candidate['search_engine_id'] ?? null, $candidate['cse_id'] ?? null);

        if ($apiKey && $cx) {
            return [
                'api_key' => $apiKey,
                'cx' => $cx,
            ];
        }
    }

    return null;
}

function http_get_json(string $url, int $timeoutSeconds = 15): array
{
    $context = stream_context_create([
        'http' => [
            'method' => 'GET',
            'timeout' => $timeoutSeconds,
            'ignore_errors' => true,
            'header' => "Accept: application/json\r\nUser-Agent: MiraTV-ArtworkCandidateFinder/1.0\r\n",
        ],
    ]);

    $body = @file_get_contents($url, false, $context);
    $status = 0;

    if (isset($http_response_header) && is_array($http_response_header)) {
        foreach ($http_response_header as $header) {
            if (preg_match('#^HTTP/\S+\s+(\d+)#', $header, $m)) {
                $status = (int)$m[1];
                break;
            }
        }
    }

    $json = is_string($body) ? json_decode($body, true) : null;

    return [
        'status' => $status,
        'body' => $body,
        'json' => is_array($json) ? $json : null,
    ];
}

function google_image_candidates(array $googleConfig, array $queries, int $limit): array
{
    $candidates = [];

    foreach ($queries as $query) {
        if (count($candidates) >= $limit) {
            break;
        }

        $params = [
            'key' => $googleConfig['api_key'],
            'cx' => $googleConfig['cx'],
            'q' => $query,
            'searchType' => 'image',
            'num' => min(10, max(1, $limit)),
            'safe' => 'active',
        ];

        $url = 'https://www.googleapis.com/customsearch/v1?' . http_build_query($params);
        $response = http_get_json($url);

        $items = $response['json']['items'] ?? [];
        if (!is_array($items)) {
            continue;
        }

        foreach ($items as $item) {
            if (count($candidates) >= $limit) {
                break 2;
            }

            $link = first_non_blank($item['link'] ?? null);
            if (!$link || !is_candidate_url_safe($link)) {
                continue;
            }

            $candidates[] = [
                'candidate_url' => $link,
                'candidate_source' => 'google',
                'candidate_kind' => 'unknown',
                'candidate_status' => 'pending_review',
                'confidence_score' => 50.0,
                'title' => $item['title'] ?? null,
                'display_link' => $item['displayLink'] ?? null,
                'query' => $query,
            ];
        }
    }

    return $candidates;
}

function upsert_candidate(PDO $pdo, array $candidate, array $context): array
{
    $stmt = $pdo->prepare("
        SELECT id
        FROM " . DB_CONTENT . ".content_artwork_candidates
        WHERE media_type = 'series'
          AND content_id = :content_id
          AND candidate_url = :candidate_url
        ORDER BY id DESC
        LIMIT 1
    ");
    $stmt->execute([
        ':content_id' => $context['series_id'],
        ':candidate_url' => $candidate['candidate_url'],
    ]);
    $existing = $stmt->fetch(PDO::FETCH_ASSOC);

    if (is_array($existing)) {
        $update = $pdo->prepare("
            UPDATE " . DB_CONTENT . ".content_artwork_candidates
            SET
                queue_id = :queue_id,
                provider = :provider,
                provider_content_id = :provider_content_id,
                title = :title,
                clean_search_name = :clean_search_name,
                candidate_source = :candidate_source,
                candidate_kind = :candidate_kind,
                candidate_status = 'pending_review',
                confidence_score = :confidence_score,
                reason = :reason,
                updated_at = NOW()
            WHERE id = :id
        ");
        $update->execute([
            ':queue_id' => $context['queue_id'],
            ':provider' => $context['provider'],
            ':provider_content_id' => $context['provider_content_id'],
            ':title' => $context['title'],
            ':clean_search_name' => $context['clean_search_name'],
            ':candidate_source' => $candidate['candidate_source'],
            ':candidate_kind' => $candidate['candidate_kind'],
            ':confidence_score' => $candidate['confidence_score'],
            ':reason' => $context['reason'],
            ':id' => $existing['id'],
        ]);

        $candidate['id'] = (int)$existing['id'];
        $candidate['action'] = 'updated_existing';
        return $candidate;
    }

    $insert = $pdo->prepare("
        INSERT INTO " . DB_CONTENT . ".content_artwork_candidates
        (
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
        )
        VALUES
        (
            'series',
            :content_id,
            :provider,
            :provider_content_id,
            :queue_id,
            :title,
            :clean_search_name,
            :candidate_url,
            :candidate_kind,
            :candidate_source,
            'pending_review',
            :confidence_score,
            :reason,
            NOW(),
            NOW()
        )
    ");
    $insert->execute([
        ':content_id' => $context['series_id'],
        ':provider' => $context['provider'],
        ':provider_content_id' => $context['provider_content_id'],
        ':queue_id' => $context['queue_id'],
        ':title' => $context['title'],
        ':clean_search_name' => $context['clean_search_name'],
        ':candidate_url' => $candidate['candidate_url'],
        ':candidate_kind' => $candidate['candidate_kind'],
        ':candidate_source' => $candidate['candidate_source'],
        ':confidence_score' => $candidate['confidence_score'],
        ':reason' => $context['reason'],
    ]);

    $candidate['id'] = (int)$pdo->lastInsertId();
    $candidate['action'] = 'inserted';
    return $candidate;
}

try {
    $input = read_request_input();

    $seriesId = (int)($input['series_id'] ?? $input['content_id'] ?? 0);
    $queueId = isset($input['queue_id']) && clean($input['queue_id']) !== '' ? (int)$input['queue_id'] : null;
    $limit = max(1, min(10, (int)($input['limit'] ?? 5)));
    $store = (int)($input['store'] ?? 0) === 1;
    $useGoogle = (int)($input['google'] ?? 0) === 1;
    $candidateKind = normalize_candidate_kind((string)($input['candidate_kind'] ?? 'unknown'));

    if ($seriesId <= 0) {
        json_out([
            'ok' => false,
            'endpoint_version' => ENDPOINT_VERSION,
            'error' => 'Missing or invalid series_id',
        ], 400);
    }

    $config = load_config();
    $pdo = open_pdo($config);

    $series = fetch_series($pdo, $seriesId);
    if (!$series) {
        json_out([
            'ok' => false,
            'endpoint_version' => ENDPOINT_VERSION,
            'error' => 'Series not found',
            'series_id' => $seriesId,
        ], 404);
    }

    $queue = fetch_queue($pdo, $queueId);
    $provider = first_non_blank($input['provider'] ?? null, $queue['provider'] ?? null);
    $providerContentId = first_non_blank(
        $input['provider_series_id'] ?? null,
        $input['provider_content_id'] ?? null,
        $queue['provider_content_id'] ?? null,
        $series['provider_series_id'] ?? null
    );

    $macUserId = isset($queue['mac_user_id']) ? (int)$queue['mac_user_id'] : null;
    $availability = fetch_availability($pdo, $macUserId, $provider, $providerContentId, $seriesId);

    $terms = build_search_terms($series, $availability);
    $queries = build_google_queries($terms, $candidateKind);
    $existing = fetch_existing_candidates($pdo, $seriesId, $limit);

    $googleConfig = extract_google_config($config);
    $googleCandidates = [];
    $stored = [];

    if ($useGoogle && $googleConfig) {
        $googleCandidates = google_image_candidates($googleConfig, $queries, $limit);

        if ($store) {
            $context = [
                'series_id' => $seriesId,
                'queue_id' => $queueId,
                'provider' => $provider,
                'provider_content_id' => $providerContentId,
                'title' => first_non_blank($series['tmdb_search_name'] ?? null, $series['clean_search_name'] ?? null, $series['name'] ?? null),
                'clean_search_name' => first_non_blank($series['clean_search_name'] ?? null, $series['tmdb_search_name'] ?? null, $series['name'] ?? null),
                'reason' => first_non_blank($input['reason'] ?? null, 'google_candidate_for_port_900_replacement'),
            ];

            foreach ($googleCandidates as $candidate) {
                $candidate['candidate_kind'] = $candidateKind;
                $stored[] = upsert_candidate($pdo, $candidate, $context);
            }
        }
    }

    json_out([
        'ok' => true,
        'endpoint_version' => ENDPOINT_VERSION,
        'series_id' => $seriesId,
        'queue_id' => $queueId,
        'google_configured' => $googleConfig !== null,
        'google_requested' => $useGoogle,
        'store_requested' => $store,
        'series' => $series,
        'queue' => $queue,
        'availability' => $availability,
        'existing_candidates' => $existing,
        'search_terms' => $terms,
        'suggested_google_queries' => $queries,
        'google_candidates' => $googleCandidates,
        'stored_candidates' => $stored,
        'note' => $googleConfig ? 'Google Custom Search is configured.' : 'Google Custom Search is not configured; use suggested_google_queries for manual lookup or add google_custom_search config.',
    ]);
} catch (Throwable $e) {
    json_out([
        'ok' => false,
        'endpoint_version' => ENDPOINT_VERSION,
        'error' => $e->getMessage(),
    ], 500);
}
