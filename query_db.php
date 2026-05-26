<?php
// TODO: Use this endpoint to query all stored procedures in the relevant DBs, find the one returning categories, and ensure the result includes a 'name' field for each category.
// query_db.php - Simple SQL query runner for debugging (returns full result set as JSON)
// Usage: POST db, sql

header('Content-Type: application/json');

$dbs = [
    'lake_knowledge' => 'xpdgxfsp_lake_knowledge',
    'lake_vector' => 'xpdgxfsp_lake_vector',
    'content' => 'xpdgxfsp_content',
    'cortex' => 'xpdgxfsp_cortex',
    'callosum_matrix' => 'xpdgxfsp_callosum_matrix',
    'ops' => 'xpdgxfsp_ops',
    'inhibitor_govenor_matrix' => 'xpdgxfsp_inhibitor_govenor_matrix',
    'i_m_g_vector_context' => 'xpdgxfsp_i_m_g_vector_context',
];

$dbkey = $_POST['db'] ?? '';
$sql = $_POST['sql'] ?? '';

if (!isset($dbs[$dbkey]) || !$sql) {
    echo json_encode(['error' => 'Missing or invalid db/sql']);
    exit;
}

$dbname = $dbs[$dbkey];
$user = 'xpdgxfsp';
$pass = '5567Lke???0302';
$dsn = "mysql:host=localhost;dbname=$dbname;charset=utf8mb4";

try {
    $pdo = new PDO($dsn, $user, $pass, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
    ]);
    $stmt = $pdo->query($sql);
    $rows = $stmt->fetchAll();
    echo json_encode(['result' => $rows]);
} catch (Exception $e) {
    echo json_encode(['error' => $e->getMessage()]);
}
