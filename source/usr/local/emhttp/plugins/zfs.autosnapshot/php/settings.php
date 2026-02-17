<?php
$pluginName = 'zfs.autosnapshot';
$configDir = "/boot/config/plugins/{$pluginName}";
$configFile = "{$configDir}/zfs_autosnapshot.conf";
$syncScript = "/usr/local/emhttp/plugins/{$pluginName}/scripts/sync-cron.sh";

$defaults = [
    'DATASETS' => '',
    'PREFIX' => 'autosnapshot-',
    'DRY_RUN' => '0',
    'KEEP_ALL_FOR_DAYS' => '14',
    'KEEP_DAILY_UNTIL_DAYS' => '30',
    'KEEP_WEEKLY_UNTIL_DAYS' => '183',
    'SCHEDULE_MODE' => 'disabled',
    'SCHEDULE_EVERY_MINUTES' => '15',
    'SCHEDULE_EVERY_HOURS' => '1',
    'SCHEDULE_DAILY_HOUR' => '3',
    'SCHEDULE_DAILY_MINUTE' => '0',
    'SCHEDULE_WEEKLY_DAY' => '0',
    'SCHEDULE_WEEKLY_HOUR' => '3',
    'SCHEDULE_WEEKLY_MINUTE' => '0',
    'CUSTOM_CRON_SCHEDULE' => '',
    'CRON_SCHEDULE' => '',
];

$weekdayNames = [
    '0' => 'Sunday',
    '1' => 'Monday',
    '2' => 'Tuesday',
    '3' => 'Wednesday',
    '4' => 'Thursday',
    '5' => 'Friday',
    '6' => 'Saturday',
];

function h($value)
{
    return htmlspecialchars((string) $value, ENT_QUOTES, 'UTF-8');
}

function trimValue($value)
{
    return trim((string) $value);
}

function isValidDatasetName($dataset)
{
    return preg_match('/^[A-Za-z0-9._\/:-]+$/', (string) $dataset) === 1;
}

function datasetPoolName($dataset)
{
    $dataset = trimValue($dataset);
    if ($dataset === '') {
        return '';
    }

    $parts = explode('/', $dataset, 2);
    return $parts[0];
}

function normalizeThreshold($value)
{
    $value = strtoupper(str_replace(' ', '', trim((string) $value)));

    if (preg_match('/^([0-9]+)([KMGT])B?$/', $value, $match) !== 1) {
        return null;
    }

    return $match[1] . $match[2];
}

function parseConfigFile($path, $defaults)
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

function parseDatasetsCsv($datasetsCsv, &$warnings = [])
{
    $warnings = [];
    $map = [];

    $parts = explode(',', (string) $datasetsCsv);
    foreach ($parts as $part) {
        $entry = trim($part);
        if ($entry === '') {
            continue;
        }

        if (strpos($entry, ':') === false) {
            $warnings[] = "Ignoring invalid DATASETS entry '{$entry}' (missing ':').";
            continue;
        }

        list($datasetRaw, $thresholdRaw) = explode(':', $entry, 2);
        $dataset = trimValue($datasetRaw);
        $threshold = normalizeThreshold($thresholdRaw);

        if (!isValidDatasetName($dataset)) {
            $warnings[] = "Ignoring invalid dataset name '{$dataset}'.";
            continue;
        }

        if ($threshold === null) {
            $warnings[] = "Ignoring invalid threshold '{$thresholdRaw}' for dataset '{$dataset}'.";
            continue;
        }

        $map[$dataset] = $threshold;
    }

    return $map;
}

function listZfsDatasets(&$errorMessage = null)
{
    $errorMessage = null;
    $datasets = [];
    $poolNames = [];
    $poolExitCode = 0;

    @exec('zpool list -H -o name 2>/dev/null', $poolNames, $poolExitCode);

    if ($poolExitCode === 0 && count($poolNames) > 0) {
        $poolScanErrors = [];

        foreach ($poolNames as $poolLine) {
            $pool = trimValue($poolLine);
            if ($pool === '') {
                continue;
            }

            $poolOutput = [];
            $poolListExitCode = 0;
            // Include both filesystems and zvols, scanning each pool independently.
            @exec('zfs list -H -o name -t filesystem,volume -r ' . escapeshellarg($pool) . ' 2>/dev/null', $poolOutput, $poolListExitCode);

            if ($poolListExitCode !== 0) {
                $poolScanErrors[] = $pool;
                continue;
            }

            foreach ($poolOutput as $line) {
                $dataset = trimValue($line);
                if ($dataset === '' || !isValidDatasetName($dataset)) {
                    continue;
                }
                $datasets[$dataset] = true;
            }
        }

        if (count($datasets) > 0) {
            $list = array_keys($datasets);
            sort($list, SORT_NATURAL | SORT_FLAG_CASE);

            if (count($poolScanErrors) > 0) {
                $errorMessage = 'Some pools could not be scanned: ' . implode(', ', $poolScanErrors);
            }

            return $list;
        }

        if (count($poolScanErrors) > 0) {
            $errorMessage = 'Could not auto-discover datasets from these pools: ' . implode(', ', $poolScanErrors);
        }
    }

    // Fallback: aggregate list in case per-pool scan is unavailable.
    $output = [];
    $exitCode = 0;
    @exec('zfs list -H -o name -t filesystem,volume 2>/dev/null', $output, $exitCode);

    if ($exitCode !== 0) {
        if ($errorMessage === null) {
            $errorMessage = 'Could not auto-discover datasets from ZFS on this page load.';
        }
        return [];
    }

    foreach ($output as $line) {
        $dataset = trimValue($line);
        if ($dataset === '' || !isValidDatasetName($dataset)) {
            continue;
        }
        $datasets[$dataset] = true;
    }

    $list = array_keys($datasets);
    sort($list, SORT_NATURAL | SORT_FLAG_CASE);

    return $list;
}

function sortDatasetRows($rows)
{
    usort($rows, function ($a, $b) {
        $poolCompare = strnatcasecmp((string) ($a['pool'] ?? ''), (string) ($b['pool'] ?? ''));
        if ($poolCompare !== 0) {
            return $poolCompare;
        }

        $datasetCompare = strnatcasecmp((string) ($a['dataset'] ?? ''), (string) ($b['dataset'] ?? ''));
        if ($datasetCompare !== 0) {
            return $datasetCompare;
        }

        if (($a['available'] ?? false) === ($b['available'] ?? false)) {
            return 0;
        }

        return ($a['available'] ?? false) ? -1 : 1;
    });

    return $rows;
}

function buildDatasetPools($datasetRows)
{
    $poolMap = [];

    foreach ($datasetRows as $row) {
        $pool = (string) ($row['pool'] ?? '');
        if ($pool === '') {
            continue;
        }

        if (!isset($poolMap[$pool])) {
            $poolMap[$pool] = ['total' => 0, 'selected' => 0];
        }

        $poolMap[$pool]['total']++;
        if (!empty($row['selected'])) {
            $poolMap[$pool]['selected']++;
        }
    }

    ksort($poolMap, SORT_NATURAL | SORT_FLAG_CASE);
    return $poolMap;
}

function buildDatasetRows($availableDatasets, $configuredDatasetMap)
{
    $rows = [];
    $seen = [];

    foreach ($availableDatasets as $dataset) {
        $rows[] = [
            'dataset' => $dataset,
            'pool' => datasetPoolName($dataset),
            'selected' => isset($configuredDatasetMap[$dataset]),
            'threshold' => isset($configuredDatasetMap[$dataset]) ? $configuredDatasetMap[$dataset] : '100G',
            'available' => true,
        ];
        $seen[$dataset] = true;
    }

    foreach ($configuredDatasetMap as $dataset => $threshold) {
        if (isset($seen[$dataset])) {
            continue;
        }

        $rows[] = [
            'dataset' => $dataset,
            'pool' => datasetPoolName($dataset),
            'selected' => true,
            'threshold' => $threshold,
            'available' => false,
        ];
    }

    return sortDatasetRows($rows);
}

function buildDatasetRowsFromPost($postedNames, $postedSelected, $postedThresholds, $availableDatasets, $configuredDatasetMap)
{
    $rows = [];
    $seen = [];
    $availableSet = array_fill_keys($availableDatasets, true);

    foreach ($postedNames as $index => $datasetRaw) {
        $dataset = trimValue($datasetRaw);
        if ($dataset === '' || isset($seen[$dataset])) {
            continue;
        }
        $seen[$dataset] = true;

        $threshold = trimValue($postedThresholds[$index] ?? '');
        if ($threshold === '' && isset($configuredDatasetMap[$dataset])) {
            $threshold = $configuredDatasetMap[$dataset];
        }
        if ($threshold === '') {
            $threshold = '100G';
        }

        $rows[] = [
            'dataset' => $dataset,
            'pool' => datasetPoolName($dataset),
            'selected' => isset($postedSelected[$index]) && (string) $postedSelected[$index] === '1',
            'threshold' => strtoupper(str_replace(' ', '', $threshold)),
            'available' => isset($availableSet[$dataset]),
        ];
    }

    return sortDatasetRows($rows);
}

function buildDatasetsCsvFromPost($postedNames, $postedSelected, $postedThresholds, &$errors)
{
    $entries = [];
    $seen = [];
    $selectedCount = 0;

    foreach ($postedNames as $index => $datasetRaw) {
        $dataset = trimValue($datasetRaw);
        if ($dataset === '') {
            continue;
        }

        if (isset($seen[$dataset])) {
            continue;
        }
        $seen[$dataset] = true;

        $isSelected = isset($postedSelected[$index]) && (string) $postedSelected[$index] === '1';
        if (!$isSelected) {
            continue;
        }

        $selectedCount++;

        if (!isValidDatasetName($dataset)) {
            $errors[] = "Invalid dataset name '{$dataset}'.";
            continue;
        }

        $threshold = normalizeThreshold($postedThresholds[$index] ?? '');
        if ($threshold === null) {
            $errors[] = "Dataset '{$dataset}' has an invalid threshold. Use values like 500M, 100G, or 2T.";
            continue;
        }

        $entries[] = "{$dataset}:{$threshold}";
    }

    if ($selectedCount === 0) {
        $errors[] = 'Select at least one dataset for automatic snapshots.';
        return null;
    }

    if (count($entries) !== $selectedCount) {
        return null;
    }

    if (count($entries) === 0) {
        $errors[] = 'No valid selected dataset entries were found.';
        return null;
    }

    return implode(',', $entries);
}

function intInRange($value, $min, $max, $label, &$errors)
{
    $value = trim((string) $value);

    if (!preg_match('/^[0-9]+$/', $value)) {
        $errors[] = "{$label} must be an integer ({$min}-{$max}).";
        return null;
    }

    $int = (int) $value;
    if ($int < $min || $int > $max) {
        $errors[] = "{$label} must be between {$min} and {$max}.";
        return null;
    }

    return (string) $int;
}

function normalizeWeekday($value)
{
    $value = strtolower(trim((string) $value));
    $map = [
        '0' => '0',
        '7' => '0',
        'sun' => '0',
        'sunday' => '0',
        '1' => '1',
        'mon' => '1',
        'monday' => '1',
        '2' => '2',
        'tue' => '2',
        'tues' => '2',
        'tuesday' => '2',
        '3' => '3',
        'wed' => '3',
        'wednesday' => '3',
        '4' => '4',
        'thu' => '4',
        'thur' => '4',
        'thurs' => '4',
        'thursday' => '4',
        '5' => '5',
        'fri' => '5',
        'friday' => '5',
        '6' => '6',
        'sat' => '6',
        'saturday' => '6',
    ];

    return $map[$value] ?? null;
}

function cronHasFiveFields($cron)
{
    $parts = preg_split('/\s+/', trim((string) $cron));
    return is_array($parts) && count($parts) === 5;
}

function buildCronFromSettings($config, &$errors)
{
    $mode = strtolower(trim((string) ($config['SCHEDULE_MODE'] ?? 'disabled')));

    if ($mode === '') {
        $mode = 'disabled';
    }

    if ($mode === 'disabled') {
        return '';
    }

    if ($mode === 'minutes') {
        $every = intInRange($config['SCHEDULE_EVERY_MINUTES'] ?? '15', 1, 59, 'Every N minutes', $errors);
        if ($every === null) {
            return '';
        }
        return ((int) $every === 1) ? '* * * * *' : "*/{$every} * * * *";
    }

    if ($mode === 'hourly') {
        $every = intInRange($config['SCHEDULE_EVERY_HOURS'] ?? '1', 1, 24, 'Every N hours', $errors);
        if ($every === null) {
            return '';
        }
        return ((int) $every === 1) ? '0 * * * *' : "0 */{$every} * * *";
    }

    if ($mode === 'daily') {
        $hour = intInRange($config['SCHEDULE_DAILY_HOUR'] ?? '3', 0, 23, 'Daily hour', $errors);
        $minute = intInRange($config['SCHEDULE_DAILY_MINUTE'] ?? '0', 0, 59, 'Daily minute', $errors);
        if ($hour === null || $minute === null) {
            return '';
        }
        return "{$minute} {$hour} * * *";
    }

    if ($mode === 'weekly') {
        $day = normalizeWeekday($config['SCHEDULE_WEEKLY_DAY'] ?? '0');
        if ($day === null) {
            $errors[] = 'Weekly day must be 0-6 or a weekday name.';
            return '';
        }
        $hour = intInRange($config['SCHEDULE_WEEKLY_HOUR'] ?? '3', 0, 23, 'Weekly hour', $errors);
        $minute = intInRange($config['SCHEDULE_WEEKLY_MINUTE'] ?? '0', 0, 59, 'Weekly minute', $errors);
        if ($hour === null || $minute === null) {
            return '';
        }
        return "{$minute} {$hour} * * {$day}";
    }

    if ($mode === 'custom') {
        $cron = trim((string) ($config['CUSTOM_CRON_SCHEDULE'] ?? ''));
        if ($cron === '') {
            $errors[] = 'Custom cron mode requires a cron expression.';
            return '';
        }
        if (!cronHasFiveFields($cron)) {
            $errors[] = 'Custom cron expression must have exactly 5 fields.';
            return '';
        }
        return $cron;
    }

    $errors[] = "Invalid schedule mode '{$mode}'.";
    return '';
}

function quoteConfigString($value)
{
    $value = str_replace('\\', '\\\\', (string) $value);
    $value = str_replace('"', '\\"', $value);
    return '"' . $value . '"';
}

function renderConfig($config)
{
    $lines = [];
    $lines[] = '# -----------------------------------------------------------------------------';
    $lines[] = '# ZFS Auto Snapshot plugin config';
    $lines[] = '# Path: /boot/config/plugins/zfs.autosnapshot/zfs_autosnapshot.conf';
    $lines[] = '# -----------------------------------------------------------------------------';
    $lines[] = '';
    $lines[] = '# DATASETS: comma-separated dataset:threshold entries';
    $lines[] = 'DATASETS=' . quoteConfigString($config['DATASETS']);
    $lines[] = '';
    $lines[] = '# Snapshot name prefix this plugin is allowed to delete';
    $lines[] = 'PREFIX=' . quoteConfigString($config['PREFIX']);
    $lines[] = '';
    $lines[] = '# 1 = dry-run only, 0 = make changes';
    $lines[] = 'DRY_RUN=' . $config['DRY_RUN'];
    $lines[] = '';
    $lines[] = '# Retention windows in days';
    $lines[] = 'KEEP_ALL_FOR_DAYS=' . $config['KEEP_ALL_FOR_DAYS'];
    $lines[] = 'KEEP_DAILY_UNTIL_DAYS=' . $config['KEEP_DAILY_UNTIL_DAYS'];
    $lines[] = 'KEEP_WEEKLY_UNTIL_DAYS=' . $config['KEEP_WEEKLY_UNTIL_DAYS'];
    $lines[] = '';
    $lines[] = '# Human-friendly schedule fields';
    $lines[] = 'SCHEDULE_MODE=' . quoteConfigString($config['SCHEDULE_MODE']);
    $lines[] = 'SCHEDULE_EVERY_MINUTES=' . $config['SCHEDULE_EVERY_MINUTES'];
    $lines[] = 'SCHEDULE_EVERY_HOURS=' . $config['SCHEDULE_EVERY_HOURS'];
    $lines[] = 'SCHEDULE_DAILY_HOUR=' . $config['SCHEDULE_DAILY_HOUR'];
    $lines[] = 'SCHEDULE_DAILY_MINUTE=' . $config['SCHEDULE_DAILY_MINUTE'];
    $lines[] = 'SCHEDULE_WEEKLY_DAY=' . $config['SCHEDULE_WEEKLY_DAY'];
    $lines[] = 'SCHEDULE_WEEKLY_HOUR=' . $config['SCHEDULE_WEEKLY_HOUR'];
    $lines[] = 'SCHEDULE_WEEKLY_MINUTE=' . $config['SCHEDULE_WEEKLY_MINUTE'];
    $lines[] = 'CUSTOM_CRON_SCHEDULE=' . quoteConfigString($config['CUSTOM_CRON_SCHEDULE']);
    $lines[] = '';
    $lines[] = '# Derived cron expression (for compatibility)';
    $lines[] = 'CRON_SCHEDULE=' . quoteConfigString($config['CRON_SCHEDULE']);
    $lines[] = '';

    return implode("\n", $lines);
}

$config = parseConfigFile($configFile, $defaults);
$errors = [];
$notices = [];

$datasetParseWarnings = [];
$configuredDatasetMap = parseDatasetsCsv($config['DATASETS'], $datasetParseWarnings);

$datasetDiscoveryError = null;
$availableDatasets = listZfsDatasets($datasetDiscoveryError);
$datasetRows = buildDatasetRows($availableDatasets, $configuredDatasetMap);
$datasetPools = buildDatasetPools($datasetRows);

if (!empty($datasetParseWarnings)) {
    foreach ($datasetParseWarnings as $warning) {
        $notices[] = $warning;
    }
}

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $submitted = $config;

    $submitted['PREFIX'] = trimValue($_POST['prefix'] ?? $submitted['PREFIX']);
    $submitted['DRY_RUN'] = isset($_POST['dry_run']) ? '1' : '0';
    $submitted['KEEP_ALL_FOR_DAYS'] = trimValue($_POST['keep_all_for_days'] ?? $submitted['KEEP_ALL_FOR_DAYS']);
    $submitted['KEEP_DAILY_UNTIL_DAYS'] = trimValue($_POST['keep_daily_until_days'] ?? $submitted['KEEP_DAILY_UNTIL_DAYS']);
    $submitted['KEEP_WEEKLY_UNTIL_DAYS'] = trimValue($_POST['keep_weekly_until_days'] ?? $submitted['KEEP_WEEKLY_UNTIL_DAYS']);
    $submitted['SCHEDULE_MODE'] = strtolower(trimValue($_POST['schedule_mode'] ?? $submitted['SCHEDULE_MODE']));
    $submitted['SCHEDULE_EVERY_MINUTES'] = trimValue($_POST['schedule_every_minutes'] ?? $submitted['SCHEDULE_EVERY_MINUTES']);
    $submitted['SCHEDULE_EVERY_HOURS'] = trimValue($_POST['schedule_every_hours'] ?? $submitted['SCHEDULE_EVERY_HOURS']);
    $submitted['SCHEDULE_DAILY_HOUR'] = trimValue($_POST['schedule_daily_hour'] ?? $submitted['SCHEDULE_DAILY_HOUR']);
    $submitted['SCHEDULE_DAILY_MINUTE'] = trimValue($_POST['schedule_daily_minute'] ?? $submitted['SCHEDULE_DAILY_MINUTE']);
    $submitted['SCHEDULE_WEEKLY_DAY'] = trimValue($_POST['schedule_weekly_day'] ?? $submitted['SCHEDULE_WEEKLY_DAY']);
    $submitted['SCHEDULE_WEEKLY_HOUR'] = trimValue($_POST['schedule_weekly_hour'] ?? $submitted['SCHEDULE_WEEKLY_HOUR']);
    $submitted['SCHEDULE_WEEKLY_MINUTE'] = trimValue($_POST['schedule_weekly_minute'] ?? $submitted['SCHEDULE_WEEKLY_MINUTE']);
    $submitted['CUSTOM_CRON_SCHEDULE'] = trimValue($_POST['custom_cron_schedule'] ?? $submitted['CUSTOM_CRON_SCHEDULE']);

    $postDatasetNames = (isset($_POST['dataset_name']) && is_array($_POST['dataset_name'])) ? $_POST['dataset_name'] : [];
    $postDatasetSelected = (isset($_POST['dataset_selected']) && is_array($_POST['dataset_selected'])) ? $_POST['dataset_selected'] : [];
    $postDatasetThresholds = (isset($_POST['dataset_threshold']) && is_array($_POST['dataset_threshold'])) ? $_POST['dataset_threshold'] : [];

    $datasetRows = buildDatasetRowsFromPost($postDatasetNames, $postDatasetSelected, $postDatasetThresholds, $availableDatasets, $configuredDatasetMap);
    $datasetPools = buildDatasetPools($datasetRows);

    if (count($postDatasetNames) === 0) {
        $errors[] = 'Dataset selection data was not submitted. Refresh the page and try again.';
    } else {
        $datasetCsv = buildDatasetsCsvFromPost($postDatasetNames, $postDatasetSelected, $postDatasetThresholds, $errors);
        if ($datasetCsv !== null) {
            $submitted['DATASETS'] = $datasetCsv;
        }
    }

    if (!preg_match('/^[A-Za-z0-9._:-]+$/', $submitted['PREFIX'])) {
        $errors[] = 'Prefix can only contain letters, numbers, dot, underscore, colon, and dash.';
    }

    $submitted['KEEP_ALL_FOR_DAYS'] = intInRange($submitted['KEEP_ALL_FOR_DAYS'], 1, 36500, 'Keep all for days', $errors) ?? $submitted['KEEP_ALL_FOR_DAYS'];
    $submitted['KEEP_DAILY_UNTIL_DAYS'] = intInRange($submitted['KEEP_DAILY_UNTIL_DAYS'], 2, 36500, 'Keep daily until days', $errors) ?? $submitted['KEEP_DAILY_UNTIL_DAYS'];
    $submitted['KEEP_WEEKLY_UNTIL_DAYS'] = intInRange($submitted['KEEP_WEEKLY_UNTIL_DAYS'], 3, 36500, 'Keep weekly until days', $errors) ?? $submitted['KEEP_WEEKLY_UNTIL_DAYS'];

    if (empty($errors)) {
        if ((int) $submitted['KEEP_ALL_FOR_DAYS'] >= (int) $submitted['KEEP_DAILY_UNTIL_DAYS'] ||
            (int) $submitted['KEEP_DAILY_UNTIL_DAYS'] >= (int) $submitted['KEEP_WEEKLY_UNTIL_DAYS']) {
            $errors[] = 'Retention must follow: keep all < keep daily until < keep weekly until.';
        }
    }

    if (!in_array($submitted['SCHEDULE_MODE'], ['disabled', 'minutes', 'hourly', 'daily', 'weekly', 'custom'], true)) {
        $errors[] = 'Schedule mode is invalid.';
    }

    $submitted['SCHEDULE_EVERY_MINUTES'] = intInRange($submitted['SCHEDULE_EVERY_MINUTES'], 1, 59, 'Every N minutes', $errors) ?? $submitted['SCHEDULE_EVERY_MINUTES'];
    $submitted['SCHEDULE_EVERY_HOURS'] = intInRange($submitted['SCHEDULE_EVERY_HOURS'], 1, 24, 'Every N hours', $errors) ?? $submitted['SCHEDULE_EVERY_HOURS'];
    $submitted['SCHEDULE_DAILY_HOUR'] = intInRange($submitted['SCHEDULE_DAILY_HOUR'], 0, 23, 'Daily hour', $errors) ?? $submitted['SCHEDULE_DAILY_HOUR'];
    $submitted['SCHEDULE_DAILY_MINUTE'] = intInRange($submitted['SCHEDULE_DAILY_MINUTE'], 0, 59, 'Daily minute', $errors) ?? $submitted['SCHEDULE_DAILY_MINUTE'];

    $normalizedWeekday = normalizeWeekday($submitted['SCHEDULE_WEEKLY_DAY']);
    if ($normalizedWeekday === null) {
        $errors[] = 'Weekly day must be a day number (0-6) or weekday name.';
    } else {
        $submitted['SCHEDULE_WEEKLY_DAY'] = $normalizedWeekday;
    }

    $submitted['SCHEDULE_WEEKLY_HOUR'] = intInRange($submitted['SCHEDULE_WEEKLY_HOUR'], 0, 23, 'Weekly hour', $errors) ?? $submitted['SCHEDULE_WEEKLY_HOUR'];
    $submitted['SCHEDULE_WEEKLY_MINUTE'] = intInRange($submitted['SCHEDULE_WEEKLY_MINUTE'], 0, 59, 'Weekly minute', $errors) ?? $submitted['SCHEDULE_WEEKLY_MINUTE'];

    $cron = buildCronFromSettings($submitted, $errors);
    $submitted['CRON_SCHEDULE'] = $cron;

    $config = $submitted;

    if (empty($errors)) {
        if (!is_dir($configDir)) {
            @mkdir($configDir, 0775, true);
        }

        $written = @file_put_contents($configFile, renderConfig($config));
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
                $notices[] = 'Settings saved and schedule applied.';

                $postSaveWarnings = [];
                $configuredDatasetMap = parseDatasetsCsv($config['DATASETS'], $postSaveWarnings);
                $datasetRows = buildDatasetRows($availableDatasets, $configuredDatasetMap);
                $datasetPools = buildDatasetPools($datasetRows);
            }
        }
    }
}

$resolvedCron = trim((string) ($config['CRON_SCHEDULE'] ?? ''));
if ($resolvedCron === '') {
    $resolvedCron = '(disabled)';
}
?>
<style>
.zfsas-wrap {
  margin: 16px;
  max-width: 1100px;
  font-family: "Segoe UI", Tahoma, Geneva, Verdana, sans-serif;
}

.zfsas-title {
  margin-bottom: 6px;
}

.zfsas-subtitle {
  color: #444;
  margin-bottom: 16px;
}

.zfsas-card {
  background: #fff;
  border: 1px solid #d9e1ea;
  border-radius: 10px;
  padding: 16px;
  margin-bottom: 14px;
  box-shadow: 0 1px 2px rgba(0, 0, 0, 0.04);
}

.zfsas-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 14px;
}

.zfsas-field {
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.zfsas-field label {
  font-weight: 600;
}

.zfsas-help {
  color: #4f5a66;
  font-size: 12px;
  line-height: 1.4;
}

.zfsas-input,
.zfsas-select {
  width: 100%;
  padding: 8px 10px;
  border: 1px solid #b8c5d1;
  border-radius: 8px;
  background: #fff;
}

.zfsas-inline {
  display: flex;
  gap: 8px;
  align-items: center;
}

.zfsas-inline > * {
  flex: 1;
}

.zfsas-checkline {
  display: flex;
  align-items: center;
  gap: 10px;
  line-height: 1.3;
}

.zfsas-checkline input[type="checkbox"] {
  flex: 0 0 auto;
  width: auto;
  margin: 0;
}

.zfsas-checkline span {
  flex: 1 1 auto;
}

.zfsas-alert {
  border-radius: 8px;
  padding: 10px 12px;
  margin-bottom: 12px;
}

.zfsas-alert-error {
  background: #fff1f0;
  border: 1px solid #f5c2c0;
  color: #8f2d2a;
}

.zfsas-alert-ok {
  background: #effaf1;
  border: 1px solid #b7e3bf;
  color: #21693a;
}

.zfsas-alert-warn {
  background: #fff9ec;
  border: 1px solid #f2d9a6;
  color: #8a5a12;
}

.zfsas-dataset-toolbar {
  display: flex;
  gap: 10px;
  align-items: center;
  margin-top: 12px;
  flex-wrap: wrap;
  padding: 10px;
  border: 1px solid #e1e8ef;
  border-radius: 8px;
  background: #f8fbff;
}

.zfsas-pool-filter {
  display: flex;
  align-items: center;
  gap: 8px;
}

.zfsas-pool-filter label {
  font-weight: 600;
  white-space: nowrap;
}

.zfsas-pool-filter .zfsas-select {
  min-width: 230px;
  width: auto;
}

.zfsas-dataset-count {
  margin-left: auto;
  font-weight: 600;
}

.zfsas-pool-chip {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  margin-left: 8px;
  padding: 2px 8px;
  font-size: 11px;
  border-radius: 99px;
  background: #eaf2ff;
  border: 1px solid #bfd3ff;
  color: #1f4b8c;
}

.zfsas-row-hidden {
  display: none;
}

.zfsas-table-wrap {
  margin-top: 10px;
  border: 1px solid #e1e8ef;
  border-radius: 8px;
  overflow-x: auto;
}

.zfsas-table {
  width: 100%;
  border-collapse: collapse;
  min-width: 720px;
}

.zfsas-table th,
.zfsas-table td {
  padding: 10px 12px;
  border-bottom: 1px solid #edf2f7;
  vertical-align: top;
}

.zfsas-table th {
  background: #f8fbff;
  text-align: left;
  font-size: 13px;
}

.zfsas-table tr:last-child td {
  border-bottom: none;
}

.zfsas-center {
  text-align: center;
  width: 70px;
}

.zfsas-table code {
  font-family: Consolas, Menlo, Monaco, monospace;
}

.zfsas-dataset-cell {
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.zfsas-badge {
  display: inline-block;
  margin-left: 8px;
  padding: 2px 6px;
  font-size: 11px;
  border-radius: 99px;
  background: #fff7e8;
  border: 1px solid #f0d3a3;
  color: #8f5e12;
}

.zfsas-empty {
  margin-top: 12px;
  padding: 12px;
  border: 1px dashed #c8d5e3;
  border-radius: 8px;
  background: #fafcff;
  color: #455261;
}

.zfsas-schedule-row {
  display: none;
}

.zfsas-preview {
  margin-top: 10px;
  padding: 10px;
  background: #f5f9ff;
  border: 1px solid #cfe0ff;
  border-radius: 8px;
  color: #264b85;
}

.zfsas-actions {
  display: flex;
  justify-content: flex-end;
  margin-top: 12px;
}

@media (max-width: 900px) {
  .zfsas-grid {
    grid-template-columns: 1fr;
  }

  .zfsas-pool-filter {
    width: 100%;
  }

  .zfsas-pool-filter .zfsas-select {
    width: 100%;
  }

  .zfsas-dataset-count {
    margin-left: 0;
    width: 100%;
  }
}
</style>

<div class="zfsas-wrap">
  <h2 class="zfsas-title">ZFS Auto Snapshot</h2>
  <div class="zfsas-subtitle">
    Manage dataset selection, retention policy, and automatic run schedule.
  </div>

  <?php if (!empty($errors)) : ?>
    <div class="zfsas-alert zfsas-alert-error">
      <?php foreach ($errors as $error) : ?>
        <div><?php echo h($error); ?></div>
      <?php endforeach; ?>
    </div>
  <?php endif; ?>

  <?php if (!empty($notices)) : ?>
    <div class="zfsas-alert zfsas-alert-ok">
      <?php foreach ($notices as $notice) : ?>
        <div><?php echo h($notice); ?></div>
      <?php endforeach; ?>
    </div>
  <?php endif; ?>

  <?php if ($datasetDiscoveryError !== null) : ?>
    <div class="zfsas-alert zfsas-alert-warn">
      <?php echo h($datasetDiscoveryError); ?>
      Existing configured datasets are still shown.
    </div>
  <?php endif; ?>

  <form method="post" action="">
    <div class="zfsas-card">
      <h3>Datasets</h3>
      <div class="zfsas-help">
        Check the datasets you want this plugin to manage. Only checked datasets are included in automated snapshot cleanup and creation.
      </div>

      <?php if (count($datasetRows) === 0) : ?>
        <div class="zfsas-empty">
          No ZFS datasets were found. Create a dataset first, then reload this page.
        </div>
      <?php else : ?>
        <div class="zfsas-dataset-toolbar">
          <div class="zfsas-pool-filter">
            <label for="dataset_pool_filter">Pool</label>
            <select id="dataset_pool_filter" class="zfsas-select">
              <option value="__all">All pools</option>
              <?php foreach ($datasetPools as $poolName => $poolStats) : ?>
                <option value="<?php echo h($poolName); ?>">
                  <?php echo h($poolName); ?> (<?php echo (int) $poolStats['total']; ?>)
                </option>
              <?php endforeach; ?>
            </select>
          </div>
          <button type="button" class="btn" id="dataset_select_visible">Select shown</button>
          <button type="button" class="btn" id="dataset_clear_visible">Clear shown</button>
          <button type="button" class="btn" id="dataset_select_all">Select all</button>
          <button type="button" class="btn" id="dataset_clear_all">Clear all</button>
          <div class="zfsas-help zfsas-dataset-count" id="dataset_count"></div>
        </div>

        <div class="zfsas-table-wrap">
          <table class="zfsas-table">
            <thead>
              <tr>
                <th class="zfsas-center">Use</th>
                <th>Dataset</th>
                <th>Pool free-space target</th>
              </tr>
            </thead>
            <tbody>
              <?php foreach ($datasetRows as $index => $row) : ?>
                <tr class="zfsas-dataset-row" data-pool="<?php echo h($row['pool']); ?>">
                  <td class="zfsas-center">
                    <input type="hidden" name="dataset_name[<?php echo (int) $index; ?>]" value="<?php echo h($row['dataset']); ?>">
                    <input class="zfsas-dataset-checkbox" type="checkbox" name="dataset_selected[<?php echo (int) $index; ?>]" value="1" <?php echo $row['selected'] ? 'checked' : ''; ?>>
                  </td>
                  <td>
                    <div class="zfsas-dataset-cell">
                      <div>
                        <code><?php echo h($row['dataset']); ?></code>
                        <span class="zfsas-pool-chip"><?php echo h($row['pool']); ?></span>
                        <?php if (!$row['available']) : ?>
                          <span class="zfsas-badge">Not currently detected</span>
                        <?php endif; ?>
                      </div>
                    </div>
                  </td>
                  <td>
                    <input class="zfsas-input" name="dataset_threshold[<?php echo (int) $index; ?>]" value="<?php echo h($row['threshold']); ?>">
                    <div class="zfsas-help">Examples: <code>500M</code>, <code>100G</code>, <code>2T</code>.</div>
                  </td>
                </tr>
              <?php endforeach; ?>
            </tbody>
          </table>
        </div>
      <?php endif; ?>

      <div class="zfsas-field" style="margin-top: 14px;">
        <label for="prefix">Snapshot name prefix</label>
        <input id="prefix" name="prefix" class="zfsas-input" value="<?php echo h($config['PREFIX']); ?>">
        <div class="zfsas-help">
          Safety guard: only snapshots containing <code>@prefix</code> are eligible for automatic deletion.
        </div>
      </div>

      <div class="zfsas-field" style="margin-top: 12px;">
        <label for="dry_run">Mode</label>
        <label class="zfsas-checkline" for="dry_run">
          <input type="checkbox" id="dry_run" name="dry_run" value="1" <?php echo ($config['DRY_RUN'] === '1') ? 'checked' : ''; ?>>
          <span>Dry run (preview only, no snapshot create/delete)</span>
        </label>
        <div class="zfsas-help">
          Leave this unchecked for normal operation.
        </div>
      </div>
    </div>

    <div class="zfsas-card">
      <h3>Retention Policy (Days)</h3>
      <div class="zfsas-grid">
        <div class="zfsas-field">
          <label for="keep_all_for_days">Keep every snapshot for this many days</label>
          <input id="keep_all_for_days" name="keep_all_for_days" class="zfsas-input" type="number" min="1" max="36500" value="<?php echo h($config['KEEP_ALL_FOR_DAYS']); ?>">
          <div class="zfsas-help">
            All snapshots newer than this age are kept.
          </div>
        </div>

        <div class="zfsas-field">
          <label for="keep_daily_until_days">Then keep 1 snapshot per day until this many days</label>
          <input id="keep_daily_until_days" name="keep_daily_until_days" class="zfsas-input" type="number" min="2" max="36500" value="<?php echo h($config['KEEP_DAILY_UNTIL_DAYS']); ?>">
          <div class="zfsas-help">
            For snapshots older than the first window, keep the newest snapshot from each day.
          </div>
        </div>

        <div class="zfsas-field">
          <label for="keep_weekly_until_days">Then keep 1 snapshot per week until this many days</label>
          <input id="keep_weekly_until_days" name="keep_weekly_until_days" class="zfsas-input" type="number" min="3" max="36500" value="<?php echo h($config['KEEP_WEEKLY_UNTIL_DAYS']); ?>">
          <div class="zfsas-help">
            Snapshots older than this are removed.
          </div>
        </div>
      </div>
    </div>

    <div class="zfsas-card">
      <h3>Run Schedule</h3>
      <div class="zfsas-field">
        <label for="schedule_mode">How often should automatic runs happen?</label>
        <select id="schedule_mode" name="schedule_mode" class="zfsas-select">
          <option value="disabled" <?php echo ($config['SCHEDULE_MODE'] === 'disabled') ? 'selected' : ''; ?>>Disabled (manual only)</option>
          <option value="minutes" <?php echo ($config['SCHEDULE_MODE'] === 'minutes') ? 'selected' : ''; ?>>Every N minutes</option>
          <option value="hourly" <?php echo ($config['SCHEDULE_MODE'] === 'hourly') ? 'selected' : ''; ?>>Every N hours</option>
          <option value="daily" <?php echo ($config['SCHEDULE_MODE'] === 'daily') ? 'selected' : ''; ?>>Every day at a specific time</option>
          <option value="weekly" <?php echo ($config['SCHEDULE_MODE'] === 'weekly') ? 'selected' : ''; ?>>Once per week</option>
          <option value="custom" <?php echo ($config['SCHEDULE_MODE'] === 'custom') ? 'selected' : ''; ?>>Advanced: custom cron</option>
        </select>
        <div class="zfsas-help">
          The plugin converts this to a cron job automatically.
        </div>
      </div>

      <div class="zfsas-field zfsas-schedule-row" data-mode="minutes" style="margin-top: 12px;">
        <label for="schedule_every_minutes">Every how many minutes?</label>
        <input id="schedule_every_minutes" name="schedule_every_minutes" class="zfsas-input" type="number" min="1" max="59" value="<?php echo h($config['SCHEDULE_EVERY_MINUTES']); ?>">
        <div class="zfsas-help">
          1 means every minute. 15 means every 15 minutes.
        </div>
      </div>

      <div class="zfsas-field zfsas-schedule-row" data-mode="hourly" style="margin-top: 12px;">
        <label for="schedule_every_hours">Every how many hours?</label>
        <input id="schedule_every_hours" name="schedule_every_hours" class="zfsas-input" type="number" min="1" max="24" value="<?php echo h($config['SCHEDULE_EVERY_HOURS']); ?>">
        <div class="zfsas-help">
          1 means every hour. 6 means every 6 hours.
        </div>
      </div>

      <div class="zfsas-field zfsas-schedule-row" data-mode="daily" style="margin-top: 12px;">
        <label>Daily run time (24-hour clock)</label>
        <div class="zfsas-inline">
          <input id="schedule_daily_hour" name="schedule_daily_hour" class="zfsas-input" type="number" min="0" max="23" value="<?php echo h($config['SCHEDULE_DAILY_HOUR']); ?>">
          <input id="schedule_daily_minute" name="schedule_daily_minute" class="zfsas-input" type="number" min="0" max="59" value="<?php echo h($config['SCHEDULE_DAILY_MINUTE']); ?>">
        </div>
        <div class="zfsas-help">
          Example: 03 and 30 means 3:30 AM every day.
        </div>
      </div>

      <div class="zfsas-field zfsas-schedule-row" data-mode="weekly" style="margin-top: 12px;">
        <label for="schedule_weekly_day">Weekly day and time</label>
        <div class="zfsas-inline">
          <select id="schedule_weekly_day" name="schedule_weekly_day" class="zfsas-select">
            <?php foreach ($weekdayNames as $dayValue => $dayLabel) : ?>
              <option value="<?php echo h($dayValue); ?>" <?php echo ((string) $config['SCHEDULE_WEEKLY_DAY'] === (string) $dayValue) ? 'selected' : ''; ?>><?php echo h($dayLabel); ?></option>
            <?php endforeach; ?>
          </select>
          <input id="schedule_weekly_hour" name="schedule_weekly_hour" class="zfsas-input" type="number" min="0" max="23" value="<?php echo h($config['SCHEDULE_WEEKLY_HOUR']); ?>">
          <input id="schedule_weekly_minute" name="schedule_weekly_minute" class="zfsas-input" type="number" min="0" max="59" value="<?php echo h($config['SCHEDULE_WEEKLY_MINUTE']); ?>">
        </div>
        <div class="zfsas-help">
          Example: Sunday, 04 and 00 means every Sunday at 4:00 AM.
        </div>
      </div>

      <div class="zfsas-field zfsas-schedule-row" data-mode="custom" style="margin-top: 12px;">
        <label for="custom_cron_schedule">Custom cron expression (advanced)</label>
        <input id="custom_cron_schedule" name="custom_cron_schedule" class="zfsas-input" value="<?php echo h($config['CUSTOM_CRON_SCHEDULE']); ?>">
        <div class="zfsas-help">
          Use only if you need behavior outside the plain-English options. Format must have exactly 5 fields.
        </div>
      </div>

      <div id="schedule_preview" class="zfsas-preview"></div>
      <div class="zfsas-help" style="margin-top: 10px;">
        Current cron expression: <code><?php echo h($resolvedCron); ?></code>
      </div>
    </div>

    <div class="zfsas-actions">
      <button type="submit" class="btn btn-primary">Save Settings</button>
    </div>
  </form>
</div>

<script>
(function () {
  function byId(id) {
    return document.getElementById(id);
  }

  function pad2(value) {
    value = parseInt(value, 10);
    if (isNaN(value)) {
      value = 0;
    }
    return String(value).padStart(2, '0');
  }

  function showOnlyForMode(mode) {
    var rows = document.querySelectorAll('.zfsas-schedule-row');
    rows.forEach(function (row) {
      row.style.display = (row.getAttribute('data-mode') === mode) ? 'flex' : 'none';
      row.style.flexDirection = 'column';
    });
  }

  function previewText() {
    var mode = byId('schedule_mode').value;
    if (mode === 'disabled') {
      return 'Automatic schedule is disabled. Run manually whenever needed.';
    }

    if (mode === 'minutes') {
      var everyMinutes = parseInt(byId('schedule_every_minutes').value, 10);
      if (isNaN(everyMinutes) || everyMinutes < 1) {
        everyMinutes = 1;
      }
      if (everyMinutes === 1) {
        return 'Runs every minute.';
      }
      return 'Runs every ' + everyMinutes + ' minutes.';
    }

    if (mode === 'hourly') {
      var every = parseInt(byId('schedule_every_hours').value, 10);
      if (isNaN(every) || every < 1) {
        every = 1;
      }
      if (every === 1) {
        return 'Runs every hour at minute 00.';
      }
      return 'Runs every ' + every + ' hours at minute 00.';
    }

    if (mode === 'daily') {
      return 'Runs every day at ' + pad2(byId('schedule_daily_hour').value) + ':' + pad2(byId('schedule_daily_minute').value) + '.';
    }

    if (mode === 'weekly') {
      var dayText = byId('schedule_weekly_day').selectedOptions[0].text;
      return 'Runs every ' + dayText + ' at ' + pad2(byId('schedule_weekly_hour').value) + ':' + pad2(byId('schedule_weekly_minute').value) + '.';
    }

    return 'Runs using custom cron expression: ' + byId('custom_cron_schedule').value;
  }

  function refreshScheduleUI() {
    var mode = byId('schedule_mode').value;
    showOnlyForMode(mode);
    byId('schedule_preview').textContent = previewText();
  }

  function rowIsVisible(row) {
    return !row.classList.contains('zfsas-row-hidden');
  }

  function applyPoolFilter() {
    var poolFilter = byId('dataset_pool_filter');
    var selectedPool = poolFilter ? poolFilter.value : '__all';
    var rows = document.querySelectorAll('.zfsas-dataset-row');

    rows.forEach(function (row) {
      var rowPool = row.getAttribute('data-pool') || '';
      var shouldShow = (selectedPool === '__all' || rowPool === selectedPool);
      row.classList.toggle('zfsas-row-hidden', !shouldShow);
    });
  }

  function refreshDatasetCount() {
    var countLabel = byId('dataset_count');
    if (!countLabel) {
      return;
    }

    var boxes = document.querySelectorAll('.zfsas-dataset-checkbox');
    if (!boxes.length) {
      countLabel.textContent = 'No datasets available.';
      return;
    }

    var selected = 0;
    var visible = 0;
    var visibleSelected = 0;
    boxes.forEach(function (box) {
      var row = box.closest('.zfsas-dataset-row');
      var isVisible = row ? rowIsVisible(row) : true;

      if (isVisible) {
        visible++;
      }

      if (box.checked) {
        selected++;
        if (isVisible) {
          visibleSelected++;
        }
      }
    });

    countLabel.textContent = selected + ' selected of ' + boxes.length + ' datasets (' + visibleSelected + ' of ' + visible + ' shown).';
  }

  function setAllDatasetChecks(checked, visibleOnly) {
    var boxes = document.querySelectorAll('.zfsas-dataset-checkbox');
    boxes.forEach(function (box) {
      if (visibleOnly) {
        var row = box.closest('.zfsas-dataset-row');
        if (row && !rowIsVisible(row)) {
          return;
        }
      }
      box.checked = checked;
    });
    refreshDatasetCount();
  }

  ['schedule_mode', 'schedule_every_minutes', 'schedule_every_hours', 'schedule_daily_hour', 'schedule_daily_minute', 'schedule_weekly_day', 'schedule_weekly_hour', 'schedule_weekly_minute', 'custom_cron_schedule'].forEach(function (id) {
    var element = byId(id);
    if (element) {
      element.addEventListener('change', refreshScheduleUI);
      element.addEventListener('input', refreshScheduleUI);
    }
  });

  var selectAllBtn = byId('dataset_select_all');
  if (selectAllBtn) {
    selectAllBtn.addEventListener('click', function () {
      setAllDatasetChecks(true, false);
    });
  }

  var clearAllBtn = byId('dataset_clear_all');
  if (clearAllBtn) {
    clearAllBtn.addEventListener('click', function () {
      setAllDatasetChecks(false, false);
    });
  }

  var selectVisibleBtn = byId('dataset_select_visible');
  if (selectVisibleBtn) {
    selectVisibleBtn.addEventListener('click', function () {
      setAllDatasetChecks(true, true);
    });
  }

  var clearVisibleBtn = byId('dataset_clear_visible');
  if (clearVisibleBtn) {
    clearVisibleBtn.addEventListener('click', function () {
      setAllDatasetChecks(false, true);
    });
  }

  var poolFilter = byId('dataset_pool_filter');
  if (poolFilter) {
    poolFilter.addEventListener('change', function () {
      applyPoolFilter();
      refreshDatasetCount();
    });
  }

  var datasetBoxes = document.querySelectorAll('.zfsas-dataset-checkbox');
  datasetBoxes.forEach(function (box) {
    box.addEventListener('change', refreshDatasetCount);
  });

  applyPoolFilter();
  refreshScheduleUI();
  refreshDatasetCount();
})();
</script>
