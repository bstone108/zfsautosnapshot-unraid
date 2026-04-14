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
    return substr(sha1(strtolower(trim((string) $source) . '|' . trim((string) $destination))), 0, 12);
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
        if (count($pieces) !== 5) {
            $warnings[] = "Ignoring invalid SEND_JOBS entry '{$entry}'.";
            continue;
        }

        list($jobIdRaw, $sourceRaw, $destinationRaw, $frequencyRaw, $thresholdRaw) = $pieces;
        $jobId = zfsas_send_trim($jobIdRaw);
        $source = zfsas_send_trim($sourceRaw);
        $destination = zfsas_send_trim($destinationRaw);
        $frequency = zfsas_send_normalize_frequency($frequencyRaw);
        $threshold = zfsas_send_normalize_threshold($thresholdRaw);

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
    $lines[] = '# Semicolon-separated jobs encoded as:';
    $lines[] = '#   jobid|source|destination|frequency|threshold';
    $lines[] = '# frequency values: 15m, 30m, 1h, 6h, 12h, 1d, 7d';
    $lines[] = 'SEND_JOBS=' . zfsas_send_quote_config_string($config['SEND_JOBS']);
    $lines[] = '';

    return implode("\n", $lines);
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
