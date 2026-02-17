<?php
$logFile = '/var/log/zfs_autosnapshot.log';

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

$lineCount = (int) ($_GET['lines'] ?? 400);
$exists = is_file($logFile);
$readable = is_readable($logFile);
$mtime = ($exists ? (int) @filemtime($logFile) : 0);
$size = ($exists ? (int) @filesize($logFile) : 0);
$truncated = false;
$content = '';

if ($exists && $readable) {
    $content = tailFileLines($logFile, $lineCount, 200000, $truncated);
}

sendJson([
    'ok' => true,
    'exists' => $exists,
    'readable' => $readable,
    'mtime' => $mtime,
    'size' => $size,
    'truncated' => $truncated,
    'content' => $content,
]);
