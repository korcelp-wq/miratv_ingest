<?php
declare(strict_types=1);

/**
 * MiraTV - Apply Series Artwork Candidate
 *
 * Endpoint version:
 *   6B-5G5-2026-05-27-applied-candidate-queue-completion
 *
 * Target server path:
 *   /home/xpdgxfsp/public_html/_workers/ai/api/apply_series_artwork_candidate.php
 *
 * Purpose:
 *   Promotes a reviewed/manual artwork candidate into the series catalog and updates
 *   the materialization queue state.
 *
 * Safety:
 *   - dry_run=1 is default unless apply=1 is passed.
 *   - apply=1 is required to write and implies dry_run=0 unless dry_run=1 is explicitly passed.
 *   - Port-900 candidate URLs are rejected.
 *   - Pending candidates are allowed only when accept_pending=1.
 *   - complete_if_poster_present=1 can complete series_port_900_image_repair rows once poster/cover art exists.
 *   - Already-applied candidates can still update queue completion when complete_if_poster_present=1.
 */

const ENDPOINT_VERSION = '6B-5G5-2026-05-27-applied-candidate-queue-completion';
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

function table_columns(PDO $pdo, string $db, string $table): array
{
    $stmt = $pdo->prepare("\n        SELECT COLUMN_NAME\n        FROM information_schema.COLUMNS\n        WHERE TABLE_SCHEMA = :db\n          AND TABLE_NAME = :table\n    ");
    $stmt->execute([
        ':db' => $db,
        ':table' => $table,
    ]);

    $cols = [];
    foreach ($stmt->fetchAll(PDO::FETCH_ASSOC) as $row) {
        $cols[strtolower((string)$row['COLUMN_NAME'])] = (string)$row['COLUMN_NAME'];
    }

    return $cols;
}

function has_col(array $cols, string $name): bool
{
    return isset($cols[strtolower($name)]);
}

function col_name(array $cols, string $name): string
{
    $key = strtolower($name);
    if (!isset($cols[$key])) {
        throw new RuntimeException('Missing expected column: ' . $name);
    }
    return $cols[$key];
}

function is_port_900_url(string $url): bool
{
    return (bool)preg_match('/:900\//i', $url);
}

function is_safe_candidate_url(string $url): bool
{
    if ($url === '') {
        return false;
    }

    if (!preg_match('#^https?://#i', $url)) {
        return false;
    }

    if (is_port_900_url($url)) {
        return false;
    }

    if (preg_match('/\.(jpg|jpeg|png|webp)(\?.*)?$/i', $url)) {
        return true;
    }

    if (preg_match('#^https?://(image\.tmdb\.org|m\.media-amazon\.com|[^/]*wikimedia\.org|[^/]*miratv\.club)/#i', $url)) {
        return true;
    }

    return false;
}

function fetch_candidate(PDO $pdo, int $candidateId, int $queueId, int $seriesId, string $candidateKind): ?array
{
    if ($candidateId > 0) {
        $stmt = $pdo->prepare("\n            SELECT *\n            FROM " . DB_CONTENT . ".content_artwork_candidates\n            WHERE id = :id\n              AND media_type = 'series'\n            LIMIT 1\n        ");
        $stmt->execute([':id' => $candidateId]);
        $row = $stmt->fetch(PDO::FETCH_ASSOC);
        return $row ?: null;
    }

    $where = ["media_type = 'series'"];
    $params = [];

    if ($queueId > 0) {
        $where[] = 'queue_id = :queue_id';
        $params[':queue_id'] = $queueId;
    }

    if ($seriesId > 0) {
        $where[] = 'content_id = :series_id';
        $params[':series_id'] = $seriesId;
    }

    if ($candidateKind !== '') {
        $where[] = 'candidate_kind = :candidate_kind';
        $params[':candidate_kind'] = $candidateKind;
    }

    if (count($where) === 1) {
        throw new RuntimeException('Provide candidate_id or a narrowing selector such as queue_id, series_id, and/or candidate_kind');
    }

    $sql = "\n        SELECT *\n        FROM " . DB_CONTENT . ".content_artwork_candidates\n        WHERE " . implode(' AND ', $where) . "\n        ORDER BY\n            CASE candidate_status\n                WHEN 'approved' THEN 1\n                WHEN 'pending_review' THEN 2\n                ELSE 3\n            END,\n            confidence_score DESC,\n            id DESC\n        LIMIT 2\n    ";

    $stmt = $pdo->prepare($sql);
    $stmt->execute($params);
    $rows = $stmt->fetchAll(PDO::FETCH_ASSOC) ?: [];

    if (count($rows) > 1) {
        throw new RuntimeException('Multiple matching candidates found. Use candidate_id to select one explicitly.');
    }

    return $rows[0] ?? null;
}

function fetch_queue(PDO $pdo, ?int $queueId): ?array
{
    if (!$queueId || $queueId <= 0) {
        return null;
    }

    $stmt = $pdo->prepare("\n        SELECT *\n        FROM " . DB_IP . ".content_materialization_queue\n        WHERE id = :id\n        LIMIT 1\n    ");
    $stmt->execute([':id' => $queueId]);
    $row = $stmt->fetch(PDO::FETCH_ASSOC);
    return $row ?: null;
}

function fetch_series(PDO $pdo, int $seriesId): ?array
{
    $stmt = $pdo->prepare("\n        SELECT *\n        FROM " . DB_CONTENT . ".series\n        WHERE id = :id\n        LIMIT 1\n    ");
    $stmt->execute([':id' => $seriesId]);
    $row = $stmt->fetch(PDO::FETCH_ASSOC);
    return $row ?: null;
}

function detect_target_columns(array $seriesCols, string $candidateKind, string $targetField): array
{
    $candidateKind = strtolower(clean($candidateKind));
    $targetField = strtolower(clean($targetField));

    if ($targetField !== '' && $targetField !== 'auto') {
        if (!has_col($seriesCols, $targetField)) {
            throw new RuntimeException('Requested target_field does not exist on series table: ' . $targetField);
        }
        return [col_name($seriesCols, $targetField)];
    }

    if ($candidateKind === 'backdrop') {
        $candidates = ['backdrop_url', 'backdrop_path'];
        $out = [];
        foreach ($candidates as $candidate) {
            if (has_col($seriesCols, $candidate)) {
                $out[] = col_name($seriesCols, $candidate);
            }
        }
        return array_values(array_unique($out));
    }

    if ($candidateKind === 'poster' || $candidateKind === 'cover') {
        $candidates = ['poster_url', 'cover_url', 'tmdb_cover_url'];
        $out = [];
        foreach ($candidates as $candidate) {
            if (has_col($seriesCols, $candidate)) {
                $out[] = col_name($seriesCols, $candidate);
            }
        }
        return array_values(array_unique($out));
    }

    throw new RuntimeException('Unsupported candidate_kind. Use poster, cover, or backdrop.');
}

function current_image_state(PDO $pdo, int $seriesId, array $seriesCols): array
{
    $series = fetch_series($pdo, $seriesId);
    if (!$series) {
        throw new RuntimeException('Series row not found: ' . $seriesId);
    }

    $state = [
        'series_id' => $seriesId,
        'poster_url' => null,
        'cover_url' => null,
        'tmdb_cover_url' => null,
        'backdrop_url' => null,
    ];

    foreach (array_keys($state) as $key) {
        if ($key === 'series_id') {
            continue;
        }
        if (has_col($seriesCols, $key)) {
            $state[$key] = clean($series[col_name($seriesCols, $key)] ?? '');
        }
    }

    return $state;
}

function requested_missing_fields(?array $queue): array
{
    if (!$queue) {
        return [];
    }

    $missing = clean($queue['missing_fields'] ?? '');
    if ($missing === '') {
        return [];
    }

    $parts = array_map('trim', explode(',', $missing));
    $parts = array_filter($parts, static fn($v) => $v !== '');
    return array_values(array_unique($parts));
}

function field_is_missing(string $field, array $state): bool
{
    $field = strtolower(clean($field));

    if ($field === 'poster_url' || $field === 'cover_url' || $field === 'tmdb_cover_url') {
        return clean($state['poster_url'] ?? '') === ''
            && clean($state['cover_url'] ?? '') === ''
            && clean($state['tmdb_cover_url'] ?? '') === '';
    }

    if ($field === 'backdrop_url') {
        return clean($state['backdrop_url'] ?? '') === '';
    }

    return true;
}

function remaining_missing_fields(array $requestedFields, array $state): array
{
    $remaining = [];
    foreach ($requestedFields as $field) {
        if (field_is_missing($field, $state)) {
            $remaining[] = $field;
        }
    }
    return array_values(array_unique($remaining));
}

function has_poster_art(array $state): bool
{
    return clean($state['poster_url'] ?? '') !== ''
        || clean($state['cover_url'] ?? '') !== ''
        || clean($state['tmdb_cover_url'] ?? '') !== '';
}

function queue_trigger_reason(?array $queue): string
{
    if (!$queue) {
        return '';
    }

    return clean($queue['trigger_reason'] ?? '');
}

function maybe_complete_with_poster_only(?array $queue, array $remaining, array $state, bool $completeIfPosterPresent): array
{
    if (!$completeIfPosterPresent) {
        return $remaining;
    }

    if (!$queue) {
        return $remaining;
    }

    if (queue_trigger_reason($queue) !== 'series_port_900_image_repair') {
        return $remaining;
    }

    if (!has_poster_art($state)) {
        return $remaining;
    }

    // For port-900 image repair, a working poster/cover fixes the broken grid/tile.
    // Backdrop remains enrichment, not a blocker, when this flag is explicitly used.
    $allowedPosterOnlyRemaining = ['backdrop_url'];
    $normalizedRemaining = array_values(array_unique(array_map('clean', $remaining)));
    sort($normalizedRemaining);
    sort($allowedPosterOnlyRemaining);

    if ($normalizedRemaining === $allowedPosterOnlyRemaining) {
        return [];
    }

    return $remaining;
}

function update_series_artwork(PDO $pdo, int $seriesId, array $targetColumns, string $url): void
{
    if (!$targetColumns) {
        throw new RuntimeException('No usable target columns exist on series table for this candidate kind.');
    }

    $sets = [];
    $params = [
        ':id' => $seriesId,
    ];

    foreach (array_values($targetColumns) as $index => $col) {
        $paramName = ':url_' . $index;
        $sets[] = "`{$col}` = {$paramName}";
        $params[$paramName] = $url;
    }

    $sql = "
        UPDATE " . DB_CONTENT . ".series
        SET " . implode(', ', $sets) . "
        WHERE id = :id
        LIMIT 1
    ";

    $stmt = $pdo->prepare($sql);
    $stmt->execute($params);
}

function update_candidate_status(PDO $pdo, int $candidateId, string $status, string $reasonSuffix): void
{
    $stmt = $pdo->prepare("\n        UPDATE " . DB_CONTENT . ".content_artwork_candidates\n        SET candidate_status = :status,\n            reason = TRIM(BOTH ' |' FROM CONCAT(COALESCE(reason, ''), ' | ', :suffix)),\n            updated_at = NOW()\n        WHERE id = :id\n        LIMIT 1\n    ");
    $stmt->execute([
        ':id' => $candidateId,
        ':status' => $status,
        ':suffix' => $reasonSuffix,
    ]);
}

function update_queue_after_apply(PDO $pdo, int $queueId, array $remaining, string $note): void
{
    if ($queueId <= 0) {
        return;
    }

    if (!$remaining) {
        $lastError = null;
        if ($note === 'completed_with_poster_only') {
            $lastError = 'completed_with_poster_only';
        }

        $stmt = $pdo->prepare("
            UPDATE " . DB_IP . ".content_materialization_queue
            SET status = 'completed',
                missing_fields = '',
                completed_at = NOW(),
                last_error = :last_error,
                updated_at = NOW()
            WHERE id = :id
            LIMIT 1
        ");
        $stmt->execute([
            ':id' => $queueId,
            ':last_error' => $lastError,
        ]);
        return;
    }

    $stmt = $pdo->prepare("
        UPDATE " . DB_IP . ".content_materialization_queue
        SET status = 'queued',
            missing_fields = :missing_fields,
            last_error = :last_error,
            updated_at = NOW()
        WHERE id = :id
        LIMIT 1
    ");
    $stmt->execute([
        ':id' => $queueId,
        ':missing_fields' => implode(',', $remaining),
        ':last_error' => $note . ' | still_missing=' . implode(',', $remaining),
    ]);
}

try {
    $apply = bool_param('apply', false);
    $dryRun = bool_param('dry_run', !$apply);
    if ($dryRun) {
        $apply = false;
    }

    $candidateId = int_param('candidate_id', 0);
    $queueId = int_param('queue_id', 0);
    $seriesIdParam = int_param('series_id', 0);
    $candidateKindParam = strtolower(clean($_GET['candidate_kind'] ?? ''));
    $targetField = strtolower(clean($_GET['target_field'] ?? 'auto'));
    $acceptPending = bool_param('accept_pending', false);
    $completeIfPosterPresent = bool_param('complete_if_poster_present', false);

    $pdo = open_pdo();

    $candidate = fetch_candidate($pdo, $candidateId, $queueId, $seriesIdParam, $candidateKindParam);
    if (!$candidate) {
        json_out([
            'ok' => false,
            'endpoint_version' => ENDPOINT_VERSION,
            'error' => 'Candidate not found',
        ], 404);
    }

    $candidateId = (int)$candidate['id'];
    $seriesId = (int)$candidate['content_id'];
    $queueId = (int)($candidate['queue_id'] ?? 0);
    $candidateKind = strtolower(clean($candidate['candidate_kind'] ?? ''));
    $candidateStatus = strtolower(clean($candidate['candidate_status'] ?? ''));
    $candidateUrl = clean($candidate['candidate_url'] ?? '');

    if (!is_safe_candidate_url($candidateUrl)) {
        json_out([
            'ok' => false,
            'endpoint_version' => ENDPOINT_VERSION,
            'error' => 'Missing, invalid, unsafe, or port-900 candidate_url',
            'candidate_id' => $candidateId,
            'candidate_url' => $candidateUrl,
        ], 400);
    }
    if ($candidateStatus === 'applied' && !$completeIfPosterPresent) {
        json_out([
            'ok' => true,
            'endpoint_version' => ENDPOINT_VERSION,
            'dry_run' => $dryRun,
            'apply' => $apply,
            'complete_if_poster_present' => $completeIfPosterPresent,
            'candidate_id' => $candidateId,
            'already_applied' => true,
            'message' => 'Candidate already applied',
            'candidate' => $candidate,
        ]);
    }

    if (
        $candidateStatus !== 'approved'
        && !($candidateStatus === 'pending_review' && $acceptPending)
        && !($candidateStatus === 'applied' && $completeIfPosterPresent)
    ) {
        json_out([
            'ok' => false,
            'endpoint_version' => ENDPOINT_VERSION,
            'error' => 'Candidate is not approved. Pass accept_pending=1 to apply a pending_review candidate.',
            'candidate_id' => $candidateId,
            'candidate_status' => $candidateStatus,
        ], 409);
    }

    $seriesCols = table_columns($pdo, DB_CONTENT, 'series');
    $queue = fetch_queue($pdo, $queueId);
    $seriesBefore = fetch_series($pdo, $seriesId);
    if (!$seriesBefore) {
        json_out([
            'ok' => false,
            'endpoint_version' => ENDPOINT_VERSION,
            'error' => 'Series row not found',
            'series_id' => $seriesId,
        ], 404);
    }

    $targetColumns = detect_target_columns($seriesCols, $candidateKind, $targetField);
    $stateBefore = current_image_state($pdo, $seriesId, $seriesCols);
    $requestedBefore = requested_missing_fields($queue);

    $predictedState = $stateBefore;
    foreach ($targetColumns as $targetColumn) {
        $lower = strtolower($targetColumn);
        if (array_key_exists($lower, $predictedState)) {
            $predictedState[$lower] = $candidateUrl;
        }
    }
    $strictRemainingAfterPredicted = remaining_missing_fields($requestedBefore, $predictedState);
    $remainingAfterPredicted = maybe_complete_with_poster_only($queue, $strictRemainingAfterPredicted, $predictedState, $completeIfPosterPresent);
    $posterOnlyCompletionPredicted = $completeIfPosterPresent && $strictRemainingAfterPredicted && !$remainingAfterPredicted;

    $applied = false;
    if ($apply) {
        $pdo->beginTransaction();

        if ($candidateStatus !== 'applied') {
            update_series_artwork($pdo, $seriesId, $targetColumns, $candidateUrl);
            update_candidate_status($pdo, $candidateId, 'applied', 'applied_to_series_catalog');
        }
        $stateAfter = current_image_state($pdo, $seriesId, $seriesCols);
        $strictRemainingAfter = remaining_missing_fields($requestedBefore, $stateAfter);
        $remainingAfter = maybe_complete_with_poster_only($queue, $strictRemainingAfter, $stateAfter, $completeIfPosterPresent);
        $posterOnlyCompletionApplied = $completeIfPosterPresent && $strictRemainingAfter && !$remainingAfter;
        update_queue_after_apply(
            $pdo,
            $queueId,
            $remainingAfter,
            $posterOnlyCompletionApplied ? 'completed_with_poster_only' : 'manual_artwork_candidate_applied'
        );

        $pdo->commit();
        $applied = true;
    } else {
        $stateAfter = $predictedState;
        $remainingAfter = $remainingAfterPredicted;
        $posterOnlyCompletionApplied = false;
    }

    $queueAfter = fetch_queue($pdo, $queueId);

    json_out([
        'ok' => true,
        'endpoint_version' => ENDPOINT_VERSION,
        'dry_run' => $dryRun,
        'apply' => $apply,
        'applied' => $applied,
        'complete_if_poster_present' => $completeIfPosterPresent,
        'poster_only_completion' => $apply ? ($posterOnlyCompletionApplied ?? false) : ($posterOnlyCompletionPredicted ?? false),
        'candidate' => [
            'id' => $candidateId,
            'content_id' => $seriesId,
            'queue_id' => $queueId,
            'candidate_url' => $candidateUrl,
            'candidate_kind' => $candidateKind,
            'candidate_source' => clean($candidate['candidate_source'] ?? ''),
            'candidate_status_before' => $candidateStatus,
            'candidate_status_after' => ($apply || $candidateStatus === 'applied') ? 'applied' : $candidateStatus,
        ],
        'series' => [
            'id' => $seriesId,
            'name' => clean($seriesBefore['name'] ?? ''),
            'clean_search_name' => clean($seriesBefore['clean_search_name'] ?? ''),
            'tmdb_search_name' => clean($seriesBefore['tmdb_search_name'] ?? ''),
            'target_columns' => $targetColumns,
            'image_state_before' => $stateBefore,
            'image_state_after' => $stateAfter,
        ],
        'queue' => [
            'id' => $queueId,
            'status_before' => $queue ? clean($queue['status'] ?? '') : null,
            'missing_fields_before' => $requestedBefore,
            'strict_missing_fields_after' => $apply ? ($strictRemainingAfter ?? $remainingAfter) : ($strictRemainingAfterPredicted ?? $remainingAfter),
            'missing_fields_after' => $remainingAfter,
            'status_after' => $queueAfter ? clean($queueAfter['status'] ?? '') : (!$remainingAfter ? 'completed' : 'queued'),
            'completed_after_apply' => !$remainingAfter,
        ],
    ]);
} catch (Throwable $e) {
    if (isset($pdo) && $pdo instanceof PDO && $pdo->inTransaction()) {
        $pdo->rollBack();
    }

    json_out([
        'ok' => false,
        'endpoint_version' => ENDPOINT_VERSION,
        'error' => $e->getMessage(),
    ], 500);
}
