<?php
require_once __DIR__ . '/response-helpers.php';
require_once __DIR__ . '/snapshot-manager-helpers.php';

$dataset = zfsas_sm_trim($_GET['dataset'] ?? '');
if (!zfsas_sm_is_valid_dataset_name($dataset)) {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => 'Invalid dataset name.',
        'snapshots' => [],
    ], 400);
}

$snapshots = zfsas_sm_dataset_snapshots($dataset, $error);
$status = zfsas_sm_read_json_file(zfsas_sm_dataset_status_file($dataset));

if ($error !== null) {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => $error,
        'snapshots' => [],
        'pendingCount' => zfsas_sm_queue_pending_count($dataset),
        'status' => $status,
    ], 500);
}

zfsas_emit_marked_json([
    'ok' => true,
    'dataset' => $dataset,
    'snapshots' => $snapshots,
    'pendingCount' => zfsas_sm_queue_pending_count($dataset),
    'status' => $status,
]);
