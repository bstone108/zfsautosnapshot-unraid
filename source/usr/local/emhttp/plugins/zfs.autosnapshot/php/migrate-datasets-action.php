<?php
require_once __DIR__ . '/response-helpers.php';
require_once __DIR__ . '/migrate-datasets-helpers.php';

if (strtoupper($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => 'Use POST for dataset migrator actions.',
    ], 405);
}

$action = zfsas_migrate_trim($_POST['action'] ?? '');
if ($action !== 'start') {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => 'Unknown dataset migrator action.',
    ], 400);
}

$dataset = zfsas_migrate_trim($_POST['dataset'] ?? '');
$error = null;
if (!zfsas_migrate_start($dataset, $error)) {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => $error ?: 'Unable to start the dataset migrator.',
    ], 400);
}

zfsas_emit_marked_json([
    'ok' => true,
    'message' => 'Dataset migration started for ' . $dataset . '.',
]);
