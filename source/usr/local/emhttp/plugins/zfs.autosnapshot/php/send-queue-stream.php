<?php
require_once __DIR__ . '/send-queue-helpers.php';

function zfsas_send_stream_emit($event, $payload)
{
    echo 'event: ' . $event . "\n";
    echo 'data: ' . json_encode($payload, JSON_UNESCAPED_SLASHES) . "\n\n";
    @ob_flush();
    flush();
}

@ini_set('zlib.output_compression', '0');
@ini_set('output_buffering', '0');
@set_time_limit(0);
ignore_user_abort(true);

header('Content-Type: text/event-stream');
header('Cache-Control: no-cache, no-store, must-revalidate');
header('Pragma: no-cache');
header('Expires: 0');
header('X-Accel-Buffering: no');

while (ob_get_level() > 0) {
    @ob_end_flush();
}
ob_implicit_flush(true);

echo "retry: 2000\n\n";

if (!zfsas_ops_ensure_storage_dirs()) {
    zfsas_send_stream_emit('queue', [
        'ok' => false,
        'error' => 'ZFS send queue storage is unavailable.',
        'jobs' => [],
        'pendingDeleteCount' => 0,
    ]);
    exit;
}

$lastHash = '';
$lastHeartbeat = time();

while (!connection_aborted()) {
    clearstatcache();
    $payload = zfsas_ops_send_queue_status_payload(120);
    $encoded = json_encode($payload, JSON_UNESCAPED_SLASHES);
    $hash = sha1((string) $encoded);
    $now = time();

    if ($hash !== $lastHash) {
        echo "event: queue\n";
        echo 'data: ' . $encoded . "\n\n";
        @ob_flush();
        flush();
        $lastHash = $hash;
        $lastHeartbeat = $now;
    } elseif (($now - $lastHeartbeat) >= 15) {
        zfsas_send_stream_emit('heartbeat', [
            'ok' => true,
            'ts' => $now,
        ]);
        $lastHeartbeat = $now;
    }

    sleep(1);
}
