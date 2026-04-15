<?php
require_once __DIR__ . '/response-helpers.php';
require_once __DIR__ . '/recovery-helpers.php';

if (strtoupper($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => 'Use POST for recovery tool actions.',
    ], 405);
}

if (!zfsas_recovery_ensure_storage()) {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => 'Recovery tool storage is unavailable.',
    ], 500);
}

$action = zfsas_recovery_trim($_POST['action'] ?? '');
if ($action !== 'start_scan') {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => 'Unknown recovery tool action.',
    ], 400);
}

$dataset = zfsas_recovery_trim($_POST['dataset'] ?? '');
$error = null;
if (!zfsas_recovery_start_scan($dataset, $error)) {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => $error ?: 'Unable to start the diagnostic scan.',
    ], 400);
}

zfsas_emit_marked_json([
    'ok' => true,
    'message' => 'Manual readability scan started for ' . $dataset . '.',
]);
