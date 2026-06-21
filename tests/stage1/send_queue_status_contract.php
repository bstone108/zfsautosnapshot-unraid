<?php
require_once __DIR__ . '/../../source/usr/local/emhttp/plugins/zfs.autosnapshot/php/send-queue-helpers.php';

function assert_true($condition, $message) {
    if (!$condition) {
        fwrite(STDERR, "FAIL: {$message}\n");
        exit(1);
    }
}

function rrmdir($dir) {
    if (!is_dir($dir)) {
        return;
    }
    $items = scandir($dir);
    if (!is_array($items)) {
        return;
    }
    foreach ($items as $item) {
        if ($item === '.' || $item === '..') {
            continue;
        }
        $path = $dir . '/' . $item;
        if (is_dir($path) && !is_link($path)) {
            rrmdir($path);
        } else {
            @unlink($path);
        }
    }
    @rmdir($dir);
}

function write_send_job($epoch, $id, $action, $state, $phase, $source, $destination, $message = '') {
    $job = [
        'JOB_ID' => $id,
        'JOB_TYPE' => 'send',
        'JOB_MODE' => 'scheduled',
        'JOB_ACTION' => $action,
        'STATE' => $state,
        'PHASE' => $phase,
        'REQUESTED_EPOCH' => (string) $epoch,
        'REQUESTED_AT' => '2026-06-21T10:00:00Z',
        'QUEUE_SORT' => (string) $epoch,
        'SCHEDULE_JOB_ID' => 'feedfacecafe',
        'SOURCE_ROOT' => $source,
        'DESTINATION_ROOT' => $destination,
        'LAST_MESSAGE' => $message,
        'LAST_ERROR' => '',
        'PROGRESS_PERCENT' => '5',
    ];
    $path = zfsas_ops_job_path($id, $epoch);
    assert_true(zfsas_ops_write_job_file($path, $job), "unable to write {$id}");
}

$root = zfsas_ops_root_dir();
$backup = null;
if (is_dir($root)) {
    $backup = $root . '.stage1-backup-' . getmypid() . '-' . bin2hex(random_bytes(4));
    assert_true(@rename($root, $backup), 'unable to isolate existing ops root for queue status contract');
}

try {
    assert_true(zfsas_ops_ensure_storage_dirs(), 'unable to create isolated ops dirs');

    write_send_job(1000, 'send-child-feedfacecafe-manual-1000-0', 'send_member', 'running', 'sending', 'source/data', 'backup/data', 'Sending.');
    write_send_job(1000, 'finalize-feedfacecafe-manual-1000', 'finalize', 'retry_wait', 'retry_wait', 'source/data', 'backup/data', 'Waiting for children.');
    write_send_job(1000, 'send-pool-prep-backup-manual-1000', 'pool_prep', 'running', 'preparing', 'backup', 'backup', 'Running destination pool prep.');
    write_send_job(1001, 'finalize-feedfacecafe-manual-1001', 'finalize', 'failed', 'failed', 'source/data', 'backup/data', 'Finalizer failed.');

    $payload = zfsas_ops_send_queue_status_payload(20);
    $ids = array_map(function ($row) { return $row['id']; }, $payload['jobs']);

    assert_true(in_array('send-child-feedfacecafe-manual-1000-0', $ids, true), 'active child send should remain visible in the queue');
    assert_true(!in_array('finalize-feedfacecafe-manual-1000', $ids, true), 'routine waiting finalizer should not appear as an extra queue row beside the child send');
    assert_true(!in_array('send-pool-prep-backup-manual-1000', $ids, true), 'routine pool-prep coordinator should not appear as an extra queue row beside the send');
    assert_true(in_array('finalize-feedfacecafe-manual-1001', $ids, true), 'failed coordinator jobs should remain visible so users can clear or inspect them');
} finally {
    rrmdir($root);
    if ($backup !== null && is_dir($backup)) {
        @rename($backup, $root);
    }
}

printf("PASS: send queue status coordinator visibility contract\n");
