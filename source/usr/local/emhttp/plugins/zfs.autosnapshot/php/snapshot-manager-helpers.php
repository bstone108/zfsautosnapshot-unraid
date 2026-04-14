<?php

function zfsas_sm_trim($value)
{
    return trim((string) $value);
}

function zfsas_sm_h($value)
{
    return htmlspecialchars((string) $value, ENT_QUOTES, 'UTF-8');
}

function zfsas_sm_is_valid_dataset_name($dataset)
{
    return preg_match('/^[A-Za-z0-9._\/:+-]+$/', (string) $dataset) === 1;
}

function zfsas_sm_is_valid_snapshot_name($snapshotName)
{
    return preg_match('/^[A-Za-z0-9._:+-]+$/', (string) $snapshotName) === 1;
}

function zfsas_sm_dataset_key($dataset)
{
    return substr(sha1(strtolower(zfsas_sm_trim($dataset))), 0, 16);
}

function zfsas_sm_plugin_config_dir()
{
    return '/boot/config/plugins/zfs.autosnapshot';
}

function zfsas_sm_root_dir()
{
    return zfsas_sm_plugin_config_dir() . '/snapshot_manager';
}

function zfsas_sm_queue_root_dir()
{
    return zfsas_sm_root_dir() . '/queues';
}

function zfsas_sm_status_root_dir()
{
    return zfsas_sm_root_dir() . '/status';
}

function zfsas_sm_runtime_dir()
{
    return '/var/run/zfs-autosnapshot-manager';
}

function zfsas_sm_dataset_queue_dir($dataset)
{
    return zfsas_sm_queue_root_dir() . '/' . zfsas_sm_dataset_key($dataset);
}

function zfsas_sm_action_label($action)
{
    switch ((string) $action) {
        case 'take_snapshot':
            return 'Take Snapshot';
        case 'delete':
            return 'Delete Snapshot';
        case 'hold':
            return 'Hold Snapshot';
        case 'release':
            return 'Release Snapshot';
        case 'rollback':
            return 'Rollback Snapshot';
        case 'send':
            return 'Send Snapshot';
        default:
            return ucfirst(str_replace('_', ' ', (string) $action));
    }
}

function zfsas_sm_dataset_status_file($dataset)
{
    return zfsas_sm_status_root_dir() . '/' . zfsas_sm_dataset_key($dataset) . '.json';
}

function zfsas_sm_dataset_runtime_lock_dir($dataset)
{
    return zfsas_sm_runtime_dir() . '/locks/' . zfsas_sm_dataset_key($dataset) . '.lockdir';
}

function zfsas_sm_apply_owner($path)
{
    @chown($path, 'nobody');
    @chgrp($path, 'users');
}

function zfsas_sm_ensure_dir($path)
{
    if (!is_dir($path)) {
        @mkdir($path, 0775, true);
    }
    @chmod($path, 0775);
    zfsas_sm_apply_owner($path);
    return is_dir($path);
}

function zfsas_sm_ensure_storage_dirs()
{
    return zfsas_sm_ensure_dir(zfsas_sm_root_dir())
        && zfsas_sm_ensure_dir(zfsas_sm_queue_root_dir())
        && zfsas_sm_ensure_dir(zfsas_sm_status_root_dir());
}

function zfsas_sm_read_send_snapshot_prefix_base()
{
    $configPath = zfsas_sm_plugin_config_dir() . '/zfs_send.conf';
    $default = 'zfs-send-';

    if (!is_file($configPath)) {
        return $default;
    }

    $lines = @file($configPath, FILE_IGNORE_NEW_LINES);
    if (!is_array($lines)) {
        return $default;
    }

    foreach ($lines as $line) {
        if (!preg_match('/^\s*SEND_SNAPSHOT_PREFIX\s*=\s*(.*)$/', (string) $line, $match)) {
            continue;
        }

        $raw = trim((string) $match[1]);
        if ($raw === '') {
            return $default;
        }

        if (($raw[0] ?? '') === '"' && substr($raw, -1) === '"' && strlen($raw) >= 2) {
            $raw = substr($raw, 1, -1);
            $raw = str_replace(['\\"', '\\\\'], ['"', '\\'], $raw);
        }

        return ($raw !== '') ? $raw : $default;
    }

    return $default;
}

function zfsas_sm_is_send_protected_snapshot($snapshotBasename)
{
    $prefix = zfsas_sm_read_send_snapshot_prefix_base();
    return ($prefix !== '' && strpos((string) $snapshotBasename, $prefix) === 0);
}

function zfsas_sm_read_json_file($path)
{
    if (!is_file($path)) {
        return null;
    }

    $raw = @file_get_contents($path);
    if (!is_string($raw) || $raw === '') {
        return null;
    }

    $decoded = json_decode($raw, true);
    return is_array($decoded) ? $decoded : null;
}

function zfsas_sm_write_json_file($path, $payload)
{
    $encoded = json_encode($payload, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
    if (!is_string($encoded)) {
        return false;
    }

    $dir = dirname($path);
    if (!zfsas_sm_ensure_dir($dir)) {
        return false;
    }

    $written = @file_put_contents($path, $encoded . "\n");
    if ($written === false) {
        return false;
    }

    @chmod($path, 0664);
    zfsas_sm_apply_owner($path);
    return true;
}

function zfsas_sm_queue_operation_files($dataset)
{
    $queueDir = zfsas_sm_dataset_queue_dir($dataset);
    if (!is_dir($queueDir)) {
        return [];
    }

    $files = glob($queueDir . '/*.op');
    if (!is_array($files)) {
        return [];
    }

    sort($files, SORT_STRING);
    return $files;
}

function zfsas_sm_queue_pending_count($dataset)
{
    return count(zfsas_sm_queue_operation_files($dataset));
}

function zfsas_sm_dataset_busy($dataset)
{
    $status = zfsas_sm_read_json_file(zfsas_sm_dataset_status_file($dataset));
    if (is_array($status) && !empty($status['busy'])) {
        return true;
    }

    return is_dir(zfsas_sm_dataset_runtime_lock_dir($dataset));
}

function zfsas_sm_human_bytes($bytes)
{
    $bytes = (float) $bytes;
    $units = ['B', 'K', 'M', 'G', 'T', 'P'];
    $index = 0;

    while ($bytes >= 1024 && $index < count($units) - 1) {
        $bytes /= 1024;
        $index++;
    }

    if ($index === 0) {
        return (string) ((int) $bytes) . $units[$index];
    }

    return rtrim(rtrim(number_format($bytes, 1, '.', ''), '0'), '.') . $units[$index];
}

function zfsas_sm_exec_lines($command, &$exitCode = null)
{
    $output = [];
    $exit = 0;
    @exec($command . ' 2>/dev/null', $output, $exit);
    $exitCode = $exit;
    return $output;
}

function zfsas_sm_list_datasets(&$error = null)
{
    $error = null;
    $command = 'zfs list -H -o name -t filesystem,volume';
    $lines = zfsas_sm_exec_lines($command, $exitCode);
    if ($exitCode !== 0) {
        $error = 'Unable to list ZFS datasets.';
        return [];
    }

    $datasets = [];
    foreach ($lines as $line) {
        $dataset = trim((string) $line);
        if ($dataset === '' || !zfsas_sm_is_valid_dataset_name($dataset)) {
            continue;
        }
        $datasets[] = $dataset;
    }

    natcasesort($datasets);
    return array_values($datasets);
}

function zfsas_sm_snapshot_counts_map()
{
    $counts = [];
    $command = 'zfs list -H -o name -t snapshot';
    $lines = zfsas_sm_exec_lines($command, $exitCode);
    if ($exitCode !== 0) {
        return $counts;
    }

    foreach ($lines as $line) {
        $snapshot = trim((string) $line);
        if ($snapshot === '' || strpos($snapshot, '@') === false) {
            continue;
        }
        list($dataset) = explode('@', $snapshot, 2);
        if (!isset($counts[$dataset])) {
            $counts[$dataset] = 0;
        }
        $counts[$dataset]++;
    }

    return $counts;
}

function zfsas_sm_dataset_summary_rows(&$error = null)
{
    $datasets = zfsas_sm_list_datasets($error);
    $counts = zfsas_sm_snapshot_counts_map();
    $rows = [];

    foreach ($datasets as $dataset) {
        $status = zfsas_sm_read_json_file(zfsas_sm_dataset_status_file($dataset));
        $pending = zfsas_sm_queue_pending_count($dataset);
        $busy = zfsas_sm_dataset_busy($dataset);
        $currentAction = is_array($status) ? (string) ($status['current_action_label'] ?? '') : '';
        $lastError = is_array($status) ? (string) ($status['last_error'] ?? '') : '';
        $lastMessage = is_array($status) ? (string) ($status['last_message'] ?? '') : '';

        $rows[] = [
            'dataset' => $dataset,
            'pool' => strtok($dataset, '/'),
            'snapshotCount' => (int) ($counts[$dataset] ?? 0),
            'pendingCount' => $pending,
            'busy' => $busy,
            'currentAction' => $currentAction,
            'lastError' => $lastError,
            'lastMessage' => $lastMessage,
        ];
    }

    return $rows;
}

function zfsas_sm_snapshot_hold_tags($snapshot)
{
    $tags = [];
    $command = 'zfs holds -H ' . escapeshellarg($snapshot);
    $lines = zfsas_sm_exec_lines($command, $exitCode);
    if ($exitCode !== 0) {
        return $tags;
    }

    foreach ($lines as $line) {
        $parts = preg_split('/\s+/', trim((string) $line));
        if (!is_array($parts) || count($parts) < 2) {
            continue;
        }
        $tag = (string) $parts[1];
        if ($tag !== '') {
            $tags[] = $tag;
        }
    }

    return array_values(array_unique($tags));
}

function zfsas_sm_dataset_snapshots($dataset, &$error = null)
{
    $error = null;

    if (!zfsas_sm_is_valid_dataset_name($dataset)) {
        $error = 'Invalid dataset name.';
        return [];
    }

    $command = 'zfs list -H -p -s creation -t snapshot -o name,creation,used,written,userrefs -d 1 ' . escapeshellarg($dataset);
    $lines = zfsas_sm_exec_lines($command, $exitCode);
    if ($exitCode !== 0) {
        $error = 'Unable to read snapshots for the selected dataset.';
        return [];
    }

    $rows = [];
    foreach ($lines as $line) {
        $parts = preg_split('/\t+/', trim((string) $line));
        if (!is_array($parts) || count($parts) < 5) {
            continue;
        }

        $fullName = (string) $parts[0];
        if (strpos($fullName, '@') === false) {
            continue;
        }

        list($rowDataset, $snapshotName) = explode('@', $fullName, 2);
        if ($rowDataset !== $dataset) {
            continue;
        }

        $createdEpoch = (int) $parts[1];
        $used = (int) $parts[2];
        $written = (int) $parts[3];
        $userrefs = (int) $parts[4];
        $holdTags = ($userrefs > 0) ? zfsas_sm_snapshot_hold_tags($fullName) : [];
        $sendProtected = zfsas_sm_is_send_protected_snapshot($snapshotName);

        $rows[] = [
            'dataset' => $dataset,
            'snapshot' => $fullName,
            'snapshotName' => $snapshotName,
            'createdEpoch' => $createdEpoch,
            'createdText' => date('Y-m-d H:i:s', $createdEpoch),
            'usedBytes' => $used,
            'usedText' => zfsas_sm_human_bytes($used),
            'writtenBytes' => $written,
            'writtenText' => zfsas_sm_human_bytes($written),
            'userrefs' => $userrefs,
            'held' => $userrefs > 0,
            'holdTags' => $holdTags,
            'sendProtected' => $sendProtected,
        ];
    }

    return $rows;
}

function zfsas_sm_start_worker($dataset, &$error = null)
{
    $error = null;
    $script = '/usr/local/sbin/zfs_autosnapshot_snapshot_manager_worker';
    $log = '/var/log/zfs_autosnapshot_snapshot_manager.log';

    if (!is_file($script) || !is_executable($script)) {
        $error = 'Snapshot manager worker is missing or not executable.';
        return false;
    }

    $command = 'nohup ' . escapeshellarg($script)
        . ' --dataset ' . escapeshellarg($dataset)
        . ' >> ' . escapeshellarg($log)
        . ' 2>&1 < /dev/null & echo $!';

    $output = [];
    $exitCode = 0;
    @exec($command, $output, $exitCode);
    if ($exitCode !== 0) {
        $error = 'Unable to start the snapshot manager worker.';
        return false;
    }

    return true;
}
