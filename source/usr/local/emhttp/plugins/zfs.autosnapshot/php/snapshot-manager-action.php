<?php
require_once __DIR__ . '/response-helpers.php';
require_once __DIR__ . '/snapshot-manager-helpers.php';

function zfsas_sm_json_error($message, $status = 400, $extra = [])
{
    $payload = array_merge([
        'ok' => false,
        'error' => $message,
    ], $extra);
    zfsas_emit_marked_json($payload, $status);
}

function zfsas_sm_write_operation_file($dataset, $operation, $sortKey, $index)
{
    $queueDir = zfsas_sm_dataset_queue_dir($dataset);
    if (!zfsas_sm_ensure_dir($queueDir)) {
        return false;
    }

    $action = preg_replace('/[^a-z0-9_]+/i', '-', (string) ($operation['action'] ?? 'op'));
    $filename = sprintf('%016d-%03d-%s.op', (int) $sortKey, (int) $index, $action);
    $path = $queueDir . '/' . $filename;

    $lines = [];
    foreach ($operation as $key => $value) {
        $key = strtoupper((string) $key);
        if (!preg_match('/^[A-Z0-9_]+$/', $key)) {
            continue;
        }

        $text = str_replace('\\', '\\\\', (string) $value);
        $text = str_replace('"', '\\"', $text);
        $lines[] = $key . '="' . $text . '"';
    }

    $written = @file_put_contents($path, implode(PHP_EOL, $lines) . PHP_EOL);
    if ($written === false) {
        return false;
    }

    @chmod($path, 0664);
    zfsas_sm_apply_owner($path);
    return true;
}

if (strtoupper($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    zfsas_sm_json_error('Use POST for snapshot manager actions.', 405);
}

if (!zfsas_sm_ensure_storage_dirs()) {
    zfsas_sm_json_error('Snapshot manager storage directories are unavailable.', 500);
}

$action = zfsas_sm_trim($_POST['action'] ?? '');
$dataset = zfsas_sm_trim($_POST['dataset'] ?? '');
if (!zfsas_sm_is_valid_dataset_name($dataset)) {
    zfsas_sm_json_error('Invalid dataset name.');
}

$knownActions = ['take_snapshot', 'delete', 'hold', 'release', 'rollback', 'send'];
if (!in_array($action, $knownActions, true)) {
    zfsas_sm_json_error('Unknown snapshot manager action.');
}

$snapshotRows = zfsas_sm_dataset_snapshots($dataset, $snapshotError);
if ($snapshotError !== null) {
    zfsas_sm_json_error($snapshotError, 500);
}

$snapshotMap = [];
foreach ($snapshotRows as $row) {
    $snapshotMap[$row['snapshot']] = $row;
}

$selectedSnapshots = [];
if (isset($_POST['snapshots'])) {
    $rawSnapshots = is_array($_POST['snapshots']) ? $_POST['snapshots'] : [$_POST['snapshots']];
    foreach ($rawSnapshots as $value) {
        $snapshot = zfsas_sm_trim($value);
        if ($snapshot === '' || isset($selectedSnapshots[$snapshot])) {
            continue;
        }
        $selectedSnapshots[$snapshot] = true;
    }
}
$selectedSnapshots = array_keys($selectedSnapshots);

$immediateActions = ['take_snapshot', 'rollback'];
$isImmediate = in_array($action, $immediateActions, true);
if ($isImmediate && (zfsas_sm_dataset_busy($dataset) || zfsas_sm_queue_pending_count($dataset) > 0)) {
    zfsas_sm_json_error('This dataset already has pending snapshot-manager work. Let it finish first, then retry the immediate action.', 409, [
        'pendingCount' => zfsas_sm_queue_pending_count($dataset),
    ]);
}

$operations = [];
$requestedAt = date('c');
$requestedEpoch = time();

if ($action === 'take_snapshot') {
    $snapshotName = zfsas_sm_trim($_POST['snapshot_name'] ?? '');
    if ($snapshotName === '') {
        zfsas_sm_json_error('Snapshot name is required.');
    }
    if (!zfsas_sm_is_valid_snapshot_name($snapshotName)) {
        zfsas_sm_json_error('Snapshot name contains unsupported characters.');
    }

    $fullSnapshot = $dataset . '@' . $snapshotName;
    if (isset($snapshotMap[$fullSnapshot])) {
        zfsas_sm_json_error('That snapshot already exists on the selected dataset.');
    }

    $operations[] = [
        'action' => $action,
        'action_label' => zfsas_sm_action_label($action),
        'dataset' => $dataset,
        'snapshot' => $fullSnapshot,
        'snapshot_name' => $snapshotName,
        'requested_at' => $requestedAt,
        'requested_epoch' => $requestedEpoch,
    ];
} else {
    if (count($selectedSnapshots) === 0) {
        zfsas_sm_json_error('Choose at least one snapshot first.');
    }

    $ordered = [];
    foreach ($selectedSnapshots as $snapshot) {
        if (!isset($snapshotMap[$snapshot])) {
            zfsas_sm_json_error('One or more selected snapshots no longer exist. Refresh the snapshot list and try again.');
        }
        $ordered[] = $snapshotMap[$snapshot];
    }

    usort($ordered, function ($a, $b) {
        return ((int) ($a['createdEpoch'] ?? 0)) <=> ((int) ($b['createdEpoch'] ?? 0));
    });

    if ($action === 'send') {
        if (count($ordered) !== 1) {
            zfsas_sm_json_error('Send works on one snapshot at a time.');
        }

        $destination = zfsas_sm_trim($_POST['destination'] ?? '');
        if (!zfsas_sm_is_valid_dataset_name($destination)) {
            zfsas_sm_json_error('Destination dataset is invalid.');
        }
        if ($destination === $dataset) {
            zfsas_sm_json_error('Destination dataset must be different from the source dataset.');
        }
        if (strpos($destination, '/') === false) {
            zfsas_sm_json_error('Destination dataset must include a dataset below a pool root.');
        }

        $row = $ordered[0];
        $error = null;
        if (!zfsas_ops_enqueue_manual_send(
            $dataset,
            $row['snapshot'],
            $row['snapshotName'],
            $destination,
            (int) $row['createdEpoch'],
            $error
        )) {
            zfsas_sm_json_error($error ?: 'Unable to queue the one-off send.', 409);
        }

        $kickError = null;
        zfsas_ops_start_queue_kicker($kickError);

        zfsas_emit_marked_json([
            'ok' => true,
            'dataset' => $dataset,
            'message' => 'One-off send queued for ' . $dataset . '.',
            'pendingCount' => zfsas_sm_queue_pending_count($dataset) + (int) (zfsas_ops_queue_pending_counts_by_dataset()[$dataset] ?? 0),
        ]);
    } else {
        foreach ($ordered as $row) {
            if (!empty($row['sendProtected']) && $action === 'rollback') {
                zfsas_sm_json_error('Send-chain snapshots are protected from delete and rollback in Snapshot Manager.', 409);
            }

            $operations[] = [
                'action' => $action,
                'action_label' => zfsas_sm_action_label($action),
                'dataset' => $dataset,
                'snapshot' => $row['snapshot'],
                'snapshot_name' => $row['snapshotName'],
                'snapshot_epoch' => (int) $row['createdEpoch'],
                'requested_at' => $requestedAt,
                'requested_epoch' => $requestedEpoch,
            ];
        }
    }
}

if ($action === 'rollback' && count($operations) !== 1) {
    zfsas_sm_json_error('Rollback works on one snapshot at a time.');
}

if ($action === 'delete') {
    $forceCheckpointDelete = (($_POST['confirm_send_delete'] ?? '') === '1');
    $queuedCount = 0;

    foreach ($operations as $index => $operation) {
        $row = $snapshotMap[$operation['snapshot']] ?? null;
        if (!is_array($row)) {
            zfsas_sm_json_error('One or more selected snapshots no longer exist. Refresh the snapshot list and try again.');
        }

        if (!empty($row['sendProtected']) && !$forceCheckpointDelete) {
            zfsas_sm_json_error('Deleting a send-managed checkpoint requires confirmation because it can disrupt future replication if used carelessly.', 409);
        }

        $error = null;
        if (!zfsas_ops_enqueue_snapshot_delete($dataset, $row, $forceCheckpointDelete, $error)) {
            zfsas_sm_json_error($error ?: 'Unable to queue the snapshot deletion.', 500);
        }
        $queuedCount++;
    }

    $kickError = null;
    zfsas_ops_start_queue_kicker($kickError);

    zfsas_emit_marked_json([
        'ok' => true,
        'dataset' => $dataset,
        'message' => $queuedCount . ' snapshot deletion(s) queued for ' . $dataset . '.',
        'pendingCount' => zfsas_sm_queue_pending_count($dataset) + (int) (zfsas_ops_queue_pending_counts_by_dataset()[$dataset] ?? 0),
    ]);
}

foreach ($operations as $index => $operation) {
    $sortKey = $isImmediate
        ? (int) (($requestedEpoch * 1000) + $index)
        : (int) (($operation['snapshot_epoch'] ?? $requestedEpoch) * 1000 + $index);
    if (!zfsas_sm_write_operation_file($dataset, $operation, $sortKey, $index)) {
        zfsas_sm_json_error('Unable to queue snapshot manager operation files.', 500);
    }
}

if (!zfsas_sm_start_worker($dataset, $workerError)) {
    zfsas_sm_json_error($workerError ?: 'Unable to start the snapshot manager worker.', 500);
}

$pendingCount = zfsas_sm_queue_pending_count($dataset);
$message = $isImmediate
    ? zfsas_sm_action_label($action) . ' started for ' . $dataset . '.'
    : count($operations) . ' snapshot action(s) queued for ' . $dataset . '.';

zfsas_emit_marked_json([
    'ok' => true,
    'dataset' => $dataset,
    'message' => $message,
    'pendingCount' => $pendingCount,
]);
