<?php
declare(strict_types=1);

/**
 * MiraTV - Upsert Series Artwork Candidate
 *
 * Endpoint version:
 *   6B-5G1-2026-05-27-series-artwork-candidate-upsert
 *
 * Purpose:
 *   Stores manual/Google/TMDb-fallback artwork candidates without overwriting
 *   xpdgxfsp_content.series poster/backdrop columns.
 *
 * Target server path:
 *   /home/xpdgxfsp/public_html/_workers/ai/api/upsert_series_artwork_candidate.php
 *
 * Required input:
 *   series_id
 *   candidate_url
 *
 * Optional input:
 *   queue_id
 *   provider
 *   provider_series_id / provider_content_id
 *   title
 *   clean_search_name
 *   candidate_kind = poster | backdrop | unknown
 *   candidate_source = google | manual | tmdb_fallback | other
 *   candidate_status = pending_review | accepted | rejected
 *   confidence_score
 *   reason
 *
 * Safety:
 *   - Rejects port-900 artwork URLs.
 *   - Rejects non-http/non-https URLs.
 *   - Does not update main catalog artwork fields.
 */

const ENDPOINT_VERSION = '6B-5G1-2026-05-27-series-artwork-candidate-upsert';
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

function normalize_candidate_kind(string $kind): string
{
    $kind = strtolower(clean($kind));
    if (in_array($kind, ['poster', 'backdrop', 'unknown'], true)) {
        return $kind;
    }
    return 'unknown';
}

function normalize_candidate_source(string $source): string
{
    $source = strtolower(clean($source));
    if ($source === '') {
        return 'manual';
    }

    $allowed = ['google', 'manual', 'tmdb_fallback', 'provider_safe', 'other'];
    if (in_array($source, $allowed, true)) {
        return $source;
    }

    return 'other';
}

function normalize_candidate_status(string $status): string
{
    $status = strtolower(clean($status));
    if (in_array($status, ['pending_review', 'accepted', 'rejected'], true)) {
        return $status;
    }
    return 'pending_review';
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

function is_valid_candidate_url(string $url): bool
{
    $url = clean($url);
    if ($url === '') {
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

function find_existing_candidate(PDO $pdo, int $seriesId, string $url, string $kind, string $source): ?array
{
    $stmt = $pdo->prepare("
        SELECT *
        FROM " . DB_CONTENT . ".content_artwork_candidates
        WHERE media_type = 'series'
          AND content_id = :content_id
          AND candidate_url = :candidate_url
          AND candidate_kind = :candidate_kind
          AND candidate_source = :candidate_source
        ORDER BY id DESC
        LIMIT 1
    ");
    $stmt->execute([
        ':content_id' => $seriesId,
        ':candidate_url' => $url,
        ':candidate_kind' => $kind,
        ':candidate_source' => $source,
    ]);

    $row = $stmt->fetch(PDO::FETCH_ASSOC);
    return is_array($row) ? $row : null;
}

function upsert_candidate(PDO $pdo, array $data): array
{
    $existing = find_existing_candidate(
        $pdo,
        (int)$data['content_id'],
        (string)$data['candidate_url'],
        (string)$data['candidate_kind'],
        (string)$data['candidate_source']
    );

    if ($existing) {
        $stmt = $pdo->prepare("
            UPDATE " . DB_CONTENT . ".content_artwork_candidates
            SET
                provider = :provider,
                provider_content_id = :provider_content_id,
                queue_id = :queue_id,
                title = :title,
                clean_search_name = :clean_search_name,
                candidate_status = :candidate_status,
                confidence_score = :confidence_score,
                reason = :reason,
                updated_at = NOW()
            WHERE id = :id
        ");
        $stmt->execute([
            ':provider' => $data['provider'],
            ':provider_content_id' => $data['provider_content_id'],
            ':queue_id' => $data['queue_id'],
            ':title' => $data['title'],
            ':clean_search_name' => $data['clean_search_name'],
            ':candidate_status' => $data['candidate_status'],
            ':confidence_score' => $data['confidence_score'],
            ':reason' => $data['reason'],
            ':id' => $existing['id'],
        ]);

        $data['id'] = (int)$existing['id'];
        $data['action'] = 'updated_existing';
        return $data;
    }

    $stmt = $pdo->prepare("
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
            :candidate_status,
            :confidence_score,
            :reason,
            NOW(),
            NOW()
        )
    ");
    $stmt->execute([
        ':content_id' => $data['content_id'],
        ':provider' => $data['provider'],
        ':provider_content_id' => $data['provider_content_id'],
        ':queue_id' => $data['queue_id'],
        ':title' => $data['title'],
        ':clean_search_name' => $data['clean_search_name'],
        ':candidate_url' => $data['candidate_url'],
        ':candidate_kind' => $data['candidate_kind'],
        ':candidate_source' => $data['candidate_source'],
        ':candidate_status' => $data['candidate_status'],
        ':confidence_score' => $data['confidence_score'],
        ':reason' => $data['reason'],
    ]);

    $data['id'] = (int)$pdo->lastInsertId();
    $data['action'] = 'inserted';
    return $data;
}

try {
    $input = read_request_input();

    $seriesId = (int)($input['series_id'] ?? $input['content_id'] ?? 0);
    $queueId = isset($input['queue_id']) && clean($input['queue_id']) !== '' ? (int)$input['queue_id'] : null;

    $candidateUrl = clean($input['candidate_url'] ?? '');
    $candidateKind = normalize_candidate_kind((string)($input['candidate_kind'] ?? 'unknown'));
    $candidateSource = normalize_candidate_source((string)($input['candidate_source'] ?? 'manual'));
    $candidateStatus = normalize_candidate_status((string)($input['candidate_status'] ?? 'pending_review'));
    $reason = first_non_blank($input['reason'] ?? null, 'port_900_replacement');

    if ($seriesId <= 0) {
        json_out([
            'ok' => false,
            'endpoint_version' => ENDPOINT_VERSION,
            'error' => 'Missing or invalid series_id',
        ], 400);
    }

    if (!is_valid_candidate_url($candidateUrl)) {
        json_out([
            'ok' => false,
            'endpoint_version' => ENDPOINT_VERSION,
            'error' => 'Missing, invalid, or unsafe candidate_url. Port-900 URLs are not accepted as candidates.',
            'candidate_url' => $candidateUrl,
        ], 400);
    }

    $confidenceRaw = clean($input['confidence_score'] ?? '');
    $confidence = $confidenceRaw === '' ? null : max(0.0, min(100.0, (float)$confidenceRaw));

    $pdo = open_pdo();

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

    $provider = first_non_blank(
        $input['provider'] ?? null,
        $queue['provider'] ?? null
    );

    $providerContentId = first_non_blank(
        $input['provider_series_id'] ?? null,
        $input['provider_content_id'] ?? null,
        $queue['provider_content_id'] ?? null,
        $series['provider_series_id'] ?? null
    );

    $title = first_non_blank(
        $input['title'] ?? null,
        $series['tmdb_search_name'] ?? null,
        $series['clean_search_name'] ?? null,
        $series['name'] ?? null
    );

    $cleanSearchName = first_non_blank(
        $input['clean_search_name'] ?? null,
        $series['clean_search_name'] ?? null,
        $series['tmdb_search_name'] ?? null,
        $series['name'] ?? null
    );

    $data = [
        'content_id' => $seriesId,
        'provider' => $provider,
        'provider_content_id' => $providerContentId,
        'queue_id' => $queueId,
        'title' => $title,
        'clean_search_name' => $cleanSearchName,
        'candidate_url' => $candidateUrl,
        'candidate_kind' => $candidateKind,
        'candidate_source' => $candidateSource,
        'candidate_status' => $candidateStatus,
        'confidence_score' => $confidence,
        'reason' => $reason,
    ];

    $saved = upsert_candidate($pdo, $data);

    json_out([
        'ok' => true,
        'endpoint_version' => ENDPOINT_VERSION,
        'saved' => $saved,
        'series' => [
            'id' => (int)$series['id'],
            'name' => $series['name'] ?? null,
            'clean_search_name' => $series['clean_search_name'] ?? null,
            'tmdb_search_name' => $series['tmdb_search_name'] ?? null,
        ],
        'queue' => $queue,
    ]);
} catch (Throwable $e) {
    json_out([
        'ok' => false,
        'endpoint_version' => ENDPOINT_VERSION,
        'error' => $e->getMessage(),
    ], 500);
}
