<?php

function zfsas_migrate_trim($value)
{
    return trim((string) $value);
}

function zfsas_migrate_h($value)
{
    return htmlspecialchars((string) $value, ENT_QUOTES, 'UTF-8');
}

function zfsas_migrate_plugin_dir()
{
    return '/boot/config/plugins/zfs.autosnapshot/dataset_migrator';
}

function zfsas_migrate_logs_dir()
{
    return zfsas_migrate_plugin_dir() . '/logs';
}

function zfsas_migrate_status_file()
{
    return zfsas_migrate_plugin_dir() . '/status.env';
}

function zfsas_migrate_folders_file()
{
    return zfsas_migrate_plugin_dir() . '/folders.tsv';
}

function zfsas_migrate_containers_file()
{
    return zfsas_migrate_plugin_dir() . '/containers.tsv';
}

function zfsas_migrate_log_file()
{
    return zfsas_migrate_plugin_dir() . '/current.log';
}

function zfsas_migrate_worker_script()
{
    return '/usr/local/sbin/zfs_autosnapshot_migrate_datasets';
}

function zfsas_migrate_apply_owner($path)
{
    @chown($path, 'nobody');
    @chgrp($path, 'users');
}

function zfsas_migrate_ensure_dir($path)
{
    if (!is_dir($path)) {
        @mkdir($path, 0775, true);
    }
    @chmod($path, 0775);
    zfsas_migrate_apply_owner($path);
    return is_dir($path);
}

function zfsas_migrate_ensure_storage()
{
    return zfsas_migrate_ensure_dir(zfsas_migrate_plugin_dir())
        && zfsas_migrate_ensure_dir(zfsas_migrate_logs_dir());
}

function zfsas_migrate_kv_escape($value)
{
    $value = str_replace('\\', '\\\\', (string) $value);
    return str_replace('"', '\\"', $value);
}

function zfsas_migrate_kv_unescape($value)
{
    $value = trim((string) $value);
    if ($value !== '' && strlen($value) >= 2 && $value[0] === '"' && substr($value, -1) === '"') {
        $value = substr($value, 1, -1);
        $value = str_replace(['\\"', '\\\\'], ['"', '\\'], $value);
    }
    return $value;
}

function zfsas_migrate_read_status()
{
    $path = zfsas_migrate_status_file();
    if (!is_file($path)) {
        return [];
    }

    $lines = @file($path, FILE_IGNORE_NEW_LINES);
    if (!is_array($lines)) {
        return [];
    }

    $payload = [];
    foreach ($lines as $line) {
        if (!preg_match('/^\s*([A-Z0-9_]+)\s*=\s*(.*)$/', (string) $line, $match)) {
            continue;
        }
        $payload[$match[1]] = zfsas_migrate_kv_unescape($match[2]);
    }

    return $payload;
}

function zfsas_migrate_read_tsv_rows($path, $headers)
{
    if (!is_file($path)) {
        return [];
    }

    $lines = @file($path, FILE_IGNORE_NEW_LINES);
    if (!is_array($lines)) {
        return [];
    }

    $rows = [];
    foreach ($lines as $line) {
        if ($line === '') {
            continue;
        }
        $parts = explode("\t", (string) $line);
        $row = [];
        foreach ($headers as $index => $header) {
            $row[$header] = isset($parts[$index]) ? str_replace(["\\t", "\\n", "\\r"], ["\t", "\n", ""], $parts[$index]) : '';
        }
        $rows[] = $row;
    }

    return $rows;
}

function zfsas_migrate_is_pid_running($pid)
{
    $pid = (int) $pid;
    if ($pid <= 0) {
        return false;
    }

    if (function_exists('posix_kill')) {
        return @posix_kill($pid, 0);
    }

    @exec('kill -0 ' . $pid . ' >/dev/null 2>&1', $output, $exitCode);
    return $exitCode === 0;
}

function zfsas_migrate_current_status()
{
    $status = zfsas_migrate_read_status();
    $status['folders'] = zfsas_migrate_read_tsv_rows(zfsas_migrate_folders_file(), [
        'name',
        'sourcePath',
        'targetDataset',
        'sizeBytes',
        'state',
        'progressPercent',
        'message',
    ]);
    $status['containers'] = zfsas_migrate_read_tsv_rows(zfsas_migrate_containers_file(), [
        'id',
        'name',
        'restartName',
        'restartMax',
        'wasRunning',
        'policyDisabled',
        'startState',
        'lastError',
    ]);

    $state = (string) ($status['STATE'] ?? '');
    $pid = (int) ($status['PID'] ?? 0);
    $status['isActive'] = in_array($state, ['preparing', 'stopping_containers', 'migrating', 'waiting_for_space', 'restarting_containers', 'retrying_container_start'], true)
        && zfsas_migrate_is_pid_running($pid);

    return $status;
}

function zfsas_migrate_exec_lines($command, &$exitCode = null)
{
    $output = [];
    $exit = 0;
    @exec($command . ' 2>/dev/null', $output, $exit);
    $exitCode = $exit;
    return $output;
}

function zfsas_migrate_is_valid_dataset_name($dataset)
{
    return preg_match('/^[A-Za-z0-9._\/:+-]+$/', (string) $dataset) === 1;
}

function zfsas_migrate_is_valid_child_name($name)
{
    return preg_match('/^[A-Za-z0-9._:+-]+$/', (string) $name) === 1;
}

function zfsas_migrate_dataset_mountpoint($dataset, &$error = null)
{
    $error = null;
    $dataset = zfsas_migrate_trim($dataset);
    if ($dataset === '' || !zfsas_migrate_is_valid_dataset_name($dataset)) {
        $error = 'Dataset is invalid.';
        return '';
    }

    $command = 'zfs get -H -o value mountpoint ' . escapeshellarg($dataset);
    $lines = zfsas_migrate_exec_lines($command, $exitCode);
    if ($exitCode !== 0 || !isset($lines[0])) {
        $error = 'Unable to read dataset mountpoint.';
        return '';
    }

    $mountpoint = zfsas_migrate_trim($lines[0]);
    if ($mountpoint === '' || $mountpoint === 'none' || $mountpoint === 'legacy') {
        $error = 'Dataset does not have a normal mounted filesystem path.';
        return '';
    }

    if (!is_dir($mountpoint)) {
        $error = 'Dataset mountpoint directory is missing.';
        return '';
    }

    return $mountpoint;
}

function zfsas_migrate_list_datasets(&$error = null)
{
    $error = null;
    $rows = [];
    $lines = zfsas_migrate_exec_lines('zfs list -H -o name,mountpoint -t filesystem', $exitCode);
    if ($exitCode !== 0) {
        $error = 'Unable to list ZFS filesystem datasets.';
        return [];
    }

    foreach ($lines as $line) {
        $parts = preg_split('/\t+/', trim((string) $line));
        if (!is_array($parts) || count($parts) < 2) {
            continue;
        }

        $dataset = zfsas_migrate_trim($parts[0]);
        $mountpoint = zfsas_migrate_trim($parts[1]);
        if ($dataset === '' || $mountpoint === '' || $mountpoint === 'none' || $mountpoint === 'legacy') {
            continue;
        }
        if (!is_dir($mountpoint)) {
            continue;
        }

        $rows[] = [
            'dataset' => $dataset,
            'mountpoint' => $mountpoint,
        ];
    }

    usort($rows, function ($a, $b) {
        return strnatcasecmp((string) ($a['dataset'] ?? ''), (string) ($b['dataset'] ?? ''));
    });

    return $rows;
}

function zfsas_migrate_directory_size_bytes($path)
{
    $command = 'du -skx ' . escapeshellarg($path) . ' | awk \'{print $1 * 1024}\'';
    $lines = zfsas_migrate_exec_lines($command, $exitCode);
    if ($exitCode !== 0 || !isset($lines[0]) || !preg_match('/^[0-9]+$/', trim((string) $lines[0]))) {
        return null;
    }
    return (int) trim((string) $lines[0]);
}

function zfsas_migrate_preview_dataset($dataset, &$error = null, $includeSizes = true)
{
    $error = null;
    $mountpoint = zfsas_migrate_dataset_mountpoint($dataset, $mountError);
    if ($mountpoint === '') {
        $error = $mountError;
        return [
            'dataset' => $dataset,
            'mountpoint' => '',
            'folders' => [],
            'eligibleCount' => 0,
            'eligibleBytes' => 0,
        ];
    }

    $childDatasets = [];
    $lines = zfsas_migrate_exec_lines('zfs list -H -r -d 1 -o name -t filesystem ' . escapeshellarg($dataset), $childExit);
    if ($childExit === 0) {
        foreach ($lines as $line) {
            $name = zfsas_migrate_trim($line);
            if ($name === '' || $name === $dataset || strpos($name, $dataset . '/') !== 0) {
                continue;
            }
            $childDatasets[$name] = true;
        }
    }

    $mountMap = [];
    $allMounts = zfsas_migrate_exec_lines('zfs list -H -o name,mountpoint -t filesystem', $mountExit);
    if ($mountExit === 0) {
        foreach ($allMounts as $line) {
            $parts = preg_split('/\t+/', trim((string) $line));
            if (!is_array($parts) || count($parts) < 2) {
                continue;
            }
            $mountMap[zfsas_migrate_trim($parts[1])] = zfsas_migrate_trim($parts[0]);
        }
    }

    $rows = [];
    $eligibleCount = 0;
    $eligibleBytes = 0;

    try {
        $iterator = new DirectoryIterator($mountpoint);
    } catch (Throwable $exception) {
        $error = 'Unable to scan the selected dataset path.';
        return [
            'dataset' => $dataset,
            'mountpoint' => $mountpoint,
            'folders' => [],
            'eligibleCount' => 0,
            'eligibleBytes' => 0,
        ];
    }

    foreach ($iterator as $entry) {
        if ($entry->isDot()) {
            continue;
        }
        if (!$entry->isDir() || $entry->isLink()) {
            continue;
        }

        $name = $entry->getFilename();
        $path = $entry->getPathname();
        $targetDataset = $dataset . '/' . $name;
        $sizeBytes = $includeSizes ? zfsas_migrate_directory_size_bytes($path) : null;
        $state = 'eligible';
        $message = 'Will be migrated into its own child dataset.';
        $eligible = true;

        if (strpos($name, '.__migration_tmp__.') !== false) {
            $state = 'temp_leftover';
            $message = 'Leftover temporary directory from an earlier migration attempt.';
            $eligible = false;
        } elseif (!zfsas_migrate_is_valid_child_name($name)) {
            $state = 'invalid_name';
            $message = 'Folder name is not a safe ZFS child dataset name.';
            $eligible = false;
        } elseif (!empty($childDatasets[$targetDataset])) {
            $state = 'already_dataset';
            $message = 'Already mounted as its own child dataset.';
            $eligible = false;
        } elseif (!empty($mountMap[$path]) && $mountMap[$path] !== $dataset) {
            $state = 'mounted_elsewhere';
            $message = 'Path is already occupied by a different mounted dataset.';
            $eligible = false;
        } else {
            foreach ($mountMap as $otherMountpoint => $otherDataset) {
                if ($otherMountpoint === '' || $otherMountpoint === 'none' || $otherMountpoint === 'legacy') {
                    continue;
                }
                if (strpos($otherMountpoint, $path . '/') === 0) {
                    $state = 'nested_mount';
                    $message = 'Contains a nested mount or child dataset, so it is not safe to migrate automatically.';
                    $eligible = false;
                    break;
                }
            }
        }

        if ($eligible) {
            $eligibleCount += 1;
            if ($includeSizes && $sizeBytes !== null) {
                $eligibleBytes += (int) $sizeBytes;
            }
        }

        $rows[] = [
            'name' => $name,
            'path' => $path,
            'targetDataset' => $targetDataset,
            'sizeBytes' => $sizeBytes,
            'state' => $state,
            'message' => $message,
            'eligible' => $eligible,
        ];
    }

    usort($rows, function ($a, $b) {
        return strnatcasecmp((string) ($a['name'] ?? ''), (string) ($b['name'] ?? ''));
    });

    return [
        'dataset' => $dataset,
        'mountpoint' => $mountpoint,
        'folders' => $rows,
        'eligibleCount' => $eligibleCount,
        'eligibleBytes' => $eligibleBytes,
    ];
}

function zfsas_migrate_reset_runtime_files()
{
    $paths = [
        zfsas_migrate_status_file(),
        zfsas_migrate_folders_file(),
        zfsas_migrate_containers_file(),
        zfsas_migrate_log_file(),
    ];

    foreach ($paths as $path) {
        if (is_file($path)) {
            @unlink($path);
        }
    }
}

function zfsas_migrate_startup_error_message()
{
    $status = zfsas_migrate_read_status();
    $message = zfsas_migrate_trim($status['LAST_ERROR'] ?? $status['MESSAGE'] ?? '');
    if ($message !== '') {
        return $message;
    }

    $logLines = zfsas_migrate_status_log_tail(10);
    if (!empty($logLines)) {
        return zfsas_migrate_trim((string) end($logLines));
    }

    return '';
}

function zfsas_migrate_wait_for_start($dataset, $pid, &$error = null)
{
    $error = null;
    $deadline = microtime(true) + 3.0;
    $dataset = zfsas_migrate_trim($dataset);
    $pid = (int) $pid;

    while (microtime(true) < $deadline) {
        clearstatcache();
        $status = zfsas_migrate_current_status();
        $statusDataset = zfsas_migrate_trim($status['DATASET'] ?? '');
        $statusState = zfsas_migrate_trim($status['STATE'] ?? '');

        if ($statusDataset === $dataset && $statusState !== '') {
            return true;
        }

        if ($pid > 0 && zfsas_migrate_is_pid_running($pid)) {
            usleep(200000);
            continue;
        }

        $error = zfsas_migrate_startup_error_message();
        if ($error === '') {
            $error = 'Dataset migrator exited before it reported startup status.';
        }
        return false;
    }

    $status = zfsas_migrate_current_status();
    if (zfsas_migrate_trim($status['DATASET'] ?? '') === $dataset && zfsas_migrate_trim($status['STATE'] ?? '') !== '') {
        return true;
    }

    if ($pid > 0 && zfsas_migrate_is_pid_running($pid)) {
        return true;
    }

    $error = zfsas_migrate_startup_error_message();
    if ($error === '') {
        $error = 'Dataset migrator did not report startup status in time.';
    }
    return false;
}

function zfsas_migrate_docker_preflight()
{
    if (!is_file('/usr/bin/docker') && !is_file('/usr/local/bin/docker') && !is_file('/bin/docker')) {
        return [
            'daemonRunning' => false,
            'runningContainers' => [],
            'riskyRestartContainers' => [],
            'error' => 'Docker CLI is not available on this system.',
        ];
    }

    zfsas_migrate_exec_lines('docker info', $infoExit);
    if ($infoExit !== 0) {
        return [
            'daemonRunning' => false,
            'runningContainers' => [],
            'riskyRestartContainers' => [],
            'error' => null,
        ];
    }

    $ids = zfsas_migrate_exec_lines('docker ps -q', $psExit);
    if ($psExit !== 0) {
        return [
            'daemonRunning' => true,
            'runningContainers' => [],
            'riskyRestartContainers' => [],
            'error' => 'Unable to query running containers.',
        ];
    }

    $running = [];
    $risky = [];
    foreach ($ids as $id) {
        $id = zfsas_migrate_trim($id);
        if ($id === '') {
            continue;
        }

        $inspect = zfsas_migrate_exec_lines(
            'docker inspect -f ' . escapeshellarg('{{.Id}}|{{.Name}}|{{.HostConfig.RestartPolicy.Name}}|{{.HostConfig.RestartPolicy.MaximumRetryCount}}') . ' ' . escapeshellarg($id),
            $inspectExit
        );
        if ($inspectExit !== 0 || !isset($inspect[0])) {
            continue;
        }

        $parts = explode('|', (string) $inspect[0]);
        $row = [
            'id' => $parts[0] ?? $id,
            'name' => ltrim((string) ($parts[1] ?? $id), '/'),
            'restartName' => $parts[2] ?? 'no',
            'restartMax' => $parts[3] ?? '0',
        ];
        $running[] = $row;
        if (($row['restartName'] ?? 'no') !== 'no') {
            $risky[] = $row;
        }
    }

    usort($running, function ($a, $b) {
        return strnatcasecmp((string) ($a['name'] ?? ''), (string) ($b['name'] ?? ''));
    });
    usort($risky, function ($a, $b) {
        return strnatcasecmp((string) ($a['name'] ?? ''), (string) ($b['name'] ?? ''));
    });

    return [
        'daemonRunning' => true,
        'runningContainers' => $running,
        'riskyRestartContainers' => $risky,
        'error' => null,
    ];
}

function zfsas_migrate_status_log_tail($lineCount = 40)
{
    $path = zfsas_migrate_log_file();
    if (!is_file($path)) {
        return [];
    }

    $lineCount = max(1, min(200, (int) $lineCount));
    $lines = zfsas_migrate_exec_lines('tail -n ' . $lineCount . ' ' . escapeshellarg($path), $exitCode);
    if ($exitCode !== 0) {
        return [];
    }

    return array_values(array_filter(array_map('rtrim', $lines), static function ($line) {
        return $line !== '';
    }));
}

function zfsas_migrate_start($dataset, &$error = null)
{
    $error = null;

    if (!zfsas_migrate_ensure_storage()) {
        $error = 'Dataset migrator storage is unavailable.';
        return false;
    }

    $dataset = zfsas_migrate_trim($dataset);
    if ($dataset === '' || !zfsas_migrate_is_valid_dataset_name($dataset)) {
        $error = 'Dataset is invalid.';
        return false;
    }

    $current = zfsas_migrate_current_status();
    if (!empty($current['isActive'])) {
        $error = 'A dataset migration is already running.';
        return false;
    }

    $preview = zfsas_migrate_preview_dataset($dataset, $previewError, false);
    if ($previewError !== null) {
        $error = $previewError;
        return false;
    }

    if ((int) ($preview['eligibleCount'] ?? 0) <= 0) {
        $error = 'No eligible top-level folders were found under the selected dataset.';
        return false;
    }

    $worker = zfsas_migrate_worker_script();
    if (!is_file($worker) || !is_executable($worker)) {
        $error = 'Dataset migrator worker is missing or not executable.';
        return false;
    }

    zfsas_migrate_reset_runtime_files();

    $command = 'nohup ' . escapeshellarg($worker)
        . ' --dataset ' . escapeshellarg($dataset)
        . ' > /dev/null 2>&1 < /dev/null & echo $!';

    $output = [];
    $exitCode = 0;
    @exec($command, $output, $exitCode);
    if ($exitCode !== 0) {
        $error = 'Unable to start the dataset migrator.';
        return false;
    }

    $pid = 0;
    if (!empty($output)) {
        $pid = (int) zfsas_migrate_trim((string) end($output));
    }

    return zfsas_migrate_wait_for_start($dataset, $pid, $error);
}
