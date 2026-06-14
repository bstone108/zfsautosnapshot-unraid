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

function zfsas_recovery_scan_results_path($dataset)
{
    return zfsas_recovery_scans_dir() . '/' . zfsas_recovery_dataset_key($dataset) . '-results.txt';
}

function zfsas_recovery_scan_stop_path($dataset)
{
    return zfsas_recovery_scans_dir() . '/' . zfsas_recovery_dataset_key($dataset) . '.stop';
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

function zfsas_recovery_send_config_path()
{
    return '/boot/config/plugins/zfs.autosnapshot/zfs_send.conf';
}

function zfsas_recovery_unquote_config_value($value)
{
    $value = zfsas_recovery_trim($value);
    if (strlen($value) >= 2 && $value[0] === '"' && substr($value, -1) === '"') {
        $value = substr($value, 1, -1);
        $value = str_replace(['\\"', '\\\\'], ['"', '\\'], $value);
    }
    return $value;
}

function zfsas_recovery_parse_send_jobs_string($jobsRaw)
{
    $jobs = [];
    foreach (explode(';', (string) $jobsRaw) as $part) {
        $entry = zfsas_recovery_trim($part);
        if ($entry === '') {
            continue;
        }
        $pieces = explode('|', $entry);
        if (count($pieces) !== 5 && count($pieces) !== 6) {
            continue;
        }
        $source = zfsas_recovery_trim($pieces[1] ?? '');
        $destination = zfsas_recovery_trim($pieces[2] ?? '');
        if ($source === '' || $destination === '') {
            continue;
        }
        $jobs[] = [
            'source' => $source,
            'destination' => $destination,
            'children' => zfsas_recovery_trim($pieces[5] ?? '0') === '1' ? '1' : '0',
        ];
    }
    return $jobs;
}

function zfsas_recovery_read_send_jobs($configPath = null)
{
    $configPath = $configPath ?: zfsas_recovery_send_config_path();
    if (!is_file($configPath)) {
        return [];
    }
    $lines = @file($configPath, FILE_IGNORE_NEW_LINES);
    if (!is_array($lines)) {
        return [];
    }
    foreach ($lines as $line) {
        $trimmed = zfsas_recovery_trim($line);
        if ($trimmed === '' || $trimmed[0] === '#') {
            continue;
        }
        if (strpos($trimmed, 'SEND_JOBS=') === 0) {
            return zfsas_recovery_parse_send_jobs_string(zfsas_recovery_unquote_config_value(substr($trimmed, strlen('SEND_JOBS='))));
        }
    }
    return [];
}

function zfsas_recovery_normalize_path($path)
{
    $path = str_replace('\\', '/', zfsas_recovery_trim($path));
    $path = preg_replace('#/+#', '/', $path);
    if ($path !== '/' && substr($path, -1) === '/') {
        $path = rtrim($path, '/');
    }
    return $path;
}

function zfsas_recovery_relative_path_for_dataset($filePath, $mountpoint)
{
    $filePath = zfsas_recovery_normalize_path($filePath);
    $mountpoint = zfsas_recovery_normalize_path($mountpoint);
    if ($filePath === '' || $mountpoint === '' || $mountpoint === 'legacy' || $mountpoint === 'none') {
        return null;
    }
    if (strpos($filePath . '/', $mountpoint . '/') !== 0) {
        return null;
    }
    $relative = ltrim(substr($filePath, strlen($mountpoint)), '/');
    return $relative === '' ? null : $relative;
}

function zfsas_recovery_original_path_from_snapshot_evidence($filePath, $mountpoint)
{
    $filePath = zfsas_recovery_normalize_path($filePath);
    $mountpoint = zfsas_recovery_normalize_path($mountpoint);
    if ($filePath === '' || $mountpoint === '' || $mountpoint === 'legacy' || $mountpoint === 'none') {
        return null;
    }

    $snapshotPrefix = $mountpoint . '/.zfs/snapshot/';
    if (strpos($filePath, $snapshotPrefix) !== 0) {
        return null;
    }

    $afterPrefix = substr($filePath, strlen($snapshotPrefix));
    $slash = strpos($afterPrefix, '/');
    if ($slash === false) {
        return null;
    }

    $relative = ltrim(substr($afterPrefix, $slash + 1), '/');
    if ($relative === '') {
        return null;
    }

    return $mountpoint . '/' . $relative;
}

function zfsas_recovery_dataset_mountpoint_map($datasetRows)
{
    $map = [];
    foreach ($datasetRows as $row) {
        $dataset = zfsas_recovery_trim($row['dataset'] ?? '');
        $mountpoint = zfsas_recovery_normalize_path($row['mountpoint'] ?? '');
        if ($dataset !== '' && $mountpoint !== '' && $mountpoint !== 'legacy' && $mountpoint !== 'none') {
            $map[$dataset] = $mountpoint;
        }
    }
    return $map;
}

function zfsas_recovery_dataset_for_path($filePath, $datasetRows)
{
    $filePath = zfsas_recovery_normalize_path($filePath);
    $bestDataset = '';
    $bestLength = -1;
    foreach (zfsas_recovery_dataset_mountpoint_map($datasetRows) as $dataset => $mountpoint) {
        if (strpos($filePath . '/', $mountpoint . '/') !== 0) {
            continue;
        }
        $length = strlen($mountpoint);
        if ($length > $bestLength) {
            $bestDataset = $dataset;
            $bestLength = $length;
        }
    }
    return $bestDataset;
}

function zfsas_recovery_send_destination_for_source($sourceDataset, $sendJobs)
{
    $sourceDataset = zfsas_recovery_trim($sourceDataset);
    foreach ($sendJobs as $job) {
        $source = zfsas_recovery_trim($job['source'] ?? '');
        $destination = zfsas_recovery_trim($job['destination'] ?? '');
        if ($source === '' || $destination === '') {
            continue;
        }
        if ($sourceDataset === $source) {
            return $destination;
        }
        if (($job['children'] ?? '0') === '1' && strpos($sourceDataset . '/', $source . '/') === 0) {
            return $destination . substr($sourceDataset, strlen($source));
        }
    }
    return null;
}

function zfsas_recovery_candidate_from_path($type, $dataset, $snapshot, $path)
{
    if (!is_file($path) || !is_readable($path)) {
        return null;
    }
    $size = @filesize($path);
    $sha256 = @hash_file('sha256', $path);
    if ($size === false || !is_string($sha256) || $sha256 === '') {
        return null;
    }
    return [
        'type' => $type,
        'dataset' => $dataset,
        'snapshot' => $snapshot,
        'path' => $path,
        'readable' => true,
        'sizeBytes' => (int) $size,
        'sha256' => $sha256,
    ];
}

function zfsas_recovery_snapshot_candidates($type, $dataset, $mountpoint, $relativePath)
{
    $candidates = [];
    $snapshotRoot = zfsas_recovery_normalize_path($mountpoint) . '/.zfs/snapshot';
    $dirs = glob($snapshotRoot . '/*', GLOB_ONLYDIR);
    if (!is_array($dirs)) {
        return [];
    }
    natsort($dirs);
    foreach ($dirs as $dir) {
        $snapshot = basename($dir);
        $candidatePath = zfsas_recovery_normalize_path($dir . '/' . $relativePath);
        $candidate = zfsas_recovery_candidate_from_path($type, $dataset, $snapshot, $candidatePath);
        if (is_array($candidate)) {
            $candidates[] = $candidate;
        }
    }
    return $candidates;
}

function zfsas_recovery_discover_clean_copies_for_option($option, $datasetRows, $sendJobs = null)
{
    $option['actionsEnabled'] = false;
    $option['requiresConfirmation'] = true;
    $option['cleanCandidates'] = [];

    $dataset = zfsas_recovery_trim($option['dataset'] ?? '');
    $evidencePath = zfsas_recovery_normalize_path($option['path'] ?? '');
    $path = $evidencePath;
    $mountpoints = zfsas_recovery_dataset_mountpoint_map($datasetRows);
    if ($dataset === '' || !isset($mountpoints[$dataset])) {
        $option['state'] = 'blocked';
        $option['message'] = 'Select a mounted dataset for this affected file before recovery candidates can be discovered.';
        return $option;
    }

    $originalPath = zfsas_recovery_original_path_from_snapshot_evidence($path, $mountpoints[$dataset]);
    if ($originalPath !== null) {
        $path = $originalPath;
        $option['snapshotEvidencePath'] = $evidencePath;
    }
    $option['path'] = $path;

    $relativePath = zfsas_recovery_relative_path_for_dataset($path, $mountpoints[$dataset]);
    if ($relativePath === null) {
        $option['state'] = 'blocked';
        $option['message'] = 'Affected file is outside the mounted dataset path; recovery candidates were not guessed.';
        return $option;
    }
    $option['relativePath'] = $relativePath;

    $sendJobs = is_array($sendJobs) ? $sendJobs : zfsas_recovery_read_send_jobs();
    $candidates = zfsas_recovery_snapshot_candidates('local_snapshot', $dataset, $mountpoints[$dataset], $relativePath);
    $destinationDataset = zfsas_recovery_send_destination_for_source($dataset, $sendJobs);
    if ($destinationDataset !== null && isset($mountpoints[$destinationDataset])) {
        $sendCandidates = zfsas_recovery_snapshot_candidates('send_destination_snapshot', $destinationDataset, $mountpoints[$destinationDataset], $relativePath);
        $candidates = array_merge($candidates, $sendCandidates);
    }

    $option['cleanCandidates'] = array_values(array_filter($candidates, function ($candidate) use ($evidencePath) {
        return zfsas_recovery_normalize_path($candidate['path'] ?? '') !== $evidencePath;
    }));
    if (!empty($option['cleanCandidates'])) {
        $option['state'] = 'ready';
        $option['actionsEnabled'] = true;
        $option['message'] = count($option['cleanCandidates']) . ' readable recovery candidate(s) found. Select a guarded recovery action and enter the exact confirmation token before data changes.';
    } else {
        $option['state'] = 'no_candidates';
        $option['actionsEnabled'] = true;
        $option['message'] = 'No readable local snapshot or ZFS send-destination copies were found yet for this affected file. Aggressive read and delete remain available only through explicit confirmation.';
    }
    return $option;
}

function zfsas_recovery_require_confirmation($request, $expected, &$error)
{
    $actual = strtoupper(zfsas_recovery_trim($request['confirmation'] ?? ''));
    if ($actual !== $expected) {
        $error = 'Explicit ' . $expected . ' confirmation is required before this recovery action can run.';
        return false;
    }
    return true;
}

function zfsas_recovery_find_discovered_candidate($option, $candidateSha256)
{
    $candidateSha256 = strtolower(zfsas_recovery_trim($candidateSha256));
    if ($candidateSha256 === '') {
        return null;
    }
    foreach (($option['cleanCandidates'] ?? []) as $candidate) {
        if (strtolower((string) ($candidate['sha256'] ?? '')) === $candidateSha256) {
            return $candidate;
        }
    }
    return null;
}

function zfsas_recovery_perform_guarded_action($request, $datasetRows, $sendJobs = null, &$error = null)
{
    $error = null;
    $action = zfsas_recovery_trim($request['recovery_action'] ?? '');
    $dataset = zfsas_recovery_trim($request['dataset'] ?? '');
    $path = zfsas_recovery_normalize_path($request['path'] ?? '');

    if ($action === '' || $dataset === '' || $path === '') {
        $error = 'Recovery action, dataset, and affected file path are required.';
        return false;
    }

    $option = zfsas_recovery_discover_clean_copies_for_option([
        'dataset' => $dataset,
        'path' => $path,
        'source' => 'recovery action request',
    ], $datasetRows, $sendJobs);

    if (($option['state'] ?? '') === 'blocked') {
        $error = $option['message'] ?? 'Affected file is not eligible for recovery actions.';
        return false;
    }

    if ($action === 'aggressive_read') {
        if (!zfsas_recovery_require_confirmation($request, 'READ', $error)) {
            return false;
        }
        if (!is_file($path) || !is_readable($path)) {
            $error = 'Affected file is not readable for aggressive read.';
            return false;
        }
        $sha256 = @hash_file('sha256', $path);
        $size = @filesize($path);
        if (!is_string($sha256) || $sha256 === '' || $size === false) {
            $error = 'Unable to complete a bounded read of the affected file.';
            return false;
        }
        return [
            'ok' => true,
            'action' => $action,
            'message' => 'Aggressive read completed. Compare the hash with known-good copies before trusting the file.',
            'sha256' => $sha256,
            'sizeBytes' => (int) $size,
        ];
    }

    if ($action === 'restore_clean_copy') {
        if (!zfsas_recovery_require_confirmation($request, 'RESTORE', $error)) {
            return false;
        }
        $candidate = zfsas_recovery_find_discovered_candidate($option, $request['candidate_sha256'] ?? '');
        if (!is_array($candidate)) {
            $error = 'Selected clean-copy candidate was not discovered for this affected file.';
            return false;
        }
        $candidatePath = zfsas_recovery_normalize_path($candidate['path'] ?? '');
        if (!is_file($candidatePath) || !is_readable($candidatePath)) {
            $error = 'Selected clean-copy candidate is no longer readable.';
            return false;
        }
        if (@copy($candidatePath, $path) !== true) {
            $error = 'Unable to restore the selected clean-copy candidate.';
            return false;
        }
        return [
            'ok' => true,
            'action' => $action,
            'message' => 'Selected clean-copy candidate was restored to the affected file path.',
            'candidate' => $candidate,
        ];
    }

    if ($action === 'delete_file') {
        if (!zfsas_recovery_require_confirmation($request, 'DELETE', $error)) {
            return false;
        }
        if (!is_file($path)) {
            $error = 'Affected file is not present for deletion.';
            return false;
        }
        if (@unlink($path) !== true) {
            $error = 'Unable to delete the affected file.';
            return false;
        }
        return [
            'ok' => true,
            'action' => $action,
            'message' => 'Affected file was deleted after explicit confirmation.',
        ];
    }

    $error = 'Unknown guarded recovery action.';
    return false;
}

function zfsas_recovery_option_candidates($poolStatus = null, $scans = null, $datasetRows = null, $sendJobs = null)
{
    if (!is_array($poolStatus)) {
        $poolStatus = zfsas_recovery_pool_status();
    }
    if (!is_array($scans)) {
        $scans = zfsas_recovery_list_scans();
    }
    $datasetRows = is_array($datasetRows) ? $datasetRows : zfsas_recovery_list_datasets($ignoredError);
    $sendJobs = is_array($sendJobs) ? $sendJobs : zfsas_recovery_read_send_jobs();

    $rows = [];
    $seen = [];
    $actionTypes = ["aggressive_read", "snapshot_restore", "send_destination_restore", "delete_file"];
    $addCandidate = function ($dataset, $path, $source, $state = 'searching') use (&$rows, &$seen, $actionTypes, $datasetRows) {
        $path = zfsas_recovery_trim($path);
        if ($path === '') {
            return;
        }
        $dataset = zfsas_recovery_trim($dataset);
        if ($dataset === '') {
            $dataset = zfsas_recovery_dataset_for_path($path, $datasetRows);
        }
        $key = strtolower($dataset . "\n" . $path . "\n" . $source);
        if (isset($seen[$key])) {
            return;
        }
        $seen[$key] = true;
        $rows[] = [
            'dataset' => $dataset,
            'path' => $path,
            'source' => $source,
            'state' => $state,
            'message' => 'Searching snapshots and ZFS send destinations for clean recovery candidates.',
            'actionTypes' => $actionTypes,
            'actionsEnabled' => false,
            'requiresConfirmation' => true,
        ];
    };

    foreach (($poolStatus['pools'] ?? []) as $pool) {
        foreach (($pool['identifiedFiles'] ?? []) as $path) {
            $addCandidate('', $path, 'zpool status');
        }
    }

    foreach ($scans as $scan) {
        $dataset = (string) ($scan['dataset'] ?? '');
        $resultsFile = (string) ($scan['resultsFile'] ?? '');
        if ($resultsFile !== '' && is_file($resultsFile)) {
            $lines = @file($resultsFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
            if (is_array($lines)) {
                foreach ($lines as $line) {
                    $addCandidate($dataset, $line, 'manual readability scan');
                }
            }
        }
        if ((int) ($scan['unreadableCount'] ?? 0) > 0 && empty($rows) && (string) ($scan['lastPath'] ?? '') !== '') {
            $addCandidate($dataset, (string) $scan['lastPath'], 'manual readability scan');
        }
    }

    if (!empty($rows)) {
        foreach ($rows as $index => $row) {
            $rows[$index] = zfsas_recovery_discover_clean_copies_for_option($row, $datasetRows, $sendJobs);
        }
    }

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

function zfsas_recovery_clear_scan($dataset, &$error = null)
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

    $statusPath = zfsas_recovery_scan_status_path($dataset);
    $payload = zfsas_recovery_read_json_file($statusPath);
    if (!is_array($payload)) {
        $error = 'No manual diagnostic scan is recorded for that dataset.';
        return false;
    }

    if (in_array((string) ($payload['state'] ?? ''), ['queued', 'running'], true)) {
        $error = 'A diagnostic scan is still queued or running for that dataset.';
        return false;
    }

    $resultsFile = (string) ($payload['resultsFile'] ?? '');
    if ($resultsFile === '' || dirname($resultsFile) !== zfsas_recovery_scans_dir()) {
        $resultsFile = zfsas_recovery_scan_results_path($dataset);
    }
    $stopFile = zfsas_recovery_scan_stop_path($dataset);

    if (is_file($resultsFile) && !@unlink($resultsFile)) {
        $error = 'Unable to remove the manual diagnostic scan result file.';
        return false;
    }
    if (is_file($stopFile)) {
        @unlink($stopFile);
    }
    if (is_file($statusPath) && !@unlink($statusPath)) {
        $error = 'Unable to remove the manual diagnostic scan status file.';
        return false;
    }

    return true;
}
