<?php
require_once __DIR__ . '/response-helpers.php';
require_once __DIR__ . '/migrate-datasets-helpers.php';

if (!zfsas_migrate_ensure_storage()) {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => 'Dataset migrator storage is unavailable.',
    ], 500);
}

$selectedDataset = zfsas_migrate_trim($_GET['dataset'] ?? '');
$datasetError = null;
$previewError = null;

$datasets = zfsas_migrate_list_datasets($datasetError);
$preview = null;
if ($selectedDataset !== '') {
    $preview = zfsas_migrate_preview_dataset($selectedDataset, $previewError);
}

zfsas_emit_marked_json([
    'ok' => true,
    'selectedDataset' => $selectedDataset,
    'datasetError' => $datasetError,
    'previewError' => $previewError,
    'datasets' => $datasets,
    'preview' => $preview,
    'status' => zfsas_migrate_current_status(),
    'docker' => zfsas_migrate_docker_preflight(),
    'logTail' => zfsas_migrate_status_log_tail(40),
]);
