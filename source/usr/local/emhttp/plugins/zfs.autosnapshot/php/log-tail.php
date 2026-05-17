<?php
require_once __DIR__ . '/log-helpers.php';

$debugLogFile = '/var/log/zfs_autosnapshot.log';
$debugArchiveLogFile = '/var/log/zfs_autosnapshot.archive.log';
$summaryLogFile = '/var/log/zfs_autosnapshot.last.log';

function sendJson($payload, $statusCode = 200)
{
    if (!headers_sent()) {
        http_response_code((int) $statusCode);
        header('Content-Type: application/json; charset=UTF-8');
        header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
        header('Pragma: no-cache');
        header('X-Content-Type-Options: nosniff');
    }

    echo json_encode($payload);
    exit;
}

function streamLogSection($title, $path)
{
    echo "===== {$title} =====\n";
    if (!zfsas_log_is_safe_path($path)) {
        echo "Log file path is unavailable because it failed safety checks.\n";
        return;
    }
    if (!is_file($path)) {
        echo "Log file is not present.\n";
        return;
    }
    if (!is_readable($path)) {
        echo "Log file exists but is not readable.\n";
        return;
    }
    readfile($path);
    if (@filesize($path) > 0) {
        echo "\n";
    }
}

function downloadCombinedLogs($debugLogFile, $debugArchiveLogFile, $summaryLogFile)
{
    if (!headers_sent()) {
        header('Content-Type: text/plain; charset=UTF-8');
        header('Content-Disposition: attachment; filename="zfs_autosnapshot_logs.txt"');
        header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
        header('Pragma: no-cache');
        header('X-Content-Type-Options: nosniff');
    }

    echo "ZFS Auto Snapshot Log Export\n";
    echo "Generated: " . gmdate('Y-m-d H:i:s') . " UTC\n\n";

    streamLogSection('Archived Debug Log', $debugArchiveLogFile);
    echo "\n";
    streamLogSection('Debug Log', $debugLogFile);
    echo "\n";
    streamLogSection('Latest Run Summary', $summaryLogFile);
}

list($logType, $logFile) = zfsas_log_resolve_type_and_file($_GET['type'] ?? 'summary', $summaryLogFile, $debugLogFile);

$download = isset($_GET['download']) && (string) $_GET['download'] === '1';
if ($download) {
    downloadCombinedLogs($debugLogFile, $debugArchiveLogFile, $summaryLogFile);
    exit;
}

$lineCount = (int) ($_GET['lines'] ?? 400);
$maxBytes = ($logType === 'debug') ? 500000 : 50000;
$safe = zfsas_log_is_safe_path($logFile);
$exists = ($safe && is_file($logFile));
$readable = ($exists && is_readable($logFile));
$mtime = ($exists ? (int) @filemtime($logFile) : 0);
$size = ($exists ? (int) @filesize($logFile) : 0);
$truncated = false;
$content = '';

if ($exists && $readable) {
    $content = zfsas_log_tail_file_lines($logFile, $lineCount, $maxBytes, $truncated);
}

sendJson([
    'ok' => true,
    'type' => $logType,
    'exists' => $exists,
    'readable' => $readable,
    'unsafe' => !$safe,
    'mtime' => $mtime,
    'size' => $size,
    'truncated' => $truncated,
    'content' => $content,
]);
