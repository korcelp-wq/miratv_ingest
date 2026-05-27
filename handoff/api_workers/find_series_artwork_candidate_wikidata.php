<?php
declare(strict_types=1);

/**
 * MiraTV - Find Series Artwork Candidate via Wikidata / Wikimedia Commons
 *
 * Endpoint version:
 *   6B-5G4-2026-05-27-series-wikidata-artwork-candidate-finder
 *
 * Target server path:
 *   /home/xpdgxfsp/public_html/_workers/ai/api/find_series_artwork_candidate_wikidata.php
 *
 * Purpose:
 *   Looks for non-port-900 artwork candidates for a local series row using
 *   Wikidata entity search and Wikimedia Commons file URLs.
 *
 * Safety:
 *   - store=0 is default.
 *   - store=1 inserts candidates into xpdgxfsp_content.content_artwork_candidates.
 *   - Port-900 URLs are rejected.
 *   - Candidate status defaults to pending_review.
 *
 * Examples:
 *   Dry lookup only:
 *     find_series_artwork_candidate_wikidata.php?series_id=7254&queue_id=23&store=0
 *
 *   Lookup and store candidates:
 *     find_series_artwork_candidate_wikidata.php?series_id=7254&queue_id=23&store=1
 */

const ENDPOINT_VERSION = '6B-5G4-2026-05-27-series-wikidata-artwork-candidate-finder';
const DB_CONTENT = 'xpdgxfsp_content';
const DB_IP = 'xpdgxfsp_ip';

header('Content-Type: application/json; charset=utf-8');

function json_out(array $payload, int $status = 200): void
{
    http_response_code($status);
    echo json_encode($payload, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    exit;
}

function clean($value): string
{
    return trim((string)($value ?? ''));
}

function bool_param(string $key, bool $default = false): bool
{
    if (!isset($_GET[$key])) {
        return $default;
    }

    $value = strtolower(clean($_GET[$key]));
    return in_array($value, ['1', 'true', 'yes', 'y', 'on'], true);
}

function int_param(string $key, int $default = 0): int
{
    if (!isset($_GET[$key])) {
        return $default;
    }

    return (int)$_GET[$key];
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

function http_get_json(string $url, int $timeoutSeconds = 12): array
{
    $headers = [
        'Accept: application/json',
        'User-Agent: MiraTVArtworkCandidateFinder/1.0 (https://miratv.club; metadata lookup)',
    ];

    if (function_exists('curl_init')) {
        $ch = curl_init($url);
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_FOLLOWLOCATION => true,
            CURLOPT_CONNECTTIMEOUT => 6,
            CURLOPT_TIMEOUT => $timeoutSeconds,
            CURLOPT_HTTPHEADER => $headers,
        ]);

        $body = curl_exec($ch);
        $err = curl_error($ch);
        $status = (int)curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        curl_close($ch);

        if ($body === false || $body === '') {
            return [
                'ok' => false,
                'http_status' => $status,
                'error' => $err ?: 'empty response',
                'json' => null,
            ];
        }

        $json = json_decode($body, true);

        return [
            'ok' => $status >= 200 && $status < 300 && is_array($json),
            'http_status' => $status,
            'error' => is_array($json) ? null : 'non-json response',
            'json' => is_array($json) ? $json : null,
            'raw_preview' => is_array($json) ? null : substr($body, 0, 300),
        ];
    }

    $context = stream_context_create([
        'http' => [
            'method' => 'GET',
            'timeout' => $timeoutSeconds,
            'header' => implode("\r\n", $headers),
        ],
    ]);

    $body = @file_get_contents($url, false, $context);
    if ($body === false || $body === '') {
        return [
            'ok' => false,
            'http_status' => null,
            'error' => 'file_get_contents failed or empty response',
            'json' => null,
        ];
    }

    $json = json_decode($body, true);
    return [
        'ok' => is_array($json),
        'http_status' => null,
        'error' => is_array($json) ? null : 'non-json response',
        'json' => is_array($json) ? $json : null,
        'raw_preview' => is_array($json) ? null : substr($body, 0, 300),
    ];
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
            cover_url,
            tmdb_cover_url,
            backdrop_url
        FROM " . DB_CONTENT . ".series
        WHERE id = :id
        LIMIT 1
    ");
    $stmt->execute([':id' => $seriesId]);
    $row = $stmt->fetch(PDO::FETCH_ASSOC);
    return $row ?: null;
}

function fetch_queue(PDO $pdo, int $queueId): ?array
{
    if ($queueId <= 0) {
        return null;
    }

    $stmt = $pdo->prepare("
        SELECT *
        FROM " . DB_IP . ".content_materialization_queue
        WHERE id = :id
        LIMIT 1
    ");
    $stmt->execute([':id' => $queueId]);
    $row = $stmt->fetch(PDO::FETCH_ASSOC);
    return $row ?: null;
}

function fetch_availability(PDO $pdo, int $seriesId, ?array $queue): ?array
{
    $provider = clean($queue['provider'] ?? '');
    $providerContentId = clean($queue['provider_content_id'] ?? '');
    $macUserId = (int)($queue['mac_user_id'] ?? 0);

    $where = ['local_series_id = :series_id'];
    $params = [':series_id' => $seriesId];

    if ($provider !== '') {
        $where[] = 'provider = :provider';
        $params[':provider'] = $provider;
    }

    if ($providerContentId !== '') {
        $where[] = 'provider_series_id = :provider_series_id';
        $params[':provider_series_id'] = $providerContentId;
    }

    if ($macUserId > 0) {
        $where[] = 'mac_user_id = :mac_user_id';
        $params[':mac_user_id'] = $macUserId;
    }

    $sql = "
        SELECT *
        FROM " . DB_IP . ".user_series_availability
        WHERE " . implode(' AND ', $where) . "
        ORDER BY last_seen_at DESC
        LIMIT 1
    ";

    try {
        $stmt = $pdo->prepare($sql);
        $stmt->execute($params);
        $row = $stmt->fetch(PDO::FETCH_ASSOC);
        return $row ?: null;
    } catch (Throwable $e) {
        return null;
    }
}

function unique_nonblank(array $values): array
{
    $out = [];
    $seen = [];

    foreach ($values as $value) {
        $value = clean($value);
        if ($value === '') {
            continue;
        }

        $key = mb_strtolower($value, 'UTF-8');
        if (isset($seen[$key])) {
            continue;
        }

        $seen[$key] = true;
        $out[] = $value;
    }

    return $out;
}

function build_search_terms(array $series, ?array $availability): array
{
    $terms = [
        $series['tmdb_search_name'] ?? '',
        $series['clean_search_name'] ?? '',
        $series['name'] ?? '',
    ];

    if ($availability) {
        $terms[] = $availability['provider_series_clean_name'] ?? '';
        $terms[] = $availability['provider_series_name'] ?? '';
    }

    // Clean provider language prefixes for fallback terms.
    $cleaned = [];
    foreach ($terms as $term) {
        $term = clean($term);
        if ($term === '') {
            continue;
        }

        $cleaned[] = $term;
        $cleaned[] = preg_replace('/^\s*[\[\(]?[A-Z]{2,4}[\]\)]?\s*(?:\||-|:|\/)\s*/u', '', $term) ?? $term;
    }

    return unique_nonblank($cleaned);
}

function is_port_900_url(string $url): bool
{
    return (bool)preg_match('/:\s*900\b|:900\//i', $url);
}

function is_safe_candidate_url(string $url): bool
{
    if ($url === '' || !preg_match('#^https?://#i', $url)) {
        return false;
    }

    if (is_port_900_url($url)) {
        return false;
    }

    if (preg_match('/\.(jpg|jpeg|png|webp)(\?.*)?$/i', $url)) {
        return true;
    }

    if (preg_match('#^https?://(commons\.wikimedia\.org|upload\.wikimedia\.org|image\.tmdb\.org|[^/]*miratv\.club)/#i', $url)) {
        return true;
    }

    return false;
}

function wikidata_search_entities(string $term, int $limit = 5): array
{
    $url = 'https://www.wikidata.org/w/api.php?' . http_build_query([
        'action' => 'wbsearchentities',
        'search' => $term,
        'language' => 'en',
        'uselang' => 'en',
        'format' => 'json',
        'limit' => $limit,
    ]);

    $response = http_get_json($url);
    if (!$response['ok']) {
        return [
            'ok' => false,
            'url' => $url,
            'error' => $response['error'],
            'http_status' => $response['http_status'],
            'items' => [],
        ];
    }

    return [
        'ok' => true,
        'url' => $url,
        'items' => $response['json']['search'] ?? [],
    ];
}

function wikidata_get_entities(array $qids): array
{
    $qids = array_values(array_unique(array_filter(array_map('clean', $qids))));
    if (!$qids) {
        return [
            'ok' => true,
            'entities' => [],
        ];
    }

    $url = 'https://www.wikidata.org/w/api.php?' . http_build_query([
        'action' => 'wbgetentities',
        'ids' => implode('|', $qids),
        'props' => 'labels|aliases|descriptions|claims|sitelinks',
        'languages' => 'en|es|tr|fr|de|pt|ar',
        'format' => 'json',
    ]);

    $response = http_get_json($url);
    if (!$response['ok']) {
        return [
            'ok' => false,
            'url' => $url,
            'error' => $response['error'],
            'http_status' => $response['http_status'],
            'entities' => [],
        ];
    }

    return [
        'ok' => true,
        'url' => $url,
        'entities' => $response['json']['entities'] ?? [],
    ];
}

function claim_string_values(array $entity, string $property): array
{
    $claims = $entity['claims'][$property] ?? [];
    $values = [];

    foreach ($claims as $claim) {
        $value = $claim['mainsnak']['datavalue']['value'] ?? null;
        if (is_string($value)) {
            $values[] = $value;
        }
    }

    return unique_nonblank($values);
}

function entity_text_bundle(array $entity): array
{
    $labels = [];
    foreach (($entity['labels'] ?? []) as $lang => $item) {
        $labels[] = clean($item['value'] ?? '');
    }

    $aliases = [];
    foreach (($entity['aliases'] ?? []) as $lang => $items) {
        foreach ($items as $item) {
            $aliases[] = clean($item['value'] ?? '');
        }
    }

    $descriptions = [];
    foreach (($entity['descriptions'] ?? []) as $lang => $item) {
        $descriptions[] = clean($item['value'] ?? '');
    }

    return [
        'labels' => unique_nonblank($labels),
        'aliases' => unique_nonblank($aliases),
        'descriptions' => unique_nonblank($descriptions),
    ];
}

function normalize_for_match(string $value): string
{
    $value = clean($value);
    $value = strtr($value, [
        'á' => 'a', 'é' => 'e', 'í' => 'i', 'ó' => 'o', 'ú' => 'u', 'ñ' => 'n',
        'Á' => 'A', 'É' => 'E', 'Í' => 'I', 'Ó' => 'O', 'Ú' => 'U', 'Ñ' => 'N',
        'ü' => 'u', 'Ü' => 'U', 'ç' => 'c', 'Ç' => 'C',
        'ş' => 's', 'Ş' => 'S', 'ğ' => 'g', 'Ğ' => 'G', 'ı' => 'i', 'İ' => 'I',
        'ö' => 'o', 'Ö' => 'O',
    ]);
    $value = preg_replace('/[^\p{L}\p{N}]+/u', ' ', $value) ?? $value;
    $value = preg_replace('/\s+/u', ' ', $value) ?? $value;
    return mb_strtolower(trim($value), 'UTF-8');
}

function score_entity(array $entity, array $searchTerms): array
{
    $bundle = entity_text_bundle($entity);
    $haystack = array_merge($bundle['labels'], $bundle['aliases']);
    $descriptions = $bundle['descriptions'];

    $bestScore = 0.0;
    $bestReason = 'no title/alias match';

    $normalizedTerms = [];
    foreach ($searchTerms as $term) {
        $normalizedTerms[] = normalize_for_match($term);
    }
    $normalizedTerms = array_values(array_unique(array_filter($normalizedTerms)));

    foreach ($haystack as $candidateText) {
        $normCandidate = normalize_for_match($candidateText);
        if ($normCandidate === '') {
            continue;
        }

        foreach ($normalizedTerms as $normTerm) {
            if ($normTerm === '') {
                continue;
            }

            if ($normCandidate === $normTerm) {
                if ($bestScore < 0.93) {
                    $bestScore = 0.93;
                    $bestReason = 'exact label/alias match';
                }
            } elseif (str_contains($normCandidate, $normTerm) || str_contains($normTerm, $normCandidate)) {
                if ($bestScore < 0.78) {
                    $bestScore = 0.78;
                    $bestReason = 'partial label/alias match';
                }
            }
        }
    }

    $descriptionText = mb_strtolower(implode(' ', $descriptions), 'UTF-8');
    if ($bestScore > 0 && preg_match('/series|television|tv|soap|drama|anime|show|program|telenovela|dizi|مسلسل/u', $descriptionText)) {
        $bestScore = min(0.99, $bestScore + 0.04);
        $bestReason .= ' + series-like description';
    }

    return [
        'score' => round($bestScore, 3),
        'reason' => $bestReason,
        'labels' => $bundle['labels'],
        'aliases' => array_slice($bundle['aliases'], 0, 20),
        'descriptions' => $bundle['descriptions'],
    ];
}

function commons_file_url(string $filename, int $width = 500): ?string
{
    $filename = clean($filename);
    if ($filename === '') {
        return null;
    }

    $title = str_starts_with($filename, 'File:') ? $filename : 'File:' . $filename;

    $url = 'https://commons.wikimedia.org/w/api.php?' . http_build_query([
        'action' => 'query',
        'titles' => $title,
        'prop' => 'imageinfo',
        'iiprop' => 'url|mime|size',
        'iiurlwidth' => $width,
        'format' => 'json',
    ]);

    $response = http_get_json($url);
    if (!$response['ok']) {
        return null;
    }

    $pages = $response['json']['query']['pages'] ?? [];
    foreach ($pages as $page) {
        $info = $page['imageinfo'][0] ?? null;
        if (!$info) {
            continue;
        }

        $thumb = clean($info['thumburl'] ?? '');
        $original = clean($info['url'] ?? '');

        if ($thumb !== '' && is_safe_candidate_url($thumb)) {
            return $thumb;
        }

        if ($original !== '' && is_safe_candidate_url($original)) {
            return $original;
        }
    }

    return null;
}

function entity_candidates(array $entity, array $searchTerms): array
{
    $qid = clean($entity['id'] ?? '');
    $score = score_entity($entity, $searchTerms);
    $out = [];

    // P18 = image
    // P154 = logo image
    // P18 is often best for artwork-like image; P154 can help with logos.
    $properties = [
        'P18' => ['kind' => 'poster', 'label' => 'wikidata_p18_image'],
        'P154' => ['kind' => 'poster', 'label' => 'wikidata_p154_logo'],
    ];

    foreach ($properties as $property => $meta) {
        foreach (claim_string_values($entity, $property) as $filename) {
            $url = commons_file_url($filename, 500);
            if (!$url || !is_safe_candidate_url($url)) {
                continue;
            }

            $confidence = $score['score'];
            if ($property === 'P154') {
                $confidence = max(0.0, $confidence - 0.08);
            }

            $out[] = [
                'qid' => $qid,
                'wikidata_url' => $qid !== '' ? 'https://www.wikidata.org/wiki/' . $qid : null,
                'candidate_url' => $url,
                'candidate_kind' => $meta['kind'],
                'candidate_source' => 'wikidata_commons',
                'candidate_status' => 'pending_review',
                'confidence_score' => round($confidence, 3),
                'reason' => $meta['label'] . ' | ' . $score['reason'],
                'matched_labels' => $score['labels'],
                'matched_aliases' => $score['aliases'],
                'matched_descriptions' => $score['descriptions'],
            ];
        }
    }

    return $out;
}

function existing_candidates(PDO $pdo, int $seriesId, int $queueId): array
{
    $sql = "
        SELECT
            id,
            media_type,
            content_id,
            queue_id,
            candidate_url,
            candidate_kind,
            candidate_source,
            candidate_status,
            confidence_score,
            reason,
            created_at,
            updated_at
        FROM " . DB_CONTENT . ".content_artwork_candidates
        WHERE media_type = 'series'
          AND content_id = :series_id
    ";

    $params = [':series_id' => $seriesId];

    if ($queueId > 0) {
        $sql .= " AND (queue_id = :queue_id OR queue_id IS NULL)";
        $params[':queue_id'] = $queueId;
    }

    $sql .= " ORDER BY id DESC LIMIT 25";

    $stmt = $pdo->prepare($sql);
    $stmt->execute($params);
    return $stmt->fetchAll(PDO::FETCH_ASSOC) ?: [];
}

function candidate_already_exists(PDO $pdo, int $seriesId, string $candidateUrl): ?array
{
    $stmt = $pdo->prepare("
        SELECT *
        FROM " . DB_CONTENT . ".content_artwork_candidates
        WHERE media_type = 'series'
          AND content_id = :series_id
          AND candidate_url = :candidate_url
        LIMIT 1
    ");
    $stmt->execute([
        ':series_id' => $seriesId,
        ':candidate_url' => $candidateUrl,
    ]);
    $row = $stmt->fetch(PDO::FETCH_ASSOC);
    return $row ?: null;
}

function insert_candidate(PDO $pdo, array $series, ?array $queue, array $candidate): array
{
    $seriesId = (int)$series['id'];
    $queueId = $queue ? (int)$queue['id'] : null;
    $provider = $queue ? clean($queue['provider'] ?? '') : null;
    $providerContentId = $queue ? clean($queue['provider_content_id'] ?? '') : clean($series['provider_series_id'] ?? '');
    $candidateUrl = clean($candidate['candidate_url'] ?? '');

    $existing = candidate_already_exists($pdo, $seriesId, $candidateUrl);
    if ($existing) {
        return [
            'id' => (int)$existing['id'],
            'action' => 'existing',
            'candidate_url' => $candidateUrl,
        ];
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
        ':content_id' => $seriesId,
        ':provider' => $provider,
        ':provider_content_id' => $providerContentId,
        ':queue_id' => $queueId,
        ':title' => clean($series['tmdb_search_name'] ?? '') ?: clean($series['clean_search_name'] ?? '') ?: clean($series['name'] ?? ''),
        ':clean_search_name' => clean($series['clean_search_name'] ?? ''),
        ':candidate_url' => $candidateUrl,
        ':candidate_kind' => clean($candidate['candidate_kind'] ?? 'poster'),
        ':candidate_source' => clean($candidate['candidate_source'] ?? 'wikidata_commons'),
        ':candidate_status' => clean($candidate['candidate_status'] ?? 'pending_review'),
        ':confidence_score' => $candidate['confidence_score'] ?? null,
        ':reason' => clean($candidate['reason'] ?? 'wikidata_commons_candidate'),
    ]);

    return [
        'id' => (int)$pdo->lastInsertId(),
        'action' => 'inserted',
        'candidate_url' => $candidateUrl,
    ];
}

try {
    $seriesId = int_param('series_id', 0);
    $queueId = int_param('queue_id', 0);
    $store = bool_param('store', false);
    $limit = max(1, min(10, int_param('limit', 5)));

    $pdo = open_pdo();

    $queue = fetch_queue($pdo, $queueId);
    if ($seriesId <= 0 && $queue) {
        $seriesId = (int)$queue['content_id'];
    }

    if ($seriesId <= 0) {
        json_out([
            'ok' => false,
            'endpoint_version' => ENDPOINT_VERSION,
            'error' => 'Missing series_id or valid queue_id',
        ], 400);
    }

    $series = fetch_series($pdo, $seriesId);
    if (!$series) {
        json_out([
            'ok' => false,
            'endpoint_version' => ENDPOINT_VERSION,
            'error' => 'Series row not found',
            'series_id' => $seriesId,
        ], 404);
    }

    $availability = fetch_availability($pdo, $seriesId, $queue);
    $searchTerms = build_search_terms($series, $availability);

    $searchResults = [];
    $qids = [];

    foreach (array_slice($searchTerms, 0, 4) as $term) {
        $result = wikidata_search_entities($term, $limit);
        $searchResults[] = [
            'term' => $term,
            'ok' => $result['ok'],
            'http_status' => $result['http_status'] ?? null,
            'error' => $result['error'] ?? null,
            'count' => count($result['items'] ?? []),
            'items' => array_map(static function ($item): array {
                return [
                    'id' => clean($item['id'] ?? ''),
                    'label' => clean($item['label'] ?? ''),
                    'description' => clean($item['description'] ?? ''),
                    'concepturi' => clean($item['concepturi'] ?? ''),
                ];
            }, $result['items'] ?? []),
        ];

        foreach ($result['items'] ?? [] as $item) {
            $qid = clean($item['id'] ?? '');
            if ($qid !== '') {
                $qids[] = $qid;
            }
        }
    }

    $entityResponse = wikidata_get_entities($qids);
    $wikidataCandidates = [];

    foreach ($entityResponse['entities'] ?? [] as $qid => $entity) {
        if (!is_array($entity) || isset($entity['missing'])) {
            continue;
        }

        foreach (entity_candidates($entity, $searchTerms) as $candidate) {
            if (($candidate['confidence_score'] ?? 0) <= 0) {
                continue;
            }

            $wikidataCandidates[] = $candidate;
        }
    }

    // Deduplicate candidate URLs.
    $deduped = [];
    $seen = [];
    foreach ($wikidataCandidates as $candidate) {
        $url = clean($candidate['candidate_url'] ?? '');
        if ($url === '' || isset($seen[$url])) {
            continue;
        }
        $seen[$url] = true;
        $deduped[] = $candidate;
    }

    usort($deduped, static function (array $a, array $b): int {
        return ($b['confidence_score'] <=> $a['confidence_score']);
    });

    $stored = [];
    if ($store) {
        foreach ($deduped as $candidate) {
            $stored[] = insert_candidate($pdo, $series, $queue, $candidate);
        }
    }

    json_out([
        'ok' => true,
        'endpoint_version' => ENDPOINT_VERSION,
        'series_id' => $seriesId,
        'queue_id' => $queueId > 0 ? $queueId : null,
        'store_requested' => $store,
        'series' => [
            'id' => (int)$series['id'],
            'provider_series_id' => $series['provider_series_id'] ?? null,
            'name' => clean($series['name'] ?? ''),
            'clean_search_name' => clean($series['clean_search_name'] ?? ''),
            'tmdb_search_name' => clean($series['tmdb_search_name'] ?? ''),
            'poster_url' => clean($series['poster_url'] ?? ''),
            'cover_url' => clean($series['cover_url'] ?? ''),
            'tmdb_cover_url' => clean($series['tmdb_cover_url'] ?? ''),
            'backdrop_url' => clean($series['backdrop_url'] ?? ''),
        ],
        'queue' => $queue ? [
            'id' => (int)$queue['id'],
            'content_id' => (int)$queue['content_id'],
            'provider' => clean($queue['provider'] ?? ''),
            'provider_content_id' => clean($queue['provider_content_id'] ?? ''),
            'mac_user_id' => (int)($queue['mac_user_id'] ?? 0),
            'trigger_reason' => clean($queue['trigger_reason'] ?? ''),
            'missing_fields' => clean($queue['missing_fields'] ?? ''),
            'status' => clean($queue['status'] ?? ''),
        ] : null,
        'availability' => $availability,
        'existing_candidates' => existing_candidates($pdo, $seriesId, $queueId),
        'search_terms' => $searchTerms,
        'wikidata_search_results' => $searchResults,
        'wikidata_entity_lookup_ok' => $entityResponse['ok'] ?? false,
        'wikidata_candidates' => $deduped,
        'stored_candidates' => $stored,
        'note' => $deduped
            ? 'Wikidata/Commons candidates found. Review before applying.'
            : 'No Wikidata/Commons image candidates found. Try manual candidate upload or alternate title/alias.',
    ]);
} catch (Throwable $e) {
    json_out([
        'ok' => false,
        'endpoint_version' => ENDPOINT_VERSION,
        'error' => $e->getMessage(),
    ], 500);
}
