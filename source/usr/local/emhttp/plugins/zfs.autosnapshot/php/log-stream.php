<?php
require_once __DIR__ . '/log-helpers.php';

$debugLogFile = '/var/log/zfs_autosnapshot.log';
$summaryLogFile = '/var/log/zfs_autosnapshot.last.log';

function buildPayload($logFile, $logType, $lineCount)
{
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

    return [
        'ok' => true,
        'type' => $logType,
        'exists' => $exists,
        'readable' => $readable,
        'unsafe' => !$safe,
        'mtime' => $mtime,
        'size' => $size,
        'truncated' => $truncated,
        'content' => $content,
    ];
}

function sendEvent($event, $payload)
{
    echo 'event: ' . $event . "\n";
    echo 'data: ' . json_encode($payload) . "\n\n";
    @ob_flush();
    @flush();
}

ignore_user_abort(true);
@set_time_limit(0);

if (!headers_sent()) {
    header('Content-Type: text/event-stream; charset=UTF-8');
    header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
    header('Pragma: no-cache');
    header('Connection: keep-alive');
    header('X-Accel-Buffering: no');
    header('X-Content-Type-Options: nosniff');
}

list($logType, $logFile) = zfsas_log_resolve_type_and_file($_GET['type'] ?? 'summary', $summaryLogFile, $debugLogFile);
$lineCount = (int) ($_GET['lines'] ?? 400);

$maxSeconds = 55;
$startedAt = time();
$lastFingerprint = '';

while (true) {
    if (connection_aborted()) {
        break;
    }

    $payload = buildPayload($logFile, $logType, $lineCount);
    $fingerprint = (string) ($payload['mtime'] ?? 0)
        . ':' . (string) ($payload['size'] ?? 0)
        . ':' . strlen((string) ($payload['content'] ?? ''))
        . ':' . md5((string) ($payload['content'] ?? ''));

    if ($fingerprint !== $lastFingerprint) {
        sendEvent('payload', $payload);
        $lastFingerprint = $fingerprint;
    } else {
        sendEvent('ping', ['ts' => time()]);
    }

    if ((time() - $startedAt) >= $maxSeconds) {
        break;
    }

    sleep(1);
}
