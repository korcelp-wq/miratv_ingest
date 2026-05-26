<?php
/**
 * MiraTV Ingest Automation PHP Logging Helper
 * File: _workers/common/worker_logging.php
 *
 * Purpose:
 *   Shared local-first logging, heartbeat, signal, kill-switch, and redaction helpers
 *   for MiraTV PHP workers/endpoints/materializers.
 *
 * Contract:
 *   - No external dependencies.
 *   - No DB dependency in this first helper version.
 *   - Writes local JSONL fallback logs by default.
 *   - Never logs raw provider usernames, passwords, tokens, API keys, or full playback URLs.
 *   - Designed to satisfy the Automation Implementation Contract baseline.
 */

declare(strict_types=1);

if (!function_exists('miratv_new_run_id')) {
    function miratv_new_run_id(string $prefix = 'run'): string
    {
        $stamp = gmdate('Ymd\THis') . sprintf('%03d', (int) floor((microtime(true) - floor(microtime(true))) * 1000)) . 'Z';

        try {
            $bytes = random_bytes(16);
            $guid = bin2hex($bytes);
        } catch (Throwable $e) {
            $guid = str_replace('.', '', uniqid('', true));
        }

        return $prefix . '-' . $stamp . '-' . $guid;
    }
}

if (!function_exists('miratv_repo_root')) {
    function miratv_repo_root(): string
    {
        /*
         * Expected location:
         *   <repo>/_workers/common/worker_logging.php
         *
         * Repo root is two levels up from _workers/common.
         */
        $root = realpath(__DIR__ . DIRECTORY_SEPARATOR . '..' . DIRECTORY_SEPARATOR . '..');

        if ($root !== false) {
            return $root;
        }

        return getcwd() ?: __DIR__;
    }
}

if (!function_exists('miratv_ensure_dir')) {
    function miratv_ensure_dir(string $path): void
    {
        if ($path === '') {
            return;
        }

        if (!is_dir($path)) {
            mkdir($path, 0775, true);
        }
    }
}

if (!function_exists('miratv_default_log_root')) {
    function miratv_default_log_root(): string
    {
        return miratv_repo_root() . DIRECTORY_SEPARATOR . 'runtime' . DIRECTORY_SEPARATOR . 'logs';
    }
}

if (!function_exists('miratv_is_sensitive_field')) {
    function miratv_is_sensitive_field(string $fieldName): bool
    {
        return (bool) preg_match(
            '/(provider_username|provider_password|password|passwd|pwd|token|api_key|apikey|secret|credential|auth|authorization|full_playback_url|playback_url|provider_url|url)/i',
            $fieldName
        );
    }
}

if (!function_exists('miratv_redact_secret')) {
    function miratv_redact_secret($value, string $fieldName = '')
    {
        if ($value === null) {
            return null;
        }

        if (miratv_is_sensitive_field($fieldName)) {
            if (preg_match('/(full_playback_url|playback_url|provider_url|url)/i', $fieldName)) {
                return 'REDACTED_URL';
            }

            return 'REDACTED';
        }

        if (is_string($value)) {
            $text = $value;

            $text = preg_replace(
                '/(password|passwd|pwd|token|api_key|apikey|secret|username|user)=([^&\s]+)/i',
                '$1=REDACTED',
                $text
            );

            $text = preg_replace(
                '/(Bearer\s+)[A-Za-z0-9\-\._~\+\/]+=*/i',
                '$1REDACTED',
                $text
            );

            $text = preg_replace(
                '/https?:\/\/[^\s"]+/i',
                'REDACTED_URL',
                $text
            );

            return $text;
        }

        return $value;
    }
}

if (!function_exists('miratv_protect_log_data')) {
    function miratv_protect_log_data(array $data): array
    {
        $clean = [];

        foreach ($data as $key => $value) {
            $keyString = (string) $key;

            if (is_array($value)) {
                $clean[$keyString] = miratv_protect_log_data($value);
            } else {
                $clean[$keyString] = miratv_redact_secret($value, $keyString);
            }
        }

        return $clean;
    }
}

if (!function_exists('miratv_json_encode_line')) {
    function miratv_json_encode_line(array $record): string
    {
        $json = json_encode(
            $record,
            JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PARTIAL_OUTPUT_ON_ERROR
        );

        if ($json === false) {
            $fallback = [
                'timestamp' => gmdate('c'),
                'event_type' => 'json_encode_failed',
                'status' => 'failed',
                'error_message' => json_last_error_msg(),
            ];

            $json = json_encode($fallback, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
        }

        return (string) $json;
    }
}

if (!function_exists('miratv_safe_component_name')) {
    function miratv_safe_component_name(string $component): string
    {
        $component = trim($component);

        if ($component === '') {
            $component = 'unknown_component';
        }

        return preg_replace('/[^A-Za-z0-9_\-\.]/', '_', $component) ?: 'unknown_component';
    }
}

if (!function_exists('miratv_write_json_line')) {
    function miratv_write_json_line(array $record, ?string $logRoot = null): string
    {
        $root = $logRoot;

        if ($root === null || trim($root) === '') {
            $root = miratv_default_log_root();
        }

        $component = isset($record['component']) ? (string) $record['component'] : 'unknown_component';
        $safeComponent = miratv_safe_component_name($component);

        $componentDir = rtrim($root, DIRECTORY_SEPARATOR) . DIRECTORY_SEPARATOR . $safeComponent;
        miratv_ensure_dir($componentDir);

        $logFile = $componentDir . DIRECTORY_SEPARATOR . gmdate('Ymd') . '.jsonl';

        $line = miratv_json_encode_line($record) . PHP_EOL;

        file_put_contents($logFile, $line, FILE_APPEND | LOCK_EX);

        return $logFile;
    }
}

if (!function_exists('miratv_base_log_record')) {
    function miratv_base_log_record(
        string $runId = '',
        string $jobName = '',
        string $workerName = '',
        string $component = '',
        string $environment = 'prod',
        string $status = 'info',
        string $eventType = 'job_event',
        array $data = []
    ): array {
        if (trim($runId) === '') {
            $runId = miratv_new_run_id();
        }

        if (trim($jobName) === '') {
            $jobName = 'unknown_job';
        }

        if (trim($workerName) === '') {
            $workerName = 'unknown_worker';
        }

        if (trim($component) === '') {
            $component = 'unknown_component';
        }

        if (trim($environment) === '') {
            $environment = 'prod';
        }

        if (trim($status) === '') {
            $status = 'info';
        }

        if (trim($eventType) === '') {
            $eventType = 'job_event';
        }

        $now = gmdate('c');

        $record = [
            'timestamp' => $now,
            'emitted_at' => $now,
            'run_id' => $runId,
            'job_name' => $jobName,
            'worker_name' => $workerName,
            'component' => $component,
            'environment' => $environment,
            'status' => $status,
            'event_type' => $eventType,
        ];

        $cleanData = miratv_protect_log_data($data);

        foreach ($cleanData as $key => $value) {
            $record[$key] = $value;
        }

        return $record;
    }
}

if (!function_exists('is_kill_switch_enabled')) {
    function is_kill_switch_enabled(string $name, bool $defaultEnabled = true): bool
    {
        if (trim($name) === '') {
            throw new InvalidArgumentException('Kill switch name is required.');
        }

        $value = getenv($name);

        if ($value === false || trim((string) $value) === '') {
            return $defaultEnabled;
        }

        $normalized = strtolower(trim((string) $value));

        if (in_array($normalized, ['1', 'true', 'yes', 'y', 'on', 'enabled', 'enable'], true)) {
            return true;
        }

        if (in_array($normalized, ['0', 'false', 'no', 'n', 'off', 'disabled', 'disable'], true)) {
            return false;
        }

        return $defaultEnabled;
    }
}

if (!function_exists('worker_log')) {
    function worker_log(array $args, ?string $logRoot = null): string
    {
        $data = isset($args['data']) && is_array($args['data']) ? $args['data'] : [];

        $payload = [];

        $optionalFields = [
            'database_target',
            'source_name',
            'attempt',
            'error_code',
            'error_message',
            'rows_inserted',
            'rows_updated',
            'rows_skipped',
            'rows_failed',
            'source_row_count',
            'duration_ms',
            'mac_user_id',
            'screen_type',
            'provider',
        ];

        foreach ($optionalFields as $field) {
            if (array_key_exists($field, $args) && $args[$field] !== null && $args[$field] !== '') {
                $payload[$field] = $args[$field];
            }
        }

        foreach ($data as $key => $value) {
            $payload[(string) $key] = $value;
        }

        if (!isset($payload['attempt'])) {
            $payload['attempt'] = 1;
        }

        $record = miratv_base_log_record(
            (string) ($args['run_id'] ?? ''),
            (string) ($args['job_name'] ?? ''),
            (string) ($args['worker_name'] ?? ''),
            (string) ($args['component'] ?? ''),
            (string) ($args['environment'] ?? 'prod'),
            (string) ($args['status'] ?? 'info'),
            (string) ($args['event_type'] ?? 'job_event'),
            $payload
        );

        return miratv_write_json_line($record, $logRoot);
    }
}

if (!function_exists('emit_heartbeat')) {
    function emit_heartbeat(array $args, ?string $logRoot = null): string
    {
        $data = isset($args['data']) && is_array($args['data']) ? $args['data'] : [];

        $heartbeatStatus = (string) ($args['heartbeat_status'] ?? 'ok');

        $payload = [
            'heartbeat_status' => $heartbeatStatus,
            'heartbeat_interval_seconds' => (int) ($args['heartbeat_interval_seconds'] ?? 60),
            'stale_after_seconds' => (int) ($args['stale_after_seconds'] ?? 300),
            'last_heartbeat_at' => gmdate('c'),
        ];

        foreach ($data as $key => $value) {
            $payload[(string) $key] = $value;
        }

        $record = miratv_base_log_record(
            (string) ($args['run_id'] ?? ''),
            (string) ($args['job_name'] ?? 'worker_heartbeat'),
            (string) ($args['worker_name'] ?? ''),
            (string) ($args['component'] ?? ''),
            (string) ($args['environment'] ?? 'prod'),
            $heartbeatStatus,
            'heartbeat',
            $payload
        );

        return miratv_write_json_line($record, $logRoot);
    }
}

if (!function_exists('emit_signal')) {
    function emit_signal(array $args, ?string $logRoot = null): string
    {
        if (!isset($args['signal_name']) || trim((string) $args['signal_name']) === '') {
            throw new InvalidArgumentException('signal_name is required.');
        }

        $data = isset($args['data']) && is_array($args['data']) ? $args['data'] : [];

        $payload = [
            'signal_name' => (string) $args['signal_name'],
        ];

        $optionalFields = [
            'p0_item',
            'signal_value',
            'value_num',
            'allowed_values',
            'source_table_or_endpoint',
            'mac_user_id',
            'screen_type',
            'error_code',
            'error_message',
            'dashboard_panel',
            'widget_key',
            'owner',
            'kill_switch_name',
        ];

        foreach ($optionalFields as $field) {
            if (array_key_exists($field, $args) && $args[$field] !== null && $args[$field] !== '') {
                $payload[$field] = $args[$field];
            }
        }

        foreach ($data as $key => $value) {
            $payload[(string) $key] = $value;
        }

        $record = miratv_base_log_record(
            (string) ($args['run_id'] ?? ''),
            (string) ($args['job_name'] ?? 'emit_signal'),
            (string) ($args['worker_name'] ?? ''),
            (string) ($args['component'] ?? ''),
            (string) ($args['environment'] ?? 'prod'),
            (string) ($args['status'] ?? 'ok'),
            'signal',
            $payload
        );

        return miratv_write_json_line($record, $logRoot);
    }
}