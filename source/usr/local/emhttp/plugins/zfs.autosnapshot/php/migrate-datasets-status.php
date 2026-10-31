<?php
require_once __DIR__ . '/response-helpers.php';
require_once __DIR__ . '/migrate-datasets-helpers.php';

if (!zfsas_migrate_ensure_storage()) {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => 'Dataset migrator storage is unavailable.',
    ], 500);
}

$mode = zfsas_migrate_trim($_GET['mode'] ?? 'status');
if ($mode !== 'scan') {
    $mode = 'status';
}

$selectedDataset = zfsas_migrate_trim($_GET['dataset'] ?? '');
$datasetError = null;
$previewError = null;
$scanMessage = null;
$scanError = null;

// Live status stays on the metadata path: worker state, the dataset dropdown,
// cached folder rows, Docker preflight, and the log tail. Folder walks and
// `du` run only for an explicit scan.
$datasets = zfsas_migrate_list_datasets($datasetError);
$status = zfsas_migrate_current_status();
$scanInProgress = zfsas_migrate_scan_in_progress();
$cached = zfsas_migrate_cached_scan($selectedDataset);
$preview = is_array($cached) ? zfsas_migrate_preview_with_cache_stamp($selectedDataset, $cached['preview']) : null;

if ($mode === 'scan') {
    ignore_user_abort(true);
    set_time_limit(0);

    if ($selectedDataset === '') {
        $scanMessage = 'Choose a dataset first.';
    } else {
        $fresh = zfsas_migrate_run_scan($selectedDataset, $scanError);
        if ($fresh !== null) {
            $preview = zfsas_migrate_preview_with_cache_stamp($selectedDataset, $fresh);
            $scanInProgress = false;
        } elseif ($scanError === 'scan in progress') {
            $scanMessage = 'scan in progress';
            $scanInProgress = true;
            $cached = zfsas_migrate_cached_scan($selectedDataset);
            $preview = is_array($cached) ? zfsas_migrate_preview_with_cache_stamp($selectedDataset, $cached['preview']) : $preview;
        } else {
            $previewError = $scanError;
        }
    }
}

zfsas_emit_marked_json([
    'ok' => true,
    'mode' => $mode,
    'selectedDataset' => $selectedDataset,
    'datasetError' => $datasetError,
    'previewError' => $previewError,
    'scanInProgress' => $scanInProgress,
    'scanMessage' => $scanMessage,
    'datasets' => $datasets,
    'preview' => $preview,
    'status' => $status,
    'docker' => zfsas_migrate_docker_preflight(),
    'logTail' => zfsas_migrate_status_log_tail(40),
]);
