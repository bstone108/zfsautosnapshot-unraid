<?php
require_once __DIR__ . '/response-helpers.php';
require_once __DIR__ . '/recovery-helpers.php';

if (!zfsas_recovery_ensure_storage()) {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => 'Recovery tool storage is unavailable.',
    ], 500);
}

$datasets = zfsas_recovery_list_datasets($datasetError);
$poolStatus = zfsas_recovery_pool_status();

zfsas_emit_marked_json([
    'ok' => true,
    'datasetError' => $datasetError,
    'datasets' => $datasets,
    'pools' => $poolStatus['pools'] ?? [],
    'poolError' => $poolStatus['error'] ?? null,
    'scans' => zfsas_recovery_list_scans(),
]);
