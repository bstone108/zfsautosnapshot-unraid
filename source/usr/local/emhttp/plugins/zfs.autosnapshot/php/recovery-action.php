<?php
require_once __DIR__ . '/response-helpers.php';
require_once __DIR__ . '/recovery-helpers.php';

if (strtoupper($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => 'Use POST for recovery tool actions.',
    ], 405);
}

$csrfError = null;
if (!zfsas_validate_csrf_token($csrfError)) {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => $csrfError,
    ], 403);
}

if (!zfsas_recovery_ensure_storage()) {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => 'Recovery tool storage is unavailable.',
    ], 500);
}

$action = zfsas_recovery_trim($_POST['action'] ?? '');
if ($action === 'start_scan') {
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
}

if ($action === 'perform_recovery_action') {
    $datasetError = null;
    $datasetRows = zfsas_recovery_list_datasets($datasetError);
    if ($datasetError !== null) {
        zfsas_emit_marked_json([
            'ok' => false,
            'error' => $datasetError,
        ], 500);
    }

    $error = null;
    $result = zfsas_recovery_perform_guarded_action($_POST, $datasetRows, zfsas_recovery_read_send_jobs(), $error);
    if (!is_array($result) || ($result['ok'] ?? false) !== true) {
        zfsas_emit_marked_json([
            'ok' => false,
            'error' => $error ?: 'Unable to perform the guarded recovery action.',
        ], 400);
    }

    zfsas_emit_marked_json($result);
}

zfsas_emit_marked_json([
    'ok' => false,
    'error' => 'Unknown recovery tool action.',
], 400);
