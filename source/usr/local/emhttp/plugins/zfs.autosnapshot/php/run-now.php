<?php
$scriptPath = '/usr/local/sbin/zfs_autosnapshot';
$debugLogFile = '/var/log/zfs_autosnapshot.log';

function sendJson($payload, $statusCode = 200)
{
    if (!headers_sent()) {
        http_response_code((int) $statusCode);
        header('Content-Type: application/json; charset=UTF-8');
        header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
        header('Pragma: no-cache');
    }

    echo json_encode($payload);
    exit;
}

if (strtoupper($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    sendJson([
        'ok' => false,
        'error' => 'Use POST for manual run requests.',
    ], 405);
}

if (!is_file($scriptPath) || !is_executable($scriptPath)) {
    sendJson([
        'ok' => false,
        'error' => 'Snapshot script is missing or not executable.',
    ], 500);
}

$command = 'nohup ' . escapeshellarg($scriptPath) . ' >> ' . escapeshellarg($debugLogFile) . ' 2>&1 < /dev/null & echo $!';
$output = [];
$exitCode = 0;
@exec($command, $output, $exitCode);

if ($exitCode !== 0 || count($output) === 0) {
    sendJson([
        'ok' => false,
        'error' => 'Failed to start manual run.',
    ], 500);
}

$pidRaw = trim((string) end($output));
$pid = (preg_match('/^[0-9]+$/', $pidRaw) === 1) ? (int) $pidRaw : 0;

sendJson([
    'ok' => true,
    'pid' => $pid,
    'message' => ($pid > 0)
        ? "Manual run started (PID {$pid})."
        : 'Manual run started.',
]);
