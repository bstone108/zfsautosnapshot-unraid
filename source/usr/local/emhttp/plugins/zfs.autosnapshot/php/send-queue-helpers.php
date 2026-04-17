<?php

require_once __DIR__ . '/send-helpers.php';

function zfsas_ops_plugin_config_dir()
{
    return '/boot/config/plugins/zfs.autosnapshot';
}

function zfsas_ops_root_dir()
{
    return '/tmp/zfs-autosnapshot-ops';
}

function zfsas_ops_jobs_dir()
{
    return zfsas_ops_root_dir() . '/jobs';
}

function zfsas_ops_status_dir()
{
    return zfsas_ops_root_dir() . '/status';
}

function zfsas_ops_delete_queue_state_path()
{
    return zfsas_ops_status_dir() . '/delete-queue.state';
}

function zfsas_ops_delete_queue_inbox_path()
{
    return zfsas_ops_root_dir() . '/delete-queue.inbox';
}

function zfsas_ops_delete_queue_inbox_lock_path()
{
    return zfsas_ops_root_dir() . '/delete-queue.inbox.lock';
}

function zfsas_ops_failed_send_logs_dir()
{
    return zfsas_ops_plugin_config_dir() . '/failed_send_logs';
}

function zfsas_ops_shared_send_log_path()
{
    return '/var/log/zfs_autosnapshot_send.log';
}

function zfsas_ops_sanitize_job_id_for_path($jobId)
{
    $jobId = (string) $jobId;
    $sanitized = preg_replace('/[^A-Za-z0-9_.-]+/', '_', $jobId);
    if (!is_string($sanitized) || $sanitized === '') {
        return 'unknown-job';
    }

    return $sanitized;
}

function zfsas_ops_failed_send_log_path($jobId)
{
    return zfsas_ops_failed_send_logs_dir() . '/' . zfsas_ops_sanitize_job_id_for_path($jobId) . '.log';
}

function zfsas_ops_failed_send_log_download_url($jobId)
{
    return '/plugins/zfs.autosnapshot/php/send-log-download.php?job_id=' . rawurlencode((string) $jobId);
}

function zfsas_ops_runtime_dir()
{
    return '/var/run/zfs-autosnapshot-ops';
}

function zfsas_ops_delete_queue_daemon_pid_path()
{
    return zfsas_ops_runtime_dir() . '/delete-worker/daemon.pid';
}

function zfsas_ops_send_schedule_state_file()
{
    return zfsas_ops_plugin_config_dir() . '/send_schedule_state.state';
}

function zfsas_ops_apply_owner($path)
{
    @chown($path, 'nobody');
    @chgrp($path, 'users');
}

function zfsas_ops_ensure_dir($path)
{
    if (!is_dir($path)) {
        @mkdir($path, 0775, true);
    }
    @chmod($path, 0775);
    zfsas_ops_apply_owner($path);
    return is_dir($path);
}

function zfsas_ops_ensure_storage_dirs()
{
    return zfsas_ops_ensure_dir(zfsas_ops_root_dir())
        && zfsas_ops_ensure_dir(zfsas_ops_jobs_dir())
        && zfsas_ops_ensure_dir(zfsas_ops_status_dir())
        && zfsas_ops_ensure_dir(zfsas_ops_failed_send_logs_dir());
}

function zfsas_ops_kv_escape($value)
{
    $value = str_replace('\\', '\\\\', (string) $value);
    $value = str_replace('"', '\\"', $value);
    return $value;
}

function zfsas_ops_kv_unescape($value)
{
    $value = (string) $value;
    if ($value !== '' && strlen($value) >= 2 && $value[0] === '"' && substr($value, -1) === '"') {
        $value = substr($value, 1, -1);
        $value = str_replace(['\\"', '\\\\'], ['"', '\\'], $value);
        return $value;
    }

    if ($value !== '' && strlen($value) >= 2 && $value[0] === "'" && substr($value, -1) === "'") {
        return substr($value, 1, -1);
    }

    return $value;
}

function zfsas_ops_parse_job_file($path)
{
    if (!is_file($path)) {
        return null;
    }

    $lines = @file($path, FILE_IGNORE_NEW_LINES);
    if (!is_array($lines)) {
        return null;
    }

    $payload = [];
    foreach ($lines as $line) {
        if (!preg_match('/^\s*([A-Z0-9_]+)\s*=\s*(.*)$/', (string) $line, $match)) {
            continue;
        }

        $payload[$match[1]] = zfsas_ops_kv_unescape(trim((string) $match[2]));
    }

    if (!isset($payload['JOB_ID']) || !isset($payload['JOB_TYPE'])) {
        return null;
    }

    $payload['__path'] = $path;
    $payload['__basename'] = basename($path);
    return $payload;
}

function zfsas_ops_write_job_file($path, $payload)
{
    $dir = dirname($path);
    if (!zfsas_ops_ensure_dir($dir)) {
        return false;
    }

    $lines = [];
    foreach ($payload as $key => $value) {
        if ($key === '__path' || $key === '__basename') {
            continue;
        }
        $key = strtoupper((string) $key);
        if (!preg_match('/^[A-Z0-9_]+$/', $key)) {
            continue;
        }
        $lines[] = $key . '="' . zfsas_ops_kv_escape($value) . '"';
    }

    $written = @file_put_contents($path, implode(PHP_EOL, $lines) . PHP_EOL);
    if ($written === false) {
        return false;
    }

    @chmod($path, 0640);
    zfsas_ops_apply_owner($path);
    return true;
}

function zfsas_ops_delete_queue_state_rows()
{
    $path = zfsas_ops_delete_queue_state_path();
    if (!is_file($path)) {
        return [];
    }

    $lines = @file($path, FILE_IGNORE_NEW_LINES);
    if (!is_array($lines)) {
        return [];
    }

    $rows = [];
    foreach ($lines as $line) {
        $parts = explode("\t", (string) $line);
        if (($parts[0] ?? '') !== 'JOB' || count($parts) < 18) {
            continue;
        }

        $state = (string) ($parts[2] ?? 'queued');
        if (!in_array($state, ['queued', 'running', 'retry_wait'], true)) {
            continue;
        }

        $rows[] = [
            'JOB_ID' => (string) ($parts[1] ?? ''),
            'STATE' => $state,
            'RETRY_AT' => (string) ($parts[3] ?? '0'),
            'REQUESTED_EPOCH' => (string) ($parts[4] ?? '0'),
            'QUEUE_SORT' => (string) ($parts[5] ?? '0'),
            'DATASET' => (string) ($parts[6] ?? ''),
            'SNAPSHOT' => (string) ($parts[7] ?? ''),
            'SNAPSHOT_NAME' => (string) ($parts[8] ?? ''),
            'SNAPSHOT_EPOCH' => (string) ($parts[9] ?? '0'),
            'SNAPSHOT_GUID' => (string) ($parts[10] ?? ''),
            'SNAPSHOT_CREATETXG' => (string) ($parts[11] ?? ''),
            'DELETE_POOL' => (string) ($parts[12] ?? ''),
            'ESTIMATED_RECLAIM_BYTES' => (string) ($parts[13] ?? '0'),
            'SEND_PROTECTED' => (string) ($parts[14] ?? '0'),
            'DELETE_SCOPE' => (string) ($parts[15] ?? 'snapshot'),
            'SEND_SCHEDULE_JOB_ID' => (string) ($parts[16] ?? ''),
            'WORKER_PID' => (string) ($parts[17] ?? ''),
        ];
    }

    return $rows;
}

function zfsas_ops_delete_queue_inbox_rows()
{
    $path = zfsas_ops_delete_queue_inbox_path();
    if (!is_file($path)) {
        return [];
    }

    $lines = @file($path, FILE_IGNORE_NEW_LINES);
    if (!is_array($lines)) {
        return [];
    }

    $rows = [];
    foreach ($lines as $line) {
        $parts = explode("\t", (string) $line);
        if (($parts[0] ?? '') !== 'ENQUEUE' || count($parts) < 15) {
            continue;
        }

        $rows[] = [
            'JOB_ID' => (string) ($parts[1] ?? ''),
            'STATE' => 'queued',
            'RETRY_AT' => '0',
            'REQUESTED_EPOCH' => (string) ($parts[2] ?? '0'),
            'QUEUE_SORT' => (string) ($parts[3] ?? '0'),
            'DATASET' => (string) ($parts[4] ?? ''),
            'SNAPSHOT' => (string) ($parts[5] ?? ''),
            'SNAPSHOT_NAME' => (string) ($parts[6] ?? ''),
            'SNAPSHOT_EPOCH' => (string) ($parts[7] ?? '0'),
            'SNAPSHOT_GUID' => (string) ($parts[8] ?? ''),
            'SNAPSHOT_CREATETXG' => (string) ($parts[9] ?? ''),
            'DELETE_POOL' => (string) ($parts[10] ?? ''),
            'ESTIMATED_RECLAIM_BYTES' => (string) ($parts[11] ?? '0'),
            'SEND_PROTECTED' => (string) ($parts[12] ?? '0'),
            'DELETE_SCOPE' => (string) ($parts[13] ?? 'snapshot'),
            'SEND_SCHEDULE_JOB_ID' => (string) ($parts[14] ?? ''),
            'WORKER_PID' => '',
        ];
    }

    return $rows;
}

function zfsas_ops_delete_queue_active_rows()
{
    $rows = [];
    $seen = [];

    foreach (array_merge(zfsas_ops_delete_queue_state_rows(), zfsas_ops_delete_queue_inbox_rows()) as $row) {
        $key = '';
        if (($row['DELETE_SCOPE'] ?? 'snapshot') === 'checkpoint' && !empty($row['SEND_SCHEDULE_JOB_ID']) && !empty($row['SNAPSHOT_NAME'])) {
            $key = 'checkpoint|' . (string) $row['SEND_SCHEDULE_JOB_ID'] . '|' . (string) $row['SNAPSHOT_NAME'];
        } else {
            $key = 'snapshot|' . (string) ($row['SNAPSHOT'] ?? '');
        }
        if ($key === '' || isset($seen[$key])) {
            continue;
        }
        $seen[$key] = true;
        $rows[] = $row;
    }

    return $rows;
}

function zfsas_ops_delete_queue_daemon_running()
{
    $path = zfsas_ops_delete_queue_daemon_pid_path();
    if (!is_file($path)) {
        return false;
    }

    $pid = (int) trim((string) @file_get_contents($path));
    return $pid > 1 && zfsas_ops_process_alive($pid);
}

function zfsas_ops_start_delete_queue_daemon(&$error = null)
{
    $error = null;
    $script = '/usr/local/sbin/zfs_autosnapshot_delete_worker';
    $log = '/var/log/zfs_autosnapshot_send.log';

    if (zfsas_ops_delete_queue_daemon_running()) {
        return true;
    }

    if (!is_file($script) || !is_executable($script)) {
        $error = 'Delete queue daemon is missing or not executable.';
        return false;
    }

    $command = 'nohup ' . escapeshellarg($script) . ' >> ' . escapeshellarg($log) . ' 2>&1 < /dev/null & echo $!';
    $output = [];
    $exitCode = 0;
    @exec($command, $output, $exitCode);
    if ($exitCode !== 0) {
        $error = 'Unable to start the delete queue daemon.';
        return false;
    }

    for ($attempt = 0; $attempt < 20; $attempt++) {
        if (zfsas_ops_delete_queue_daemon_running()) {
            return true;
        }
        usleep(100000);
    }

    return zfsas_ops_delete_queue_daemon_running();
}

function zfsas_ops_delete_queue_command_line($payload)
{
    $parts = ['ENQUEUE'];
    $fields = [
        'JOB_ID',
        'REQUESTED_EPOCH',
        'QUEUE_SORT',
        'DATASET',
        'SNAPSHOT',
        'SNAPSHOT_NAME',
        'SNAPSHOT_EPOCH',
        'SNAPSHOT_GUID',
        'SNAPSHOT_CREATETXG',
        'DELETE_POOL',
        'ESTIMATED_RECLAIM_BYTES',
        'SEND_PROTECTED',
        'DELETE_SCOPE',
        'SEND_SCHEDULE_JOB_ID',
    ];

    foreach ($fields as $field) {
        $value = str_replace(["\t", "\r", "\n"], ' ', (string) ($payload[$field] ?? ''));
        $parts[] = $value;
    }

    return implode("\t", $parts);
}

function zfsas_ops_append_delete_queue_inbox($line)
{
    $lockPath = zfsas_ops_delete_queue_inbox_lock_path();
    $inboxPath = zfsas_ops_delete_queue_inbox_path();

    $lockHandle = @fopen($lockPath, 'c');
    if (!is_resource($lockHandle)) {
        return false;
    }

    if (!@flock($lockHandle, LOCK_EX)) {
        @fclose($lockHandle);
        return false;
    }

    $written = @file_put_contents($inboxPath, $line . PHP_EOL, FILE_APPEND);
    @flock($lockHandle, LOCK_UN);
    @fclose($lockHandle);

    if ($written === false) {
        return false;
    }

    @chmod($inboxPath, 0660);
    zfsas_ops_apply_owner($inboxPath);
    return true;
}

function zfsas_ops_list_jobs($types = null)
{
    zfsas_ops_purge_expired_jobs();

    $files = glob(zfsas_ops_jobs_dir() . '/*.job');
    if (!is_array($files)) {
        return [];
    }

    $typeMap = null;
    if (is_array($types)) {
        $typeMap = [];
        foreach ($types as $type) {
            $typeMap[(string) $type] = true;
        }
    }

    $jobs = [];
    foreach ($files as $path) {
        $job = zfsas_ops_parse_job_file($path);
        if (!is_array($job)) {
            continue;
        }
        if (is_array($typeMap) && empty($typeMap[(string) ($job['JOB_TYPE'] ?? '')])) {
            continue;
        }
        $jobs[] = $job;
    }

    usort($jobs, function ($a, $b) {
        $left = (int) ($a['REQUESTED_EPOCH'] ?? 0);
        $right = (int) ($b['REQUESTED_EPOCH'] ?? 0);
        if ($left === $right) {
            return strnatcasecmp((string) ($a['JOB_ID'] ?? ''), (string) ($b['JOB_ID'] ?? ''));
        }
        return $right <=> $left;
    });

    return $jobs;
}

function zfsas_ops_purge_expired_jobs()
{
    $now = time();
    $files = glob(zfsas_ops_jobs_dir() . '/*.job');
    if (!is_array($files)) {
        return;
    }

    foreach ($files as $path) {
        $job = zfsas_ops_parse_job_file($path);
        if (!is_array($job)) {
            continue;
        }

        $state = (string) ($job['STATE'] ?? '');
        if (!in_array($state, ['complete', 'skipped'], true)) {
            continue;
        }

        $purgeAfter = (int) ($job['PURGE_AFTER_EPOCH'] ?? 0);
        if ($purgeAfter > 0 && $purgeAfter <= $now) {
            @unlink($path);
            continue;
        }

        if ($purgeAfter <= 0) {
            $fileMtime = @filemtime($path);
            if (is_int($fileMtime) && $fileMtime > 0 && ($now - $fileMtime) >= 5) {
                @unlink($path);
            }
        }
    }
}

function zfsas_ops_send_job_progress_percent($job)
{
    $explicit = (int) ($job['PROGRESS_PERCENT'] ?? -1);
    if ($explicit >= 0) {
        return max(0, min(100, $explicit));
    }

    $phase = (string) ($job['PHASE'] ?? 'queued');
    switch ($phase) {
        case 'queued':
            return 5;
        case 'preparing':
            return 15;
        case 'snapshot_created':
            return 30;
        case 'sending':
            return 60;
        case 'verifying':
            return 85;
        case 'cleanup':
            return 95;
        case 'complete':
            return 100;
        case 'failed':
            return 100;
        case 'retry_wait':
            return 10;
        default:
            return 0;
    }
}

function zfsas_ops_send_job_state_label($job)
{
    $state = (string) ($job['STATE'] ?? 'queued');
    $phase = (string) ($job['PHASE'] ?? 'queued');

    if ($state === 'failed' && (string) ($job['CANCELLED_BY_USER'] ?? '0') === '1') {
        return 'Canceled';
    }

    if ($state === 'running') {
        return ucfirst(str_replace('_', ' ', $phase));
    }

    if ($state === 'retry_wait') {
        return 'Retry waiting';
    }

    return ucfirst(str_replace('_', ' ', $state));
}

function zfsas_ops_send_job_type_label($job)
{
    $mode = (string) ($job['JOB_MODE'] ?? '');
    $action = (string) ($job['JOB_ACTION'] ?? '');

    if ($mode === 'manual_snapshot') {
        return 'Manual send';
    }

    switch ($action) {
        case 'prepare':
            return ((string) ($job['INCLUDE_CHILDREN'] ?? '0') === '1')
                ? 'Recursive prep'
                : 'Scheduled send';
        case 'send_member':
            return 'Child send';
        case 'cleanup_member':
            return 'Zero-change cleanup';
        case 'finalize':
            return 'Finalize cleanup';
        default:
            return 'Scheduled send';
    }
}

function zfsas_ops_schedule_state_read()
{
    $path = zfsas_ops_send_schedule_state_file();
    if (!is_file($path)) {
        return [];
    }

    $raw = @file_get_contents($path);
    if (!is_string($raw) || $raw === '') {
        return [];
    }

    $result = [];
    foreach (preg_split('/\r?\n/', trim($raw)) as $line) {
        $line = trim((string) $line);
        if ($line === '') {
            continue;
        }
        $parts = explode('|', $line, 2);
        if (count($parts) !== 2) {
            continue;
        }
        $jobId = trim((string) $parts[0]);
        $windowKey = trim((string) $parts[1]);
        if ($jobId === '' || !preg_match('/^\d+$/', $windowKey)) {
            continue;
        }
        $result[$jobId] = $windowKey;
    }

    return $result;
}

function zfsas_ops_schedule_state_write($payload)
{
    if (!zfsas_ops_ensure_storage_dirs()) {
        return false;
    }

    $path = zfsas_ops_send_schedule_state_file();
    $lines = [];
    if (is_array($payload)) {
        ksort($payload, SORT_NATURAL);
        foreach ($payload as $jobId => $windowKey) {
            $jobId = trim((string) $jobId);
            $windowKey = trim((string) $windowKey);
            if ($jobId === '' || !preg_match('/^\d+$/', $windowKey)) {
                continue;
            }
            $lines[] = $jobId . '|' . $windowKey;
        }
    }

    $written = @file_put_contents($path, implode("\n", $lines) . ($lines ? "\n" : ''));
    if ($written === false) {
        return false;
    }

    @chmod($path, 0640);
    zfsas_ops_apply_owner($path);
    return true;
}

function zfsas_ops_is_overlap_pair($source, $destination)
{
    $source = zfsas_send_trim($source);
    $destination = zfsas_send_trim($destination);

    if ($source === '' || $destination === '') {
        return false;
    }

    return $source === $destination
        || strpos($source . '/', $destination . '/') === 0
        || strpos($destination . '/', $source . '/') === 0;
}

function zfsas_ops_schedule_job_id_from_snapshot_name($snapshotName, $prefixBase = 'zfs-send-')
{
    $snapshotName = zfsas_send_trim($snapshotName);
    $prefixBase = zfsas_send_trim($prefixBase);
    if ($snapshotName === '' || $prefixBase === '') {
        return '';
    }

    if (strpos($snapshotName, $prefixBase) !== 0) {
        return '';
    }

    $remainder = substr($snapshotName, strlen($prefixBase));
    if (preg_match('/^([a-f0-9]{12})-/', $remainder, $match) !== 1) {
        return '';
    }

    return (string) $match[1];
}

function zfsas_ops_make_job_filename($jobId, $requestedEpoch)
{
    return sprintf('%010d-%s.job', (int) $requestedEpoch, preg_replace('/[^a-zA-Z0-9_.-]+/', '-', (string) $jobId));
}

function zfsas_ops_job_path($jobId, $requestedEpoch)
{
    return zfsas_ops_jobs_dir() . '/' . zfsas_ops_make_job_filename($jobId, $requestedEpoch);
}

function zfsas_ops_start_queue_kicker(&$error = null, $arguments = [])
{
    $error = null;
    $script = '/usr/local/sbin/zfs_autosnapshot_queue_kicker';
    $log = '/var/log/zfs_autosnapshot_send.log';

    if (!is_file($script) || !is_executable($script)) {
        $error = 'Queue kicker is missing or not executable.';
        return false;
    }

    $command = 'nohup ' . escapeshellarg($script);
    foreach ($arguments as $argument) {
        $command .= ' ' . escapeshellarg((string) $argument);
    }
    $command .= ' >> ' . escapeshellarg($log) . ' 2>&1 < /dev/null & echo $!';

    $output = [];
    $exitCode = 0;
    @exec($command, $output, $exitCode);
    if ($exitCode !== 0) {
        $error = 'Unable to start the queue kicker.';
        return false;
    }

    return true;
}

function zfsas_ops_dataset_send_activity_map()
{
    $activity = [];
    $jobs = zfsas_ops_list_jobs(['send']);

    foreach ($jobs as $job) {
        $state = (string) ($job['STATE'] ?? 'queued');
        if (!in_array($state, ['queued', 'running', 'retry_wait'], true)) {
            continue;
        }

        $datasets = [];
        $sourceRoot = zfsas_send_trim($job['SOURCE_ROOT'] ?? $job['DATASET'] ?? '');
        if ($sourceRoot !== '') {
            $datasets[$sourceRoot] = true;
        }

        $memberCount = (int) ($job['MEMBER_COUNT'] ?? 0);
        for ($index = 0; $index < $memberCount; $index++) {
            $memberSource = zfsas_send_trim($job['MEMBER_' . $index . '_SOURCE'] ?? '');
            if ($memberSource !== '') {
                $datasets[$memberSource] = true;
            }
        }

        foreach (array_keys($datasets) as $dataset) {
            if (!isset($activity[$dataset])) {
                $activity[$dataset] = [];
            }
            $activity[$dataset][] = [
                'jobId' => (string) ($job['JOB_ID'] ?? ''),
                'state' => $state,
                'stateLabel' => zfsas_ops_send_job_state_label($job),
                'progress' => zfsas_ops_send_job_progress_percent($job),
                'message' => (string) ($job['LAST_MESSAGE'] ?? ''),
                'destination' => (string) ($job['DESTINATION_ROOT'] ?? $job['DESTINATION'] ?? ''),
                'manual' => ((string) ($job['JOB_MODE'] ?? '') === 'manual_snapshot'),
            ];
        }
    }

    return $activity;
}

function zfsas_ops_delete_snapshot_map()
{
    $map = [];
    foreach (zfsas_ops_delete_queue_active_rows() as $job) {
        $snapshot = (string) ($job['SNAPSHOT'] ?? '');
        if ($snapshot === '') {
            continue;
        }
        $map[$snapshot] = $job;
    }

    return $map;
}

function zfsas_ops_pending_delete_job_count()
{
    return count(zfsas_ops_delete_queue_active_rows());
}

function zfsas_ops_queue_pending_counts_by_dataset()
{
    $counts = [];
    foreach (zfsas_ops_list_jobs(['send']) as $job) {
        $state = (string) ($job['STATE'] ?? 'queued');
        if (!in_array($state, ['queued', 'running', 'retry_wait'], true)) {
            continue;
        }
        $dataset = (string) ($job['DATASET'] ?? $job['SOURCE_ROOT'] ?? '');
        if ($dataset === '') {
            continue;
        }
        if (!isset($counts[$dataset])) {
            $counts[$dataset] = 0;
        }
        $counts[$dataset]++;
    }

    foreach (zfsas_ops_delete_queue_active_rows() as $job) {
        $dataset = (string) ($job['DATASET'] ?? '');
        if ($dataset === '') {
            continue;
        }
        if (!isset($counts[$dataset])) {
            $counts[$dataset] = 0;
        }
        $counts[$dataset]++;
    }

    return $counts;
}

function zfsas_ops_job_exists_for_window($scheduleJobId, $windowKey)
{
    foreach (zfsas_ops_list_jobs(['send']) as $job) {
        if ((string) ($job['JOB_MODE'] ?? '') !== 'scheduled') {
            continue;
        }
        if ((string) ($job['SCHEDULE_JOB_ID'] ?? '') !== (string) $scheduleJobId) {
            continue;
        }
        if ((string) ($job['WINDOW_KEY'] ?? '') !== (string) $windowKey) {
            continue;
        }
        return true;
    }

    return false;
}

function zfsas_ops_scheduled_job_blocked($scheduleJobId)
{
    foreach (zfsas_ops_list_jobs(['send']) as $job) {
        if ((string) ($job['JOB_MODE'] ?? '') !== 'scheduled') {
            continue;
        }
        if ((string) ($job['SCHEDULE_JOB_ID'] ?? '') !== (string) $scheduleJobId) {
            continue;
        }
        if (in_array((string) ($job['STATE'] ?? ''), ['queued', 'running', 'retry_wait', 'failed'], true)) {
            return true;
        }
    }

    return false;
}

function zfsas_ops_find_matching_manual_send_job($snapshot, $destination)
{
    foreach (zfsas_ops_list_jobs(['send']) as $job) {
        if ((string) ($job['JOB_MODE'] ?? '') !== 'manual_snapshot') {
            continue;
        }
        if ((string) ($job['SOURCE_SNAPSHOT'] ?? '') !== (string) $snapshot) {
            continue;
        }
        if ((string) ($job['DESTINATION_ROOT'] ?? '') !== (string) $destination) {
            continue;
        }
        if (in_array((string) ($job['STATE'] ?? ''), ['queued', 'running', 'retry_wait'], true)) {
            return $job;
        }
    }

    return null;
}

function zfsas_ops_recent_send_jobs($limit = 100)
{
    $jobs = zfsas_ops_list_jobs(['send']);
    usort($jobs, function ($a, $b) {
        $leftSort = (int) ($a['QUEUE_SORT'] ?? PHP_INT_MAX);
        $rightSort = (int) ($b['QUEUE_SORT'] ?? PHP_INT_MAX);
        if ($leftSort !== $rightSort) {
            return $leftSort <=> $rightSort;
        }

        $leftRequested = (int) ($a['REQUESTED_EPOCH'] ?? 0);
        $rightRequested = (int) ($b['REQUESTED_EPOCH'] ?? 0);
        if ($leftRequested !== $rightRequested) {
            return $leftRequested <=> $rightRequested;
        }

        return strnatcasecmp((string) ($a['JOB_ID'] ?? ''), (string) ($b['JOB_ID'] ?? ''));
    });
    return array_slice($jobs, 0, max(1, (int) $limit));
}

function zfsas_ops_retry_send_job($jobId, &$error = null)
{
    $error = null;
    foreach (zfsas_ops_list_jobs(['send']) as $job) {
        if ((string) ($job['JOB_ID'] ?? '') !== (string) $jobId) {
            continue;
        }
        if ((string) ($job['STATE'] ?? '') !== 'failed') {
            $error = 'Only failed send jobs can be retried.';
            return false;
        }
        $job['STATE'] = 'queued';
        $job['PHASE'] = 'queued';
        $job['RETRY_AT'] = '0';
        $job['LAST_ERROR'] = '';
        $job['LAST_MESSAGE'] = 'Queued for manual retry.';
        $job['WORKER_PID'] = '';
        $job['PROGRESS_PERCENT'] = '5';
        if (!zfsas_ops_write_job_file($job['__path'], $job)) {
            $error = 'Unable to update the send job for retry.';
            return false;
        }
        return true;
    }

    $error = 'Send job not found.';
    return false;
}

function zfsas_ops_clear_send_job($jobId, &$error = null)
{
    $error = null;
    foreach (zfsas_ops_list_jobs(['send']) as $job) {
        if ((string) ($job['JOB_ID'] ?? '') !== (string) $jobId) {
            continue;
        }
        if ((string) ($job['STATE'] ?? '') !== 'failed') {
            $error = 'Only failed send jobs can be cleared.';
            return false;
        }
        if (!zfsas_ops_delete_failed_send_log($jobId, $error)) {
            return false;
        }
        if (!@unlink((string) ($job['__path'] ?? ''))) {
            $error = 'Unable to remove the failed send job from the queue.';
            return false;
        }
        return true;
    }

    $error = 'Send job not found.';
    return false;
}

function zfsas_ops_process_alive($pid)
{
    $pid = (int) $pid;
    if ($pid <= 1) {
        return false;
    }

    if (function_exists('posix_kill')) {
        return @posix_kill($pid, 0);
    }

    $output = [];
    $exitCode = 0;
    @exec('kill -0 ' . (int) $pid . ' >/dev/null 2>&1', $output, $exitCode);
    return $exitCode === 0;
}

function zfsas_ops_signal_process($pid, $signal)
{
    $pid = (int) $pid;
    $signal = (int) $signal;
    if ($pid <= 1 || $signal <= 0) {
        return false;
    }

    if (function_exists('posix_kill')) {
        return @posix_kill($pid, $signal);
    }

    $output = [];
    $exitCode = 0;
    @exec('kill -' . $signal . ' ' . $pid . ' >/dev/null 2>&1', $output, $exitCode);
    return $exitCode === 0;
}

function zfsas_ops_wait_for_process_exit($pid, $timeoutMs)
{
    $pid = (int) $pid;
    $timeoutMs = max(0, (int) $timeoutMs);
    $deadline = microtime(true) + ($timeoutMs / 1000);

    while (microtime(true) < $deadline) {
        if (!zfsas_ops_process_alive($pid)) {
            return true;
        }
        usleep(100000);
    }

    return !zfsas_ops_process_alive($pid);
}

function zfsas_ops_mark_send_job_canceled($job, &$error = null)
{
    $error = null;
    if (!is_array($job) || empty($job['__path'])) {
        $error = 'Send job not found.';
        return false;
    }

    $job['STATE'] = 'failed';
    $job['PHASE'] = 'failed';
    $job['RETRY_AT'] = '0';
    $job['WORKER_PID'] = '';
    $job['PROGRESS_PERCENT'] = '100';
    $job['LAST_ERROR'] = 'Canceled by user.';
    $job['LAST_MESSAGE'] = 'Canceled by user.';
    $job['CANCELLED_BY_USER'] = '1';
    $job['ATTEMPT_COUNT'] = (string) max(3, (int) ($job['ATTEMPT_COUNT'] ?? 0));

    if (!zfsas_ops_write_job_file($job['__path'], $job)) {
        $error = 'Unable to update the canceled send job.';
        return false;
    }

    return true;
}

function zfsas_ops_delete_failed_send_log($jobId, &$error = null)
{
    $error = null;
    $path = zfsas_ops_failed_send_log_path($jobId);
    clearstatcache(true, $path);

    if (!file_exists($path)) {
        return true;
    }

    if (is_link($path) || !is_file($path)) {
        $error = 'Preserved send log path is invalid.';
        return false;
    }

    if (!@unlink($path)) {
        $error = 'Unable to remove the preserved send log.';
        return false;
    }

    return true;
}

function zfsas_ops_cancel_send_job($jobId, &$error = null)
{
    $error = null;
    foreach (zfsas_ops_list_jobs(['send']) as $job) {
        if ((string) ($job['JOB_ID'] ?? '') !== (string) $jobId) {
            continue;
        }

        $state = (string) ($job['STATE'] ?? '');
        if (!in_array($state, ['queued', 'running', 'retry_wait'], true)) {
            $error = 'Only queued, waiting, or running send jobs can be canceled.';
            return false;
        }

        if ($state === 'running') {
            $workerPid = (int) ($job['WORKER_PID'] ?? 0);
            if ($workerPid <= 1) {
                $error = 'The send worker pid is missing for this running job.';
                return false;
            }

            zfsas_ops_signal_process($workerPid, 15);
            if (!zfsas_ops_wait_for_process_exit($workerPid, 5000)) {
                zfsas_ops_signal_process($workerPid, 9);
                if (!zfsas_ops_wait_for_process_exit($workerPid, 2000)) {
                    $error = 'Unable to stop the running send worker for this job.';
                    return false;
                }
            }

            $reloaded = zfsas_ops_parse_job_file((string) $job['__path']);
            if (is_array($reloaded)) {
                $job = $reloaded;
            }
        }

        return zfsas_ops_mark_send_job_canceled($job, $error);
    }

    $error = 'Send job not found.';
    return false;
}

function zfsas_ops_snapshot_identity($snapshot)
{
    $snapshot = zfsas_send_trim($snapshot);
    if ($snapshot === '') {
        return null;
    }

    $output = [];
    $exitCode = 0;
    @exec(
        'zfs get -H -p -o property,value creation,guid,createtxg ' . escapeshellarg($snapshot) . ' 2>/dev/null',
        $output,
        $exitCode
    );

    if ($exitCode !== 0) {
        return null;
    }

    $identity = [
        'creation' => '',
        'guid' => '',
        'createtxg' => '',
    ];

    foreach ($output as $line) {
        $parts = preg_split('/\t+/', trim((string) $line));
        if (!is_array($parts) || count($parts) < 2) {
            continue;
        }
        $property = (string) $parts[0];
        $value = (string) $parts[1];
        if (array_key_exists($property, $identity)) {
            $identity[$property] = $value;
        }
    }

    return $identity;
}

function zfsas_ops_manual_send_job_id($snapshot, $destination)
{
    return 'manual-send-' . substr(sha1(strtolower(trim((string) $snapshot) . '|' . trim((string) $destination))), 0, 16);
}

function zfsas_ops_enqueue_manual_send($dataset, $snapshot, $snapshotName, $destination, $createdEpoch, &$error = null)
{
    $error = null;

    if (!zfsas_ops_ensure_storage_dirs()) {
        $error = 'ZFS send queue storage is unavailable.';
        return false;
    }

    $existing = zfsas_ops_find_matching_manual_send_job($snapshot, $destination);
    if (is_array($existing)) {
        $error = 'That snapshot is already queued or running for the selected destination.';
        return false;
    }

    $identity = zfsas_ops_snapshot_identity($snapshot);
    if (!is_array($identity)) {
        $error = 'Unable to read the selected snapshot identity from ZFS.';
        return false;
    }

    $requestedEpoch = time();
    $requestedAt = gmdate('Y-m-d\TH:i:s\Z', $requestedEpoch);
    $jobId = zfsas_ops_manual_send_job_id($snapshot, $destination) . '-' . $requestedEpoch;
    $path = zfsas_ops_job_path($jobId, $requestedEpoch);
    $payload = [
        'JOB_ID' => $jobId,
        'JOB_TYPE' => 'send',
        'JOB_MODE' => 'manual_snapshot',
        'STATE' => 'queued',
        'PHASE' => 'queued',
        'REQUESTED_EPOCH' => (string) $requestedEpoch,
        'REQUESTED_AT' => $requestedAt,
        'QUEUE_SORT' => (string) $requestedEpoch,
        'DATASET' => $dataset,
        'SOURCE_ROOT' => $dataset,
        'SOURCE_SNAPSHOT' => $snapshot,
        'SOURCE_SNAPSHOT_NAME' => $snapshotName,
        'SOURCE_SNAPSHOT_EPOCH' => (string) $createdEpoch,
        'SOURCE_SNAPSHOT_GUID' => (string) ($identity['guid'] ?? ''),
        'SOURCE_SNAPSHOT_CREATETXG' => (string) ($identity['createtxg'] ?? ''),
        'DESTINATION_ROOT' => $destination,
        'INCLUDE_CHILDREN' => '0',
        'ATTEMPT_COUNT' => '0',
        'RETRY_AT' => '0',
        'LAST_ERROR' => '',
        'LAST_MESSAGE' => 'Queued from Snapshot Manager.',
        'WORKER_PID' => '',
        'PROGRESS_PERCENT' => '5',
        'MEMBER_COUNT' => '0',
    ];

    if (!zfsas_ops_write_job_file($path, $payload)) {
        $error = 'Unable to create the queued send job.';
        return false;
    }

    return true;
}

function zfsas_ops_enqueue_snapshot_delete($dataset, $snapshotRow, $forceCheckpointDelete, &$error = null)
{
    $error = null;

    if (!zfsas_ops_ensure_storage_dirs()) {
        $error = 'Snapshot delete queue storage is unavailable.';
        return false;
    }

    $snapshot = (string) ($snapshotRow['snapshot'] ?? '');
    $snapshotName = (string) ($snapshotRow['snapshotName'] ?? '');
    if ($snapshot === '' || $snapshotName === '') {
        $error = 'Snapshot information is incomplete.';
        return false;
    }

    if (isset(zfsas_ops_delete_snapshot_map()[$snapshot])) {
        return true;
    }

    $requestedEpoch = time();
    $jobId = 'delete-' . substr(sha1(strtolower($snapshot)), 0, 16) . '-' . $requestedEpoch;
    $payload = [
        'JOB_ID' => $jobId,
        'REQUESTED_EPOCH' => (string) $requestedEpoch,
        'QUEUE_SORT' => (string) (((int) ($snapshotRow['createdEpoch'] ?? $requestedEpoch) * 1000) + random_int(1, 999)),
        'DATASET' => $dataset,
        'SNAPSHOT' => $snapshot,
        'SNAPSHOT_NAME' => $snapshotName,
        'SNAPSHOT_EPOCH' => (string) ((int) ($snapshotRow['createdEpoch'] ?? 0)),
        'SNAPSHOT_GUID' => (string) ($snapshotRow['guid'] ?? ''),
        'SNAPSHOT_CREATETXG' => (string) ($snapshotRow['createtxg'] ?? ''),
        'DELETE_POOL' => strtok($dataset, '/'),
        'ESTIMATED_RECLAIM_BYTES' => (string) ((int) ($snapshotRow['writtenBytes'] ?? $snapshotRow['usedBytes'] ?? 0)),
        'SEND_PROTECTED' => !empty($snapshotRow['sendProtected']) ? '1' : '0',
        'DELETE_SCOPE' => ($forceCheckpointDelete && !empty($snapshotRow['sendProtected'])) ? 'checkpoint' : 'snapshot',
    ];

    if (!empty($snapshotRow['sendScheduleJobId'])) {
        $payload['SEND_SCHEDULE_JOB_ID'] = (string) $snapshotRow['sendScheduleJobId'];
    }

    if (!zfsas_ops_append_delete_queue_inbox(zfsas_ops_delete_queue_command_line($payload))) {
        $error = 'Unable to queue the snapshot deletion.';
        return false;
    }

    $daemonError = null;
    zfsas_ops_start_delete_queue_daemon($daemonError);

    return true;
}
