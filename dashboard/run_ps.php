<?php
// Simple proxy to run PowerShell commands
$data = json_decode(file_get_contents('php://input'), true);
$command = $data['command'] ?? '';

// Security: only allow specific commands
$allowed = [
    '.\Query.ps1'
];

// Basic validation
if (!str_contains($command, '.\Query.ps1')) {
    http_response_code(403);
    echo json_encode(['success' => false, 'error' => 'Command not allowed']);
    exit;
}

// Run PowerShell
$output = shell_exec("powershell -Command \"$command\" 2>&1");

echo json_encode([
    'success' => true,
    'output' => $output
]);
?>