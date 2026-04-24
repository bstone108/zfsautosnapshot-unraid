<?php
require_once __DIR__ . '/response-helpers.php';
require_once __DIR__ . '/send-queue-helpers.php';

if (!zfsas_ops_ensure_storage_dirs()) {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => 'ZFS send queue storage is unavailable.',
    ], 500);
}

zfsas_emit_marked_json(zfsas_ops_send_queue_status_payload(120));
