<?php
require_once __DIR__ . '/response-helpers.php';
require_once __DIR__ . '/send-helpers.php';
require_once __DIR__ . '/send-queue-helpers.php';

$configPath = '/boot/config/plugins/zfs.autosnapshot/zfs_send.conf';
$defaults = [
    'SEND_SNAPSHOT_PREFIX' => 'zfs-send-',
    'SEND_MAX_PARALLEL' => '1',
    'SEND_JOBS' => '',
];

if (strtoupper($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => 'Use POST for manual ZFS send requests.',
    ], 405);
}

$csrfError = null;
if (!zfsas_validate_csrf_token($csrfError)) {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => $csrfError,
    ], 403);
}

if (!zfsas_ops_ensure_storage_dirs()) {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => 'ZFS send queue storage is unavailable.',
    ], 500);
}

$config = zfsas_send_parse_config_file($configPath, $defaults);
$warnings = [];
$errors = [];
$jobs = zfsas_send_parse_jobs($config['SEND_JOBS'] ?? '', $errors, $warnings);

if (!empty($errors)) {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => $errors[0],
    ], 400);
}

if (count($jobs) === 0) {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => 'No scheduled ZFS send jobs are configured yet.',
    ], 409);
}

$kickError = null;
if (!zfsas_ops_start_queue_kicker($kickError, ['--manual-now'])) {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => $kickError ?: 'Unable to queue a manual ZFS send run.',
    ], 500);
}

zfsas_emit_marked_json([
    'ok' => true,
    'message' => 'Manual ZFS send queue kick started. Scheduled send jobs due for this run are being enqueued.',
    'jobCount' => count($jobs),
]);
