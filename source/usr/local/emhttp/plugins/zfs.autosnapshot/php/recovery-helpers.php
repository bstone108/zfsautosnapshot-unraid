<?php

require_once __DIR__ . '/response-helpers.php';

function zfsas_recovery_trim($value)
{
    return trim((string) $value);
}

function zfsas_recovery_is_valid_dataset_name($dataset)
{
    return zfsas_is_valid_dataset_name($dataset);
}

function zfsas_recovery_h($value)
{
    return htmlspecialchars((string) $value, ENT_QUOTES, 'UTF-8');
}

function zfsas_recovery_plugin_dir()
{
    return '/boot/config/plugins/zfs.autosnapshot/recovery_tools';
}

function zfsas_recovery_scans_dir()
{
    return zfsas_recovery_plugin_dir() . '/scans';
}

function zfsas_recovery_logs_dir()
{
    return '/var/log/zfs_autosnapshot_recovery';
}

function zfsas_recovery_apply_owner($path)
{
    @chown($path, 'nobody');
    @chgrp($path, 'users');
}

function zfsas_recovery_ensure_dir($path)
{
    if (!is_dir($path)) {
        @mkdir($path, 0775, true);
    }
    @chmod($path, 0775);
    zfsas_recovery_apply_owner($path);
    return is_dir($path);
}

function zfsas_recovery_ensure_storage()
{
    return zfsas_recovery_ensure_dir(zfsas_recovery_plugin_dir())
        && zfsas_recovery_ensure_dir(zfsas_recovery_scans_dir())
        && zfsas_recovery_ensure_dir(zfsas_recovery_logs_dir());
}

function zfsas_recovery_dataset_key($dataset)
{
    return substr(sha1(strtolower(zfsas_recovery_trim($dataset))), 0, 16);
}

function zfsas_recovery_scan_status_path($dataset)
{
    return zfsas_recovery_scans_dir() . '/' . zfsas_recovery_dataset_key($dataset) . '.json';
}

function zfsas_recovery_log_path($dataset)
{
    return zfsas_recovery_logs_dir() . '/' . zfsas_recovery_dataset_key($dataset) . '.log';
}

function zfsas_recovery_read_json_file($path)
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

function zfsas_recovery_write_json_file($path, $payload)
{
    $dir = dirname($path);
    if (!zfsas_recovery_ensure_dir($dir)) {
        return false;
    }

    $encoded = json_encode($payload, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
    if (!is_string($encoded)) {
        return false;
    }

    $written = @file_put_contents($path, $encoded . "\n");
    if ($written === false) {
        return false;
    }

    @chmod($path, 0640);
    zfsas_recovery_apply_owner($path);
    return true;
}

function zfsas_recovery_exec_lines($command, &$exitCode = null)
{
    $output = [];
    $exit = 0;
    @exec($command . ' 2>/dev/null', $output, $exit);
    $exitCode = $exit;
    return $output;
}

function zfsas_recovery_list_datasets(&$error = null)
{
    $error = null;
    $rows = [];
    $lines = zfsas_recovery_exec_lines('zfs list -H -o name,mountpoint -t filesystem', $exitCode);
    if ($exitCode !== 0) {
        $error = 'Unable to list ZFS filesystem datasets.';
        return [];
    }

    foreach ($lines as $line) {
        $parts = preg_split('/\t+/', trim((string) $line));
        if (!is_array($parts) || count($parts) < 2) {
            continue;
        }
        $dataset = zfsas_recovery_trim($parts[0]);
        $mountpoint = zfsas_recovery_trim($parts[1]);
        if ($dataset === '') {
            continue;
        }
        $rows[] = [
            'dataset' => $dataset,
            'mountpoint' => $mountpoint,
            'scanStatus' => zfsas_recovery_read_json_file(zfsas_recovery_scan_status_path($dataset)),
        ];
    }

    usort($rows, function ($a, $b) {
        return strnatcasecmp((string) ($a['dataset'] ?? ''), (string) ($b['dataset'] ?? ''));
    });

    return $rows;
}

function zfsas_recovery_pool_status()
{
    $lines = zfsas_recovery_exec_lines('zpool status -v', $exitCode);
    if ($exitCode !== 0) {
        return [
            'error' => 'Unable to read zpool status.',
            'pools' => [],
        ];
    }

    $pools = [];
    $currentIndex = -1;
    $captureErrors = false;

    foreach ($lines as $line) {
        $raw = rtrim((string) $line, "\r\n");
        $trimmed = trim($raw);

        if (preg_match('/^pool:\s+(\S+)/', $trimmed, $match) === 1) {
            $pools[] = [
                'name' => $match[1],
                'state' => '',
                'scan' => '',
                'status' => '',
                'errors' => '',
                'identifiedFiles' => [],
                'unmappedIssues' => [],
                'rawErrorLines' => [],
            ];
            $currentIndex = count($pools) - 1;
            $captureErrors = false;
            continue;
        }

        if ($currentIndex < 0) {
            continue;
        }

        if (strpos($trimmed, 'state:') === 0) {
            $pools[$currentIndex]['state'] = trim(substr($trimmed, strlen('state:')));
            $captureErrors = false;
            continue;
        }

        if (strpos($trimmed, 'status:') === 0) {
            $pools[$currentIndex]['status'] = trim(substr($trimmed, strlen('status:')));
            $captureErrors = false;
            continue;
        }

        if (strpos($trimmed, 'scan:') === 0) {
            $pools[$currentIndex]['scan'] = trim(substr($trimmed, strlen('scan:')));
            $captureErrors = false;
            continue;
        }

        if (strpos($trimmed, 'errors:') === 0) {
            $pools[$currentIndex]['errors'] = trim(substr($trimmed, strlen('errors:')));
            $captureErrors = stripos($pools[$currentIndex]['errors'], 'No known data errors') === false;
            continue;
        }

        if (!$captureErrors) {
            continue;
        }

        if ($trimmed === '') {
            continue;
        }

        if (preg_match('/^(config:|NAME\s+STATE|see:)/', $trimmed) === 1) {
            continue;
        }

        $pools[$currentIndex]['rawErrorLines'][] = $trimmed;
        if ($trimmed[0] === '/' || preg_match('/\/[A-Za-z0-9._-]/', $trimmed) === 1) {
            $pools[$currentIndex]['identifiedFiles'][] = $trimmed;
        } else {
            $pools[$currentIndex]['unmappedIssues'][] = $trimmed;
        }
    }

    foreach ($pools as &$pool) {
        $pool['identifiedFiles'] = array_values(array_unique($pool['identifiedFiles']));
        $pool['unmappedIssues'] = array_values(array_unique($pool['unmappedIssues']));
        $pool['rawErrorLines'] = array_values(array_unique($pool['rawErrorLines']));
    }
    unset($pool);

    return [
        'error' => null,
        'pools' => $pools,
    ];
}

function zfsas_recovery_list_scans()
{
    $files = glob(zfsas_recovery_scans_dir() . '/*.json');
    if (!is_array($files)) {
        return [];
    }

    $rows = [];
    foreach ($files as $path) {
        $payload = zfsas_recovery_read_json_file($path);
        if (!is_array($payload)) {
            continue;
        }
        $rows[] = $payload;
    }

    usort($rows, function ($a, $b) {
        return ((int) ($b['startedEpoch'] ?? 0)) <=> ((int) ($a['startedEpoch'] ?? 0));
    });

    return $rows;
}

function zfsas_recovery_start_scan($dataset, &$error = null)
{
    $error = null;

    if (!zfsas_recovery_ensure_storage()) {
        $error = 'Recovery scan storage is unavailable.';
        return false;
    }

    $dataset = zfsas_recovery_trim($dataset);
    if ($dataset === '' || !zfsas_recovery_is_valid_dataset_name($dataset)) {
        $error = 'Dataset is invalid.';
        return false;
    }

    $existing = zfsas_recovery_read_json_file(zfsas_recovery_scan_status_path($dataset));
    $existingPid = (int) ($existing['pid'] ?? 0);
    $existingRunning = is_array($existing)
        && in_array((string) ($existing['state'] ?? ''), ['queued', 'running'], true)
        && $existingPid > 0
        && function_exists('posix_kill')
        && @posix_kill($existingPid, 0);
    if ($existingRunning) {
        $error = 'A diagnostic scan is already running for that dataset.';
        return false;
    }

    $script = '/usr/local/sbin/zfs_autosnapshot_recovery_scan';
    if (!is_file($script) || !is_executable($script)) {
        $error = 'Recovery scan worker is missing or not executable.';
        return false;
    }

    $logPath = zfsas_recovery_log_path($dataset);
    $command = 'nohup ' . escapeshellarg($script)
        . ' --dataset ' . escapeshellarg($dataset)
        . ' >> ' . escapeshellarg($logPath)
        . ' 2>&1 < /dev/null & echo $!';

    $output = [];
    $exitCode = 0;
    @exec($command, $output, $exitCode);
    if ($exitCode !== 0) {
        $error = 'Unable to start the recovery diagnostic scan.';
        return false;
    }

    return true;
}
