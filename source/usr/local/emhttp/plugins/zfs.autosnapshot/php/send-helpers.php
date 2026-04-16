<?php

function zfsas_send_trim($value)
{
    return trim((string) $value);
}

function zfsas_send_h($value)
{
    return htmlspecialchars((string) $value, ENT_QUOTES, 'UTF-8');
}

function zfsas_send_is_valid_dataset_name($dataset)
{
    return preg_match('/^[A-Za-z0-9._\/:+-]+$/', (string) $dataset) === 1;
}

function zfsas_send_dataset_pool_name($dataset)
{
    $dataset = zfsas_send_trim($dataset);
    if ($dataset === '') {
        return '';
    }

    $parts = explode('/', $dataset, 2);
    return $parts[0];
}

function zfsas_send_normalize_threshold($value)
{
    $value = strtoupper(str_replace(' ', '', trim((string) $value)));
    if (preg_match('/^([0-9]+)([KMGT])B?$/', $value, $match) !== 1) {
        return null;
    }

    return $match[1] . $match[2];
}

function zfsas_send_frequency_options()
{
    return [
        '15m' => 'Every 15 minutes',
        '30m' => 'Every 30 minutes',
        '1h' => 'Every hour',
        '6h' => 'Every 6 hours',
        '12h' => 'Every 12 hours',
        '1d' => 'Every day',
        '7d' => 'Every week',
    ];
}

function zfsas_send_normalize_frequency($value)
{
    $value = strtolower(trim((string) $value));
    $options = zfsas_send_frequency_options();
    return array_key_exists($value, $options) ? $value : null;
}

function zfsas_send_frequency_label($value)
{
    $options = zfsas_send_frequency_options();
    return $options[$value] ?? $value;
}

function zfsas_send_job_id($source, $destination)
{
    return substr(sha1(strtolower(trim((string) $source) . "|" . trim((string) $destination))), 0, 12);
}

function zfsas_send_paths_overlap($source, $destination)
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

function zfsas_send_normalize_children_flag($value)
{
    if (is_bool($value)) {
        return $value ? '1' : '0';
    }

    $value = strtolower(trim((string) $value));
    if (in_array($value, ['1', 'true', 'yes', 'on'], true)) {
        return '1';
    }

    return '0';
}

function zfsas_send_normalize_parallel_limit($value)
{
    $value = (int) $value;
    if ($value < 1) {
        $value = 1;
    }
    if ($value > 8) {
        $value = 8;
    }
    return (string) $value;
}

function zfsas_send_defaults()
{
    return [
        'SEND_SNAPSHOT_PREFIX' => 'zfs-send-',
        'SEND_MAX_PARALLEL' => '1',
        'SEND_JOBS' => '',
    ];
}

function zfsas_send_is_ajax_request()
{
    if (($_POST['ajax'] ?? '') === 'save') {
        return true;
    }

    $requestedWith = $_SERVER['HTTP_X_REQUESTED_WITH'] ?? '';
    return is_string($requestedWith) && strcasecmp($requestedWith, 'XMLHttpRequest') === 0;
}

function zfsas_send_current_page_url($fallback)
{
    $requestUri = (string) ($_SERVER['REQUEST_URI'] ?? '');
    if ($requestUri === '') {
        return $fallback;
    }

    $parts = parse_url($requestUri);
    if (!is_array($parts)) {
        return $fallback;
    }

    $path = (string) ($parts['path'] ?? '');
    if ($path === '') {
        return $fallback;
    }

    $query = [];
    if (isset($parts['query'])) {
        parse_str((string) $parts['query'], $query);
    }
    unset($query['saved']);

    $queryString = http_build_query($query);
    return ($queryString === '') ? $path : ($path . '?' . $queryString);
}

function zfsas_send_render_jobs_string($jobs)
{
    $parts = [];
    foreach ($jobs as $job) {
        $parts[] = implode('|', [
            $job['id'],
            $job['source'],
            $job['destination'],
            $job['frequency'],
            $job['threshold'],
            $job['children'] ?? '0',
        ]);
    }

    return implode(';', $parts);
}

function zfsas_send_parse_config_file($path, $defaults)
{
    $config = $defaults;

    if (!is_file($path)) {
        return $config;
    }

    $lines = @file($path, FILE_IGNORE_NEW_LINES);
    if (!is_array($lines)) {
        return $config;
    }

    foreach ($lines as $line) {
        if (!preg_match('/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/', $line, $match)) {
            continue;
        }

        $key = $match[1];
        $raw = trim($match[2]);
        if (!array_key_exists($key, $config)) {
            continue;
        }

        if ($raw === '') {
            $config[$key] = '';
            continue;
        }

        if ($raw[0] === '"' && substr($raw, -1) === '"' && strlen($raw) >= 2) {
            $raw = substr($raw, 1, -1);
            $raw = str_replace(['\\"', '\\\\'], ['"', '\\'], $raw);
            $config[$key] = $raw;
            continue;
        }

        if ($raw[0] === "'" && substr($raw, -1) === "'" && strlen($raw) >= 2) {
            $config[$key] = substr($raw, 1, -1);
            continue;
        }

        $config[$key] = $raw;
    }

    return $config;
}

function zfsas_send_quote_config_string($value)
{
    $value = str_replace('\\', '\\\\', (string) $value);
    $value = str_replace('"', '\\"', $value);
    return '"' . $value . '"';
}

function zfsas_send_parse_jobs($jobsRaw, &$errors = [], &$warnings = [])
{
    $errors = [];
    $warnings = [];
    $jobs = [];
    $seen = [];

    $parts = explode(';', (string) $jobsRaw);
    foreach ($parts as $part) {
        $entry = trim($part);
        if ($entry === '') {
            continue;
        }

        $pieces = explode('|', $entry);
        if (count($pieces) !== 5 && count($pieces) !== 6) {
            $warnings[] = "Ignoring invalid SEND_JOBS entry '{$entry}'.";
            continue;
        }

        $jobIdRaw = $pieces[0] ?? '';
        $sourceRaw = $pieces[1] ?? '';
        $destinationRaw = $pieces[2] ?? '';
        $frequencyRaw = $pieces[3] ?? '';
        $thresholdRaw = $pieces[4] ?? '';
        $childrenRaw = $pieces[5] ?? '0';
        $jobId = zfsas_send_trim($jobIdRaw);
        $source = zfsas_send_trim($sourceRaw);
        $destination = zfsas_send_trim($destinationRaw);
        $frequency = zfsas_send_normalize_frequency($frequencyRaw);
        $threshold = zfsas_send_normalize_threshold($thresholdRaw);
        $children = zfsas_send_normalize_children_flag($childrenRaw);

        if ($jobId === '' || preg_match('/^[a-f0-9]{12}$/', $jobId) !== 1) {
            $warnings[] = "Ignoring invalid ZFS send job id '{$jobIdRaw}'.";
            continue;
        }

        if (!zfsas_send_is_valid_dataset_name($source) || !zfsas_send_is_valid_dataset_name($destination)) {
            $warnings[] = "Ignoring invalid ZFS send job '{$entry}'.";
            continue;
        }

        if ($source === $destination) {
            $warnings[] = "Ignoring ZFS send job '{$source}' because source and destination match.";
            continue;
        }

        if (zfsas_send_dataset_pool_name($source) === zfsas_send_dataset_pool_name($destination)
            && zfsas_send_paths_overlap($source, $destination)
        ) {
            $warnings[] = "Ignoring ZFS send job '{$source}' -> '{$destination}' because the datasets overlap on the same pool.";
            continue;
        }

        if ($frequency === null) {
            $warnings[] = "Ignoring ZFS send job '{$entry}' because the frequency is invalid.";
            continue;
        }

        if ($threshold === null) {
            $warnings[] = "Ignoring ZFS send job '{$entry}' because the destination free-space target is invalid.";
            continue;
        }

        if (isset($seen[$jobId])) {
            $warnings[] = "Ignoring duplicate ZFS send job '{$source}' -> '{$destination}'.";
            continue;
        }

        $jobs[] = [
            'id' => $jobId,
            'source' => $source,
            'destination' => $destination,
            'destination_pool' => zfsas_send_dataset_pool_name($destination),
            'frequency' => $frequency,
            'frequency_label' => zfsas_send_frequency_label($frequency),
            'threshold' => $threshold,
            'children' => $children,
        ];
        $seen[$jobId] = true;
    }

    usort($jobs, function ($a, $b) {
        $sourceCompare = strnatcasecmp((string) ($a['source'] ?? ''), (string) ($b['source'] ?? ''));
        if ($sourceCompare !== 0) {
            return $sourceCompare;
        }

        return strnatcasecmp((string) ($a['destination'] ?? ''), (string) ($b['destination'] ?? ''));
    });

    return $jobs;
}

function zfsas_send_collect_submitted_jobs($post, &$errors)
{
    $jobs = [];
    $seenJobIds = [];

    $jobIds = (isset($post['job_id']) && is_array($post['job_id'])) ? $post['job_id'] : [];
    $sources = (isset($post['job_source']) && is_array($post['job_source'])) ? $post['job_source'] : [];
    $destinations = (isset($post['job_destination']) && is_array($post['job_destination'])) ? $post['job_destination'] : [];
    $frequencies = (isset($post['job_frequency']) && is_array($post['job_frequency'])) ? $post['job_frequency'] : [];
    $thresholds = (isset($post['job_threshold']) && is_array($post['job_threshold'])) ? $post['job_threshold'] : [];
    $childrenFlags = (isset($post['job_children']) && is_array($post['job_children'])) ? $post['job_children'] : [];
    $removes = (isset($post['job_remove']) && is_array($post['job_remove'])) ? $post['job_remove'] : [];

    foreach ($sources as $index => $sourceRaw) {
        if (isset($removes[$index]) && (string) $removes[$index] === '1') {
            continue;
        }

        $source = zfsas_send_trim($sourceRaw);
        $destination = zfsas_send_trim($destinations[$index] ?? '');
        $frequency = zfsas_send_normalize_frequency($frequencies[$index] ?? '');
        $threshold = zfsas_send_normalize_threshold($thresholds[$index] ?? '');
        $children = zfsas_send_normalize_children_flag($childrenFlags[$index] ?? '0');
        $jobId = zfsas_send_trim($jobIds[$index] ?? '');

        if ($source === '' && $destination === '') {
            continue;
        }

        if (!zfsas_send_is_valid_dataset_name($source)) {
            $errors[] = "Invalid source dataset '{$source}'.";
            continue;
        }

        if (!zfsas_send_is_valid_dataset_name($destination)) {
            $errors[] = "Invalid destination dataset '{$destination}'.";
            continue;
        }

        if ($source === $destination) {
            $errors[] = "Source and destination must be different for '{$source}'.";
            continue;
        }

        if (zfsas_send_dataset_pool_name($source) === zfsas_send_dataset_pool_name($destination)
            && zfsas_send_paths_overlap($source, $destination)
        ) {
            $errors[] = "Source '{$source}' and destination '{$destination}' overlap on the same pool.";
            continue;
        }

        if (strpos($destination, '/') === false) {
            $errors[] = "Destination '{$destination}' must include a dataset below a pool root.";
            continue;
        }

        if ($frequency === null) {
            $errors[] = "Invalid frequency for '{$source}' -> '{$destination}'.";
            continue;
        }

        if ($threshold === null) {
            $errors[] = "Destination free-space target for '{$source}' -> '{$destination}' is invalid.";
            continue;
        }

        if ($jobId === '') {
            $jobId = zfsas_send_job_id($source, $destination);
        }

        if (isset($seenJobIds[$jobId])) {
            $errors[] = "Duplicate ZFS send job '{$source}' -> '{$destination}' detected.";
            continue;
        }

        $jobs[] = [
            'id' => $jobId,
            'source' => $source,
            'destination' => $destination,
            'destination_pool' => zfsas_send_dataset_pool_name($destination),
            'frequency' => $frequency,
            'frequency_label' => zfsas_send_frequency_label($frequency),
            'threshold' => $threshold,
            'children' => $children,
        ];
        $seenJobIds[$jobId] = true;
    }

    $newSource = zfsas_send_trim($post['new_job_source'] ?? '');
    $newDestination = zfsas_send_trim($post['new_job_destination'] ?? '');
    $newFrequencyRaw = zfsas_send_trim($post['new_job_frequency'] ?? '');
    $newThresholdRaw = zfsas_send_trim($post['new_job_threshold'] ?? '');
    $newChildrenRaw = zfsas_send_trim($post['new_job_children'] ?? '0');

    if ($newSource !== '' || $newDestination !== '') {
        $newFrequency = zfsas_send_normalize_frequency($newFrequencyRaw);
        $newThreshold = zfsas_send_normalize_threshold($newThresholdRaw);
        $newChildren = zfsas_send_normalize_children_flag($newChildrenRaw);

        if (!zfsas_send_is_valid_dataset_name($newSource)) {
            $errors[] = 'New ZFS send source dataset is invalid.';
        } elseif (!zfsas_send_is_valid_dataset_name($newDestination)) {
            $errors[] = 'New ZFS send destination dataset is invalid.';
        } elseif ($newSource === $newDestination) {
            $errors[] = 'New ZFS send source and destination must be different.';
        } elseif (zfsas_send_dataset_pool_name($newSource) === zfsas_send_dataset_pool_name($newDestination)
            && zfsas_send_paths_overlap($newSource, $newDestination)
        ) {
            $errors[] = 'New ZFS send source and destination overlap on the same pool.';
        } elseif (strpos($newDestination, '/') === false) {
            $errors[] = 'New ZFS send destination must include a dataset below a pool root.';
        } elseif ($newFrequency === null) {
            $errors[] = 'New ZFS send frequency is invalid.';
        } elseif ($newThreshold === null) {
            $errors[] = 'New ZFS send destination free-space target is invalid.';
        } else {
            $newJobId = zfsas_send_job_id($newSource, $newDestination);
            if (isset($seenJobIds[$newJobId])) {
                $errors[] = 'This ZFS send source/destination pair already exists.';
            } else {
                $jobs[] = [
                    'id' => $newJobId,
                    'source' => $newSource,
                    'destination' => $newDestination,
                    'destination_pool' => zfsas_send_dataset_pool_name($newDestination),
                    'frequency' => $newFrequency,
                    'frequency_label' => zfsas_send_frequency_label($newFrequency),
                    'threshold' => $newThreshold,
                    'children' => $newChildren,
                ];
            }
        }
    }

    usort($jobs, function ($a, $b) {
        $sourceCompare = strnatcasecmp((string) ($a['source'] ?? ''), (string) ($b['source'] ?? ''));
        if ($sourceCompare !== 0) {
            return $sourceCompare;
        }

        return strnatcasecmp((string) ($a['destination'] ?? ''), (string) ($b['destination'] ?? ''));
    });

    return $jobs;
}

function zfsas_send_render_config($config)
{
    $lines = [];
    $lines[] = '# -----------------------------------------------------------------------------';
    $lines[] = '# ZFS send replication config for ZFS Auto Snapshot';
    $lines[] = '# Path: /boot/config/plugins/zfs.autosnapshot/zfs_send.conf';
    $lines[] = '# -----------------------------------------------------------------------------';
    $lines[] = '';
    $lines[] = '# Prefix namespace reserved for send snapshots.';
    $lines[] = 'SEND_SNAPSHOT_PREFIX=' . zfsas_send_quote_config_string($config['SEND_SNAPSHOT_PREFIX']);
    $lines[] = '';
    $lines[] = '# Maximum number of queued ZFS send jobs allowed to transfer in parallel.';
    $lines[] = 'SEND_MAX_PARALLEL=' . zfsas_send_normalize_parallel_limit($config['SEND_MAX_PARALLEL']);
    $lines[] = '';
    $lines[] = '# Semicolon-separated jobs encoded as:';
    $lines[] = '#   jobid|source|destination|frequency|threshold|children';
    $lines[] = '# frequency values: 15m, 30m, 1h, 6h, 12h, 1d, 7d';
    $lines[] = 'SEND_JOBS=' . zfsas_send_quote_config_string($config['SEND_JOBS']);
    $lines[] = '';

    return implode("\n", $lines);
}

function zfsas_send_handle_save_request($post, $configDir, $configFile, $syncScript, $config, $defaultReturnUrl)
{
    $errors = [];
    $notices = [];
    $saved = false;
    $returnTarget = zfsas_normalize_return_url($post['return_to'] ?? '', $defaultReturnUrl);

    $submitted = $config;
    $submitted['SEND_SNAPSHOT_PREFIX'] = zfsas_send_trim($post['send_snapshot_prefix'] ?? $submitted['SEND_SNAPSHOT_PREFIX']);
    $submitted['SEND_MAX_PARALLEL'] = zfsas_send_normalize_parallel_limit($post['send_max_parallel'] ?? $submitted['SEND_MAX_PARALLEL']);
    $submittedJobs = zfsas_send_collect_submitted_jobs($post, $errors);

    if ($submitted['SEND_SNAPSHOT_PREFIX'] === '') {
        $errors[] = 'Send snapshot prefix cannot be empty.';
    } elseif (strpos($submitted['SEND_SNAPSHOT_PREFIX'], '@') !== false) {
        $errors[] = 'Send snapshot prefix cannot contain @.';
    } elseif (preg_match('/^[A-Za-z0-9._:-]+$/', $submitted['SEND_SNAPSHOT_PREFIX']) !== 1) {
        $errors[] = 'Send snapshot prefix can only contain letters, numbers, dot, underscore, colon, and dash.';
    }

    if (empty($errors)) {
        $submitted['SEND_JOBS'] = zfsas_send_render_jobs_string($submittedJobs);
        $config = $submitted;

        if (!is_dir($configDir)) {
            @mkdir($configDir, 0775, true);
        }

        $written = @file_put_contents($configFile, zfsas_send_render_config($config));
        if ($written === false) {
            $errors[] = "Unable to write config file: {$configFile}";
        } else {
            @chmod($configFile, 0644);
            $syncOutput = [];
            $syncExit = 0;
            @exec(escapeshellcmd($syncScript) . ' 2>&1', $syncOutput, $syncExit);

            if ($syncExit !== 0) {
                $errors[] = 'Settings saved, but failed to apply scheduler: ' . implode(' | ', $syncOutput);
            } else {
                $notices[] = 'ZFS send settings saved and schedule applied.';
                $saved = true;
            }
        }
    }

    return [
        'config' => $config,
        'formJobs' => $submittedJobs,
        'errors' => array_values($errors),
        'notices' => array_values($notices),
        'saved' => $saved,
        'returnTarget' => $returnTarget,
    ];
}

function zfsas_send_list_zfs_datasets(&$errorMessage = null)
{
    $errorMessage = null;
    $datasets = [];
    $output = [];
    $exitCode = 0;
    @exec('zfs list -H -o name -t filesystem,volume 2>/dev/null', $output, $exitCode);

    if ($exitCode !== 0) {
        $errorMessage = 'Could not auto-discover datasets from ZFS on this page load.';
        return [];
    }

    foreach ($output as $line) {
        $dataset = zfsas_send_trim($line);
        if ($dataset === '' || !zfsas_send_is_valid_dataset_name($dataset)) {
            continue;
        }
        $datasets[$dataset] = true;
    }

    $list = array_keys($datasets);
    sort($list, SORT_NATURAL | SORT_FLAG_CASE);
    return $list;
}

function zfsas_send_destination_pools_from_jobs($jobs)
{
    $pools = [];
    foreach ($jobs as $job) {
        $pool = (string) ($job['destination_pool'] ?? '');
        if ($pool !== '') {
            $pools[$pool] = true;
        }
    }

    return $pools;
}

function zfsas_send_destination_datasets_from_jobs($jobs, $candidateDatasets = [])
{
    $datasets = [];

    foreach ($jobs as $job) {
        $destination = zfsas_send_trim($job['destination'] ?? '');
        if ($destination === '') {
            continue;
        }

        $datasets[$destination] = true;

        if (($job['children'] ?? '0') !== '1') {
            continue;
        }

        foreach ($candidateDatasets as $candidateRaw) {
            $candidate = zfsas_send_trim($candidateRaw);
            if ($candidate === '' || $candidate === $destination) {
                continue;
            }

            if (strpos($candidate . '/', $destination . '/') === 0) {
                $datasets[$candidate] = true;
            }
        }
    }

    return $datasets;
}
