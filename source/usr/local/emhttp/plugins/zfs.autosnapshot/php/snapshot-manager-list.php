<?php
require_once __DIR__ . '/response-helpers.php';
require_once __DIR__ . '/snapshot-manager-helpers.php';

$rows = zfsas_sm_dataset_summary_rows($error);
if ($error !== null) {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => $error,
        'datasets' => [],
    ], 500);
}

zfsas_emit_marked_json([
    'ok' => true,
    'datasets' => $rows,
]);
