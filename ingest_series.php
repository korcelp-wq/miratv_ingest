<?php

set_time_limit(0);
ignore_user_abort(true);
ini_set('memory_limit', '512M');

/* ---------- LOGGING ---------- */

$LOG_FILE = 'C:/miratv_ingest/ingest_series.log';

function logmsg($msg) {
    global $LOG_FILE;
    $line = '[' . date('Y-m-d H:i:s') . '] ' . $msg . "\r\n";
    file_put_contents($LOG_FILE, $line, FILE_APPEND);
    echo $line;
}

/* ---------- LOCKING ---------- */

$lockFile = 'C:/miratv_ingest/ingest_series.lock';
$lock = fopen($lockFile, 'c');

if (!$lock || !flock($lock, LOCK_EX | LOCK_NB)) {
    logmsg('Another ingest is already running. Exiting.');
    exit;
}

/* ---------- CONFIG ---------- */

$provider = 'eldervpn';

$baseUrl  = 'http://uxurwymd.eldervpn.xyz:8080';
$username = 'Marina2025';
$password = '3KY586YR';

$dbHost = 'http://ams-business-4.hostwindsdns.com:2083';
$dbUser = 'xpdgxfsp_ingest_remomte';
$dbPass = 'IWs^oXasV)lL';
$dbName = 'xpdgxfsp_content';
$dbPort = 3306;

/* ---------- DB CONNECT ---------- */

$db = @mysqli_connect($dbHost, $dbUser, $dbPass, $dbName, $dbPort);

if (!$db) {
    logmsg('DB connection failed: ' . mysqli_connect_error());
    exit;
}

mysqli_set_charset($db, 'utf8mb4');

/* ---------- API HELPER ---------- */

function api_get($url) {
    $ctx = stream_context_create(array(
        'http' => array('timeout' => 60)
    ));
    $json = @file_get_contents($url, false, $ctx);
    if ($json === false) return null;
    return json_decode($json, true);
}

/* ---------- INGEST ---------- */

logmsg('=== SERIES INGEST START ===');

$seriesUrl = $GLOBALS['baseUrl']
    . '/player_api.php?username=' . $GLOBALS['username']
    . '&password=' . $GLOBALS['password']
    . '&action=get_series';

$seriesList = api_get($seriesUrl);

if (!is_array($seriesList)) {
    logmsg('ERROR: Failed to fetch series list');
    exit;
}

logmsg('Series count: ' . count($seriesList));

logmsg('=== SERIES INGEST COMPLETE ===');

/* ---------- CLEANUP ---------- */

flock($lock, LOCK_UN);
fclose($lock);
