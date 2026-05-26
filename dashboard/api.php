<?php
// Simple local proxy to avoid CORS
$token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY";
$endpoint = "https://miratv.club/_workers/api/series/dog_open.php";

$body = file_get_contents('php://input');

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
?>