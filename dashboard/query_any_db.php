<?php
// Proxy to query any MiraTV database using dog_open.php
$token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY";
$endpoint = "https://miratv.club/_workers/api/series/dog_open.php";

// Accept JSON POST with: { "db": "database_name", "sql": "SQL QUERY" }
$input = json_decode(file_get_contents('php://input'), true);
$db = $input['db'] ?? '';
$sql = $input['sql'] ?? '';

if (!$db || !$sql) {
    http_response_code(400);
    echo json_encode(["error" => "Missing db or sql"]);
    exit;
}

$body = json_encode([
    "token" => $token,
    "db" => $db,
    "sql" => $sql,
    "params" => []
]);

$ch = curl_init($endpoint);
curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
curl_setopt($ch, CURLOPT_POST, true);
curl_setopt($ch, CURLOPT_POSTFIELDS, $body);
curl_setopt($ch, CURLOPT_HTTPHEADER, ['Content-Type: application/json']);

$response = curl_exec($ch);
$httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
curl_close($ch);

http_response_code($httpCode);
header('Content-Type: application/json');
echo $response;
