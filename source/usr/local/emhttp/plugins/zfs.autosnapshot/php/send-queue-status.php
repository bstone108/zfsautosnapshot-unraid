<?php
require_once __DIR__ . '/response-helpers.php';
require_once __DIR__ . '/send-queue-helpers.php';

if (!zfsas_ops_ensure_storage_dirs()) {
    zfsas_emit_marked_json([
        'ok' => false,
        'error' => 'ZFS send queue storage is unavailable.',
    ], 500);
}

$rows = [];
foreach (zfsas_ops_recent_send_jobs(120) as $job) {
    $rows[] = [
        'id' => (string) ($job['JOB_ID'] ?? ''),
        'mode' => (string) ($job['JOB_MODE'] ?? ''),
        'action' => (string) ($job['JOB_ACTION'] ?? ''),
        'typeLabel' => zfsas_ops_send_job_type_label($job),
        'state' => (string) ($job['STATE'] ?? ''),
        'phase' => (string) ($job['PHASE'] ?? ''),
        'stateLabel' => zfsas_ops_send_job_state_label($job),
        'source' => (string) ($job['SOURCE_ROOT'] ?? $job['DATASET'] ?? ''),
        'destination' => (string) ($job['DESTINATION_ROOT'] ?? ''),
        'includeChildren' => ((string) ($job['INCLUDE_CHILDREN'] ?? '0') === '1'),
        'requestedAt' => (string) ($job['REQUESTED_AT'] ?? ''),
        'lastMessage' => (string) ($job['LAST_MESSAGE'] ?? ''),
        'lastError' => (string) ($job['LAST_ERROR'] ?? ''),
        'progress' => zfsas_ops_send_job_progress_percent($job),
        'retryAt' => (string) ($job['RETRY_AT'] ?? '0'),
        'canRetry' => ((string) ($job['STATE'] ?? '') === 'failed' && (string) ($job['CANCELLED_BY_USER'] ?? '0') !== '1'),
        'canClear' => ((string) ($job['STATE'] ?? '') === 'failed'),
        'canCancel' => in_array((string) ($job['STATE'] ?? ''), ['queued', 'running', 'retry_wait'], true),
    ];
}

zfsas_emit_marked_json([
    'ok' => true,
    'jobs' => $rows,
    'pendingDeleteCount' => zfsas_ops_pending_delete_job_count(),
]);
