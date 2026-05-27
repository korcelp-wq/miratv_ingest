<?php
declare(strict_types=1);

/**
 * MiraTV - Normalize Media Search Names
 *
 * Endpoint version:
 *   6B-5H6-2026-05-27-live-native-script-preservation
 *
 * Target server path:
 *   /home/xpdgxfsp/public_html/_workers/ai/api/normalize_media_search_names.php
 *
 * Purpose:
 *   Normalizes search-name columns without overwriting provider/original title fields.
 *
 * Supported modes:
 *   media_type=series
 *   media_type=vod
 *   media_type=live
 *
 * Safety:
 *   - dry_run=1 is default.
 *   - apply=1 is required to write.
 *   - Original title/name columns are never changed.
 *   - Series/VOD write clean_search_name and tmdb_search_name only.
 *   - Live writes clean_search_name only.
 *   - VOD uses vod_id as the primary key.
 *   - Numeric hyphen titles such as 9-1-1 are preserved.
 *   - Decorative symbols and VIP/provider fragments are stripped more aggressively.
 *   - Search punctuation , . ' ; : " is removed.
 *   - Empty/punctuation-only proposed names are not written.
 *   - Accented characters are folded for search stability, e.g. Quédate -> Quedate, Español -> Espanol.
 *   - Apostrophes are removed without splitting words, e.g. Man's -> Mans.
 *   - Brackets/parentheses/braces are removed from search names.
 *   - MULTISUB, quality, language, and media suffix tags are stripped more aggressively.
 *   - Decorative ? artifacts caused by ASCII folding are removed.
 *   - Live preserves native-script names instead of ASCII-folding them.
 *   - Dry-run output includes Google candidate queries for native-script/live rows.
 *
 * Example:
 *   normalize_media_search_names.php?media_type=series&dry_run=1&limit=25&only_missing=0
 *   normalize_media_search_names.php?media_type=vod&apply=1&limit=100&only_missing=1
 *   normalize_media_search_names.php?media_type=live&apply=1&limit=100&only_missing=1
 */

const ENDPOINT_VERSION = '6B-5H6-2026-05-27-live-native-script-preservation';
const DB_CONTENT = 'xpdgxfsp_content';

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

function bool_param(string $key, bool $default = false): bool
{
    if (!isset($_GET[$key])) {
        return $default;
    }

    $value = strtolower(clean($_GET[$key]));
    return in_array($value, ['1', 'true', 'yes', 'y', 'on'], true);
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
    } elseif (isset($config['dsn'])) {
        $entry = $config;
    } elseif (isset($config['ip']['dsn'])) {
        $entry = $config['ip'];
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

function normalize_unicode_spaces(string $value): string
{
    $value = str_replace(["\xC2\xA0", "\t", "\r", "\n"], ' ', $value);
    $value = preg_replace('/\s+/u', ' ', $value) ?? $value;
    return trim($value);
}

function noise_tag_pattern(): string
{
    return implode('|', [
        'MULTI[-_\s]?SUB',
        'MULTISUB',
        'MULTI\s*SUB',
        'MULTI[-_\s]?LANG',
        'SUBS?',
        'DUAL\s*AUDIO',
        'LATINO',
        'CAST',
        'CASTELLANO',
        'ESP',
        'SPA',
        'SPANISH',
        'ENG',
        'ENGLISH',
        'FR',
        'FRENCH',
        'IT',
        'ITALIAN',
        'AR',
        'ARABIC',
        'PT',
        'PORTUGUESE',
        'DE',
        'GERMAN',
        '4K',
        'UHD',
        'FHD',
        'HD',
        'SD',
        'CAM',
        'TS',
        'HDCAM',
        'WEB[-_\s]?DL',
        'WEBRIP',
        'BLURAY',
        'BRRIP',
        'HDRIP',
    ]);
}

function strip_wrapped_noise_tags(string $value): string
{
    $pattern = noise_tag_pattern();

    // Remove bracketed/parenthesized/braced noise tags.
    $value = preg_replace('/[\[\(\{]\s*(?:' . $pattern . ')\s*[\]\)\}]/iu', ' ', $value) ?? $value;

    // Remove standalone provider/media quality suffixes at the end.
    $value = preg_replace('/(?:[\s\-_]+)(?:' . $pattern . ')\s*$/iu', ' ', $value) ?? $value;

    // Remove standalone provider/media quality prefixes at the beginning.
    $value = preg_replace('/^\s*(?:' . $pattern . ')(?:[\s\-_]+)/iu', ' ', $value) ?? $value;

    // Remove remaining standalone MULTISUB variants anywhere.
    $value = preg_replace('/\b(?:MULTI_SUB|MULTI-SUB|MULTISUB|MULTI\s+SUB)\b/iu', ' ', $value) ?? $value;

    return $value;
}

function strip_all_bracket_shells(string $value): string
{
    // Search names should not retain brackets/braces/parentheses.
    $value = str_replace(['[', ']', '(', ')', '{', '}'], ' ', $value);
    return $value;
}

function strip_orphan_question_noise(string $value): string
{
    // iconv may convert decorative symbols to ?. Treat standalone/repeated ? as decoration.
    $value = preg_replace('/(?:^|\s)\?+(?=\s|$)/u', ' ', $value) ?? $value;
    $value = preg_replace('/^\?+\s*/u', '', $value) ?? $value;
    $value = preg_replace('/\s*\?+$/u', '', $value) ?? $value;
    return $value;
}

function strip_language_prefixes(string $value): string
{
    // Prefixes like ES| Title, EN - Title, [ES] Title, (FR) Title.
    $value = preg_replace('/^\s*[\[\(\{]?\s*(?:ES|EN|FR|IT|AR|PT|DE|NL|TR|LAT|MX|MY|US|UK|BR|IN|JP|KR|CN|PL|RU|SE|NO|DK|FI)\s*[\]\)\}]?\s*(?:\||-|:|\/)\s*/iu', '', $value) ?? $value;

    // Multi-lang category-like prefixes.
    $value = preg_replace('/^\s*[\[\(\{]?\s*(?:MULTI[-_\s]?LANG|MULTI[-_\s]?SUB|LATINO|CASTELLANO)\s*[\]\)\}]?\s*(?:\||-|:|\/)\s*/iu', '', $value) ?? $value;

    return $value;
}

function strip_known_provider_prefixes(string $value): string
{
    // Remove common IPTV grouping prefixes while preserving actual title words.
    $value = preg_replace('/^\s*(?:VIP|VOD|MOVIE|MOVIES|SERIES|TV|LIVE)\s*(?:\||-|:|\/)\s*/iu', '', $value) ?? $value;
    return $value;
}

function strip_decorative_symbols(string $value): string
{
    // Remove common decorative bullets/stars while preserving normal title punctuation.
    $value = preg_replace('/[✦★☆●•◆◇■□▲△▼▽]+/u', ' ', $value) ?? $value;

    // Remove repeated ornamental punctuation at edges.
    $value = preg_replace('/^\s*[\|\-:\/~=_*#]+\s*/u', '', $value) ?? $value;
    $value = preg_replace('/\s*[\|\-:\/~=_*#]+\s*$/u', '', $value) ?? $value;

    return $value;
}

function normalize_provider_fragments(string $value): string
{
    // Remove provider-tier fragments that commonly appear inside live/channel labels.
    $value = preg_replace('/(?:^|[\s\|\-:\/])(?:AR[-_\s]?)?VIP(?:$|[\s\|\-:\/])/iu', ' ', $value) ?? $value;
    $value = preg_replace('/(?:^|[\s\|\-:\/])(?:PREMIUM|ULTRA|BACKUP|BKP)(?:$|[\s\|\-:\/])/iu', ' ', $value) ?? $value;

    return $value;
}

function normalize_separators(string $value): string
{
    $value = str_replace(['_', '¦', '»', '«'], ' ', $value);

    // Pipes are provider/category separators for this data set, not title punctuation.
    $value = preg_replace('/\s*\|\s*/u', ' ', $value) ?? $value;

    // Remove bracket shell characters before final punctuation cleanup.
    $value = strip_all_bracket_shells($value);

    // Preserve digit-hyphen-digit title patterns such as 9-1-1 or 24-7.
    $placeholderMap = [];
    $value = preg_replace_callback('/\b\d+(?:-\d+)+\b/u', function (array $m) use (&$placeholderMap): string {
        $key = '__NUMHYPHEN_' . count($placeholderMap) . '__';
        $placeholderMap[$key] = $m[0];
        return $key;
    }, $value) ?? $value;

    // Apostrophes are removed without adding a space:
    // Man's -> Mans, Don't -> Dont.
    $value = str_replace(["'", "’", "`", "´"], '', $value);

    // Other search punctuation becomes a separator.
    $value = str_replace([',', '.', ';', ':', '"', '“', '”'], ' ', $value);

    // Treat slashes and non-numeric dashes as separators.
    $value = preg_replace('/\s*\/\s*/u', ' ', $value) ?? $value;
    $value = preg_replace('/\s*-\s*/u', ' ', $value) ?? $value;

    foreach ($placeholderMap as $key => $original) {
        $value = str_replace($key, $original, $value);
    }

    $value = strip_orphan_question_noise($value);
    $value = preg_replace('/\s+/u', ' ', $value) ?? $value;

    return trim($value, " \t\n\r\0\x0B-|/.,';:\"]()[]{}?");
}

function is_valid_proposed_search_name(string $value): bool
{
    $value = trim($value);

    if ($value === '') {
        return false;
    }

    // Reject pure bracket/paren/brace shells and punctuation-only results.
    if (preg_match('/^[\[\]\(\)\{\}\s\-_\/\\\\.,;\':"]+$/u', $value)) {
        return false;
    }

    // Require at least one Unicode letter or number.
    if (!preg_match('/[\p{L}\p{N}]/u', $value)) {
        return false;
    }

    return true;
}

function normalize_encoding_artifacts(string $value): string
{
    // Conservative cleanup for common mojibake fragments. Do not overcorrect all accents.
    $replacements = [
        'Ã¡' => 'á',
        'Ã©' => 'é',
        'Ã­' => 'í',
        'Ã³' => 'ó',
        'Ãº' => 'ú',
        'Ã±' => 'ñ',
        'Ã' => 'Á',
        'Ã‰' => 'É',
        'Ã' => 'Í',
        'Ã“' => 'Ó',
        'Ãš' => 'Ú',
        'Ã‘' => 'Ñ',
        'Ã¼' => 'ü',
        'Ã¶' => 'ö',
        'Ã¤' => 'ä',
        'Ã¨' => 'è',
        'Ãª' => 'ê',
        'Ã§' => 'ç',
        'â€™' => "'",
        'â€œ' => '"',
        'â€' => '"',
        'â€“' => '-',
        'â€”' => '-',
    ];

    return strtr($value, $replacements);
}


function fold_search_name_to_ascii(string $value): string
{
    // Search fields should be stable ASCII where possible:
    // Quédate -> Quedate, Fiancé -> Fiance, Español -> Espanol.
    $map = [
        'À' => 'A', 'Á' => 'A', 'Â' => 'A', 'Ã' => 'A', 'Ä' => 'A', 'Å' => 'A', 'Ā' => 'A', 'Ă' => 'A', 'Ą' => 'A',
        'à' => 'a', 'á' => 'a', 'â' => 'a', 'ã' => 'a', 'ä' => 'a', 'å' => 'a', 'ā' => 'a', 'ă' => 'a', 'ą' => 'a',
        'Æ' => 'AE', 'æ' => 'ae',
        'Ç' => 'C', 'Ć' => 'C', 'Ĉ' => 'C', 'Ċ' => 'C', 'Č' => 'C',
        'ç' => 'c', 'ć' => 'c', 'ĉ' => 'c', 'ċ' => 'c', 'č' => 'c',
        'Ð' => 'D', 'Ď' => 'D', 'Đ' => 'D',
        'ð' => 'd', 'ď' => 'd', 'đ' => 'd',
        'È' => 'E', 'É' => 'E', 'Ê' => 'E', 'Ë' => 'E', 'Ē' => 'E', 'Ĕ' => 'E', 'Ė' => 'E', 'Ę' => 'E', 'Ě' => 'E',
        'è' => 'e', 'é' => 'e', 'ê' => 'e', 'ë' => 'e', 'ē' => 'e', 'ĕ' => 'e', 'ė' => 'e', 'ę' => 'e', 'ě' => 'e',
        'Ĝ' => 'G', 'Ğ' => 'G', 'Ġ' => 'G', 'Ģ' => 'G',
        'ĝ' => 'g', 'ğ' => 'g', 'ġ' => 'g', 'ģ' => 'g',
        'Ĥ' => 'H', 'Ħ' => 'H',
        'ĥ' => 'h', 'ħ' => 'h',
        'Ì' => 'I', 'Í' => 'I', 'Î' => 'I', 'Ï' => 'I', 'Ĩ' => 'I', 'Ī' => 'I', 'Ĭ' => 'I', 'Į' => 'I', 'İ' => 'I',
        'ì' => 'i', 'í' => 'i', 'î' => 'i', 'ï' => 'i', 'ĩ' => 'i', 'ī' => 'i', 'ĭ' => 'i', 'į' => 'i', 'ı' => 'i',
        'Ĵ' => 'J', 'ĵ' => 'j',
        'Ķ' => 'K', 'ķ' => 'k',
        'Ĺ' => 'L', 'Ļ' => 'L', 'Ľ' => 'L', 'Ŀ' => 'L', 'Ł' => 'L',
        'ĺ' => 'l', 'ļ' => 'l', 'ľ' => 'l', 'ŀ' => 'l', 'ł' => 'l',
        'Ñ' => 'N', 'Ń' => 'N', 'Ņ' => 'N', 'Ň' => 'N',
        'ñ' => 'n', 'ń' => 'n', 'ņ' => 'n', 'ň' => 'n',
        'Ò' => 'O', 'Ó' => 'O', 'Ô' => 'O', 'Õ' => 'O', 'Ö' => 'O', 'Ø' => 'O', 'Ō' => 'O', 'Ŏ' => 'O', 'Ő' => 'O',
        'ò' => 'o', 'ó' => 'o', 'ô' => 'o', 'õ' => 'o', 'ö' => 'o', 'ø' => 'o', 'ō' => 'o', 'ŏ' => 'o', 'ő' => 'o',
        'Œ' => 'OE', 'œ' => 'oe',
        'Ŕ' => 'R', 'Ŗ' => 'R', 'Ř' => 'R',
        'ŕ' => 'r', 'ŗ' => 'r', 'ř' => 'r',
        'Ś' => 'S', 'Ŝ' => 'S', 'Ş' => 'S', 'Š' => 'S',
        'ś' => 's', 'ŝ' => 's', 'ş' => 's', 'š' => 's',
        'Ţ' => 'T', 'Ť' => 'T', 'Ŧ' => 'T',
        'ţ' => 't', 'ť' => 't', 'ŧ' => 't',
        'Ù' => 'U', 'Ú' => 'U', 'Û' => 'U', 'Ü' => 'U', 'Ũ' => 'U', 'Ū' => 'U', 'Ŭ' => 'U', 'Ů' => 'U', 'Ű' => 'U', 'Ų' => 'U',
        'ù' => 'u', 'ú' => 'u', 'û' => 'u', 'ü' => 'u', 'ũ' => 'u', 'ū' => 'u', 'ŭ' => 'u', 'ů' => 'u', 'ű' => 'u', 'ų' => 'u',
        'Ý' => 'Y', 'Ÿ' => 'Y', 'Ŷ' => 'Y',
        'ý' => 'y', 'ÿ' => 'y', 'ŷ' => 'y',
        'Ź' => 'Z', 'Ż' => 'Z', 'Ž' => 'Z',
        'ź' => 'z', 'ż' => 'z', 'ž' => 'z',
        'Þ' => 'TH', 'þ' => 'th',
        'ß' => 'ss',
    ];

    $value = strtr($value, $map);

    // If intl/iconv is available, use it as a secondary safety net.
    if (function_exists('iconv')) {
        $converted = @iconv('UTF-8', 'ASCII//TRANSLIT//IGNORE', $value);
        if (is_string($converted) && $converted !== '') {
            $value = $converted;
        }
    }

    return $value;
}

function normalize_search_name(string $raw, string $mediaType = 'generic'): string
{
    $mediaType = strtolower(clean($mediaType));

    $value = normalize_encoding_artifacts($raw);
    $value = strip_decorative_symbols($value);
    $value = strip_orphan_question_noise($value);

    // VOD/Series feed TMDb-style lookup paths, so ASCII folding helps.
    // Live clean names feed provider/EPG/channel matching and Google/native-script candidate lookup,
    // so preserve Arabic/Hebrew/CJK/etc. names.
    if ($mediaType !== 'live') {
        $value = fold_search_name_to_ascii($value);
        $value = strip_decorative_symbols($value);
        $value = strip_orphan_question_noise($value);
    }

    $value = normalize_unicode_spaces($value);

    $value = strip_language_prefixes($value);
    $value = strip_known_provider_prefixes($value);
    $value = normalize_provider_fragments($value);

    $value = strip_wrapped_noise_tags($value);
    $value = normalize_separators($value);
    $value = strip_wrapped_noise_tags($value);
    $value = strip_all_bracket_shells($value);
    $value = normalize_separators($value);

    $value = strip_decorative_symbols($value);
    $value = strip_orphan_question_noise($value);
    $value = normalize_provider_fragments($value);
    $value = strip_wrapped_noise_tags($value);
    $value = normalize_unicode_spaces($value);

    return $value;
}

function contains_non_latin_script(string $value): bool
{
    return (bool)preg_match('/[\x{0590}-\x{05FF}\x{0600}-\x{06FF}\x{0750}-\x{077F}\x{08A0}-\x{08FF}\x{3040}-\x{30FF}\x{3400}-\x{4DBF}\x{4E00}-\x{9FFF}\x{AC00}-\x{D7AF}]/u', $value);
}

function build_google_candidate_queries(string $mediaType, string $cleanName): array
{
    $mediaType = strtolower(clean($mediaType));
    $cleanName = clean($cleanName);

    if ($cleanName === '') {
        return [];
    }

    if ($mediaType === 'live') {
        if (contains_non_latin_script($cleanName)) {
            return array_values(array_unique([
                $cleanName,
                $cleanName . ' مسلسل poster',
                $cleanName . ' بوستر',
                $cleanName . ' tv series poster',
            ]));
        }

        return array_values(array_unique([
            $cleanName,
            $cleanName . ' live channel logo',
            $cleanName . ' tv channel image',
        ]));
    }

    if ($mediaType === 'series') {
        return array_values(array_unique([
            $cleanName,
            $cleanName . ' series poster',
            $cleanName . ' tv series poster',
        ]));
    }

    if ($mediaType === 'vod') {
        return array_values(array_unique([
            $cleanName,
            $cleanName . ' movie poster',
            $cleanName . ' film poster',
        ]));
    }

    return [$cleanName];
}

function looks_dirty(?string $value): bool
{
    $value = clean($value);
    if ($value === '') {
        return true;
    }

    $patterns = [
        '/^\s*[\[\(\{]?\s*(?:ES|EN|FR|IT|AR|PT|DE|LAT|MX|US|UK)\s*[\]\)\}]?\s*(?:\||-|:|\/)/iu',
        '/[\[\(\{]\s*(?:MULTI[-_\s]?SUB|MULTISUB|MULTI\s*SUB|4K|FHD|HD|SD|DUAL\s*AUDIO)\s*[\]\)\}]/iu',
        '/(?:MULTI_SUB|MULTI-SUB|MULTISUB|MULTI SUB)/iu',
        '/[\[\]\(\)\{\}]/u',
        '/(?:^|\s)\?+(?:\s|$)/u',
        '/\s{2,}/u',
        '/^\s*[\|\-:\/]+/u',
        '/[\|\-:\/]+\s*$/u',
        '/Ã.|â€|Â/u',
    ];

    foreach ($patterns as $pattern) {
        if (preg_match($pattern, $value)) {
            return true;
        }
    }

    return false;
}

function should_write_clean(?string $current, string $proposed, bool $force, bool $onlyMissing): bool
{
    $current = clean($current);

    if (!is_valid_proposed_search_name($proposed)) {
        return false;
    }

    if ($force) {
        return $current !== $proposed;
    }

    if ($onlyMissing) {
        return $current === '';
    }

    return $current === '' || looks_dirty($current);
}

function should_write_tmdb(?string $current, string $proposed, bool $force, bool $onlyMissing): bool
{
    $current = clean($current);

    if (!is_valid_proposed_search_name($proposed)) {
        return false;
    }

    if ($force) {
        return $current !== $proposed;
    }

    if ($onlyMissing) {
        return $current === '';
    }

    return $current === '' || looks_dirty($current);
}

function fetch_rows(PDO $pdo, string $mediaType, int $limit, bool $onlyMissing, bool $includeDirty, ?int $id): array
{
    if ($mediaType === 'series') {
        $where = [];
        if ($id !== null && $id > 0) {
            $where[] = 'id = :id';
        } elseif ($onlyMissing) {
            $where[] = "((clean_search_name IS NULL OR clean_search_name = '') OR (tmdb_search_name IS NULL OR tmdb_search_name = ''))";
        } elseif ($includeDirty) {
            // Broad scan, PHP will decide whether values are dirty.
            $where[] = '1=1';
        } else {
            $where[] = '1=1';
        }

        $sql = "
            SELECT id, name AS raw_title, clean_search_name, tmdb_search_name
            FROM " . DB_CONTENT . ".series
            WHERE " . implode(' AND ', $where) . "
            ORDER BY id ASC
            LIMIT " . (int)$limit;
    } elseif ($mediaType === 'vod') {
        $where = [];
        if ($id !== null && $id > 0) {
            $where[] = 'vod_id = :id';
        } elseif ($onlyMissing) {
            $where[] = "((clean_search_name IS NULL OR clean_search_name = '') OR (tmdb_search_name IS NULL OR tmdb_search_name = ''))";
        } elseif ($includeDirty) {
            $where[] = '1=1';
        } else {
            $where[] = '1=1';
        }

        $sql = "
            SELECT vod_id AS id, title AS raw_title, clean_search_name, tmdb_search_name
            FROM " . DB_CONTENT . ".vod
            WHERE " . implode(' AND ', $where) . "
            ORDER BY vod_id ASC
            LIMIT " . (int)$limit;
    } elseif ($mediaType === 'live') {
        $where = [];
        if ($id !== null && $id > 0) {
            $where[] = 'id = :id';
        } elseif ($onlyMissing) {
            $where[] = "(clean_search_name IS NULL OR clean_search_name = '')";
        } elseif ($includeDirty) {
            $where[] = '1=1';
        } else {
            $where[] = '1=1';
        }

        $sql = "
            SELECT id, name AS raw_title, clean_search_name, NULL AS tmdb_search_name
            FROM " . DB_CONTENT . ".live_channels
            WHERE " . implode(' AND ', $where) . "
            ORDER BY id ASC
            LIMIT " . (int)$limit;
    } else {
        throw new InvalidArgumentException('Unsupported media_type. Use series, vod, or live.');
    }

    $stmt = $pdo->prepare($sql);
    if ($id !== null && $id > 0) {
        $stmt->bindValue(':id', $id, PDO::PARAM_INT);
    }
    $stmt->execute();
    return $stmt->fetchAll(PDO::FETCH_ASSOC) ?: [];
}

function apply_update(PDO $pdo, string $mediaType, int $id, ?string $cleanSearchName, ?string $tmdbSearchName): void
{
    if ($mediaType === 'series') {
        $sets = [];
        $params = [':id' => $id];

        if ($cleanSearchName !== null) {
            $sets[] = 'clean_search_name = :clean_search_name';
            $params[':clean_search_name'] = $cleanSearchName;
        }

        if ($tmdbSearchName !== null) {
            $sets[] = 'tmdb_search_name = :tmdb_search_name';
            $params[':tmdb_search_name'] = $tmdbSearchName;
        }

        if (!$sets) {
            return;
        }

        $sql = "UPDATE " . DB_CONTENT . ".series SET " . implode(', ', $sets) . " WHERE id = :id LIMIT 1";
    } elseif ($mediaType === 'vod') {
        $sets = [];
        $params = [':id' => $id];

        if ($cleanSearchName !== null) {
            $sets[] = 'clean_search_name = :clean_search_name';
            $params[':clean_search_name'] = $cleanSearchName;
        }

        if ($tmdbSearchName !== null) {
            $sets[] = 'tmdb_search_name = :tmdb_search_name';
            $params[':tmdb_search_name'] = $tmdbSearchName;
        }

        if (!$sets) {
            return;
        }

        $sql = "UPDATE " . DB_CONTENT . ".vod SET " . implode(', ', $sets) . " WHERE vod_id = :id LIMIT 1";
    } elseif ($mediaType === 'live') {
        if ($cleanSearchName === null) {
            return;
        }

        $params = [
            ':id' => $id,
            ':clean_search_name' => $cleanSearchName,
        ];
        $sql = "UPDATE " . DB_CONTENT . ".live_channels SET clean_search_name = :clean_search_name WHERE id = :id LIMIT 1";
    } else {
        throw new InvalidArgumentException('Unsupported media_type. Use series, vod, or live.');
    }

    $stmt = $pdo->prepare($sql);
    $stmt->execute($params);
}

try {
    $mediaType = strtolower(clean($_GET['media_type'] ?? ''));
    if (!in_array($mediaType, ['series', 'vod', 'live'], true)) {
        json_out([
            'ok' => false,
            'endpoint_version' => ENDPOINT_VERSION,
            'error' => 'Missing or invalid media_type. Use series, vod, or live.',
        ], 400);
    }

    $limit = max(1, min(500, (int)($_GET['limit'] ?? 50)));
    $id = isset($_GET['id']) && clean($_GET['id']) !== '' ? (int)$_GET['id'] : null;
    $apply = bool_param('apply', false);
    $dryRun = bool_param('dry_run', !$apply);
    $force = bool_param('force', false);
    $onlyMissing = bool_param('only_missing', true);
    $includeDirty = bool_param('include_dirty', true);

    if ($dryRun) {
        $apply = false;
    }

    $pdo = open_pdo();
    $rows = fetch_rows($pdo, $mediaType, $limit, $onlyMissing, $includeDirty, $id);

    $items = [];
    $changed = 0;
    $updated = 0;
    $skipped = 0;

    foreach ($rows as $row) {
        $rowId = (int)$row['id'];
        $rawTitle = clean($row['raw_title'] ?? '');
        $currentClean = clean($row['clean_search_name'] ?? '');
        $currentTmdb = clean($row['tmdb_search_name'] ?? '');

        $proposedClean = normalize_search_name($rawTitle, $mediaType);
        $proposedTmdb = $mediaType === 'live' ? '' : $proposedClean;

        $writeClean = should_write_clean($currentClean, $proposedClean, $force, $onlyMissing);
        $writeTmdb = false;

        if ($mediaType !== 'live') {
            $writeTmdb = should_write_tmdb($currentTmdb, $proposedTmdb, $force, $onlyMissing);
        }

        $dirtyCurrentClean = looks_dirty($currentClean);
        $dirtyCurrentTmdb = $mediaType !== 'live' ? looks_dirty($currentTmdb) : false;

        $willChange = $writeClean || $writeTmdb;

        $item = [
            'id' => $rowId,
            'media_type' => $mediaType,
            'raw_title' => $rawTitle,
            'current_clean_search_name' => $currentClean,
            'proposed_clean_search_name' => $proposedClean,
            'current_tmdb_search_name' => $mediaType === 'live' ? null : $currentTmdb,
            'proposed_tmdb_search_name' => $mediaType === 'live' ? null : $proposedTmdb,
            'dirty_current_clean_search_name' => $dirtyCurrentClean,
            'dirty_current_tmdb_search_name' => $mediaType === 'live' ? null : $dirtyCurrentTmdb,
            'valid_proposed_search_name' => is_valid_proposed_search_name($proposedClean),
            'contains_non_latin_script' => contains_non_latin_script($proposedClean),
            'google_candidate_queries' => build_google_candidate_queries($mediaType, $proposedClean),
            'write_clean_search_name' => $writeClean,
            'write_tmdb_search_name' => $writeTmdb,
            'will_change' => $willChange,
            'applied' => false,
        ];

        if ($willChange) {
            $changed++;

            if ($apply) {
                apply_update(
                    $pdo,
                    $mediaType,
                    $rowId,
                    $writeClean ? $proposedClean : null,
                    $writeTmdb ? $proposedTmdb : null
                );
                $updated++;
                $item['applied'] = true;
            }
        } else {
            $skipped++;
        }

        $items[] = $item;
    }

    json_out([
        'ok' => true,
        'endpoint_version' => ENDPOINT_VERSION,
        'media_type' => $mediaType,
        'dry_run' => $dryRun,
        'apply' => $apply,
        'force' => $force,
        'only_missing' => $onlyMissing,
        'include_dirty' => $includeDirty,
        'limit' => $limit,
        'id' => $id,
        'found_count' => count($rows),
        'changed_count' => $changed,
        'updated_count' => $updated,
        'skipped_count' => $skipped,
        'items' => $items,
    ]);
} catch (Throwable $e) {
    json_out([
        'ok' => false,
        'endpoint_version' => ENDPOINT_VERSION,
        'error' => $e->getMessage(),
    ], 500);
}
