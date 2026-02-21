<?php
$debugLogFile = '/var/log/zfs_autosnapshot.log';
$summaryLogFile = '/var/log/zfs_autosnapshot.last.log';

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

function tailFileLines($path, $lineCount, $maxBytes, &$wasTruncated = false)
{
    $wasTruncated = false;

    $lineCount = (int) $lineCount;
    if ($lineCount < 50) {
        $lineCount = 50;
    } elseif ($lineCount > 2000) {
        $lineCount = 2000;
    }

    $maxBytes = (int) $maxBytes;
    if ($maxBytes < 1024) {
        $maxBytes = 1024;
    }

    $output = [];
    $exitCode = 0;
    @exec('tail -n ' . $lineCount . ' ' . escapeshellarg($path) . ' 2>/dev/null', $output, $exitCode);

    if ($exitCode !== 0) {
        return '';
    }

    $text = implode("\n", $output);
    if ($text !== '') {
        $text .= "\n";
    }

    if (strlen($text) > $maxBytes) {
        $text = substr($text, -$maxBytes);
        $wasTruncated = true;
    }

    return $text;
}

function resolveLogTypeAndFile($requestedType, $summaryLogFile, $debugLogFile)
{
    $type = strtolower(trim((string) $requestedType));
    if ($type === 'debug') {
        return ['debug', $debugLogFile];
    }

    return ['summary', $summaryLogFile];
}

function streamLogSection($title, $path)
{
    echo "===== {$title} ({$path}) =====\n";
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

function downloadCombinedLogs($debugLogFile, $summaryLogFile)
{
    if (!headers_sent()) {
        header('Content-Type: text/plain; charset=UTF-8');
        header('Content-Disposition: attachment; filename="zfs_autosnapshot_logs.txt"');
        header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
        header('Pragma: no-cache');
    }

    echo "ZFS Auto Snapshot Log Export\n";
    echo "Generated: " . gmdate('Y-m-d H:i:s') . " UTC\n\n";

    streamLogSection('Debug Log', $debugLogFile);
    echo "\n";
    streamLogSection('Latest Run Summary', $summaryLogFile);
}

list($logType, $logFile) = resolveLogTypeAndFile($_GET['type'] ?? 'summary', $summaryLogFile, $debugLogFile);

$download = isset($_GET['download']) && (string) $_GET['download'] === '1';
if ($download) {
    downloadCombinedLogs($debugLogFile, $summaryLogFile);
    exit;
}

$lineCount = (int) ($_GET['lines'] ?? 400);
$maxBytes = ($logType === 'debug') ? 500000 : 50000;
$exists = is_file($logFile);
$readable = is_readable($logFile);
$mtime = ($exists ? (int) @filemtime($logFile) : 0);
$size = ($exists ? (int) @filesize($logFile) : 0);
$truncated = false;
$content = '';

if ($exists && $readable) {
    $content = tailFileLines($logFile, $lineCount, $maxBytes, $truncated);
}

sendJson([
    'ok' => true,
    'type' => $logType,
    'exists' => $exists,
    'readable' => $readable,
    'mtime' => $mtime,
    'size' => $size,
    'truncated' => $truncated,
    'content' => $content,
]);
