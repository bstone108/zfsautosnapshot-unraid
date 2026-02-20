<?php
$debugLogFile = '/var/log/zfs_autosnapshot.log';
$summaryLogFile = '/var/log/zfs_autosnapshot.last.log';

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

function buildPayload($logFile, $logType, $lineCount)
{
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

    return [
        'ok' => true,
        'type' => $logType,
        'exists' => $exists,
        'readable' => $readable,
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
}

list($logType, $logFile) = resolveLogTypeAndFile($_GET['type'] ?? 'summary', $summaryLogFile, $debugLogFile);
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
