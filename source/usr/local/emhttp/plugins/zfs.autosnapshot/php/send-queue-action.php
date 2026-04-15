<?php
require_once __DIR__ . '/response-helpers.php';
require_once __DIR__ . '/send-queue-helpers.php';

if (strtoupper($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => 'Use POST for send queue actions.',
    ], 405);
}

if (!zfsas_ops_ensure_storage_dirs()) {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => 'ZFS send queue storage is unavailable.',
    ], 500);
}

$action = trim((string) ($_POST['action'] ?? ''));
if ($action !== 'retry') {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => 'Unknown send queue action.',
    ], 400);
}

$jobId = trim((string) ($_POST['job_id'] ?? ''));
if ($jobId === '') {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => 'Job id is required.',
    ], 400);
}

$error = null;
if (!zfsas_ops_retry_send_job($jobId, $error)) {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => $error ?: 'Unable to retry the selected send job.',
    ], 400);
}

$kickError = null;
zfsas_ops_start_queue_kicker($kickError);

zfsas_emit_marked_json([
    'ok' => true,
    'message' => 'Send job queued for retry.',
]);
