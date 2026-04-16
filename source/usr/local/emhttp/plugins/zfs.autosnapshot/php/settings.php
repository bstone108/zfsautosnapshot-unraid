<?php
$pluginName = 'zfs.autosnapshot';
$settingsPagePath = '/Settings/ZFSAutoSnapshot';
$configDir = "/boot/config/plugins/{$pluginName}";
$configFile = "{$configDir}/zfs_autosnapshot.conf";
$sendConfigFile = "{$configDir}/zfs_send.conf";
$syncScript = "/usr/local/emhttp/plugins/{$pluginName}/scripts/sync-cron.sh";
$logApiUrl = "/plugins/{$pluginName}/php/log-tail.php";
$logStreamApiUrl = "/plugins/{$pluginName}/php/log-stream.php";
$runApiUrl = "/plugins/{$pluginName}/php/run-now.php";
$saveApiUrl = "/plugins/{$pluginName}/php/save-settings.php";
$sendSettingsUrl = "/plugins/{$pluginName}/php/send-settings.php";
$migrateDatasetsUrl = "/plugins/{$pluginName}/php/migrate-datasets.php";
$snapshotManagerPageUrl = "/plugins/{$pluginName}/php/snapshot-manager-page.php";
$snapshotManagerEmbeddedUrl = $snapshotManagerPageUrl . '?embedded=1';
$recoveryToolsUrl = "/plugins/{$pluginName}/php/recovery-tools.php";
$snapshotManagerListUrl = "/plugins/{$pluginName}/php/snapshot-manager-list.php";
$snapshotManagerDatasetUrl = "/plugins/{$pluginName}/php/snapshot-manager-dataset.php";
$snapshotManagerActionUrl = "/plugins/{$pluginName}/php/snapshot-manager-action.php";
$logPollIntervalMs = 2000;

require_once __DIR__ . '/response-helpers.php';
require_once __DIR__ . '/send-helpers.php';

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

$sendDefaults = [
    'SEND_SNAPSHOT_PREFIX' => 'zfs-send-',
    'SEND_JOBS' => '',
];

function h($value)
{
    return htmlspecialchars((string) $value, ENT_QUOTES, 'UTF-8');
}

function isAjaxSaveRequest()
{
    if (($_POST['ajax'] ?? '') === 'save') {
        return true;
    }

    $requestedWith = $_SERVER['HTTP_X_REQUESTED_WITH'] ?? '';
    return is_string($requestedWith) && strcasecmp($requestedWith, 'XMLHttpRequest') === 0;
}

function currentRequestUriWithQuery($replacements = [])
{
    $requestUri = (string) ($_SERVER['REQUEST_URI'] ?? '');
    if ($requestUri === '') {
        return '';
    }

    $parts = parse_url($requestUri);
    $path = (string) ($parts['path'] ?? '');
    if ($path === '') {
        return '';
    }

    $query = [];
    if (isset($parts['query'])) {
        parse_str((string) $parts['query'], $query);
    }

    foreach ($replacements as $key => $value) {
        if ($value === null) {
            unset($query[$key]);
        } else {
            $query[$key] = $value;
        }
    }

    $queryString = http_build_query($query);
    return ($queryString === '') ? $path : ($path . '?' . $queryString);
}

function pluginSettingsPageUrl($fallbackPath, $replacements = [])
{
    $fallbackPath = trim((string) $fallbackPath);
    if ($fallbackPath === '') {
        $fallbackPath = '/Settings/ZFSAutoSnapshot';
    }

    $parts = parse_url($fallbackPath);
    if (!is_array($parts)) {
        $parts = ['path' => '/Settings/ZFSAutoSnapshot'];
    }

    $path = trim((string) ($parts['path'] ?? ''));
    if ($path === '') {
        $path = '/Settings/ZFSAutoSnapshot';
    }

    $query = [];
    if (isset($parts['query'])) {
        parse_str((string) $parts['query'], $query);
    }

    foreach ($replacements as $key => $value) {
        if ($value === null) {
            unset($query[$key]);
        } else {
            $query[$key] = $value;
        }
    }

    $queryString = http_build_query($query);
    return ($queryString === '') ? $path : ($path . '?' . $queryString);
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

function detectInstalledPluginVersion($pluginName)
{
    $pluginName = trim((string) $pluginName);
    if ($pluginName === '') {
        return 'unknown';
    }

    $manifestPaths = [
        "/var/log/plugins/{$pluginName}.plg",
        "/boot/config/plugins/{$pluginName}.plg",
    ];

    foreach ($manifestPaths as $manifestPath) {
        if (!is_file($manifestPath) || !is_readable($manifestPath)) {
            continue;
        }

        $xmlHead = @file_get_contents($manifestPath, false, null, 0, 8192);
        if (!is_string($xmlHead) || $xmlHead === '') {
            continue;
        }

        if (preg_match('/<PLUGIN\b[^>]*\bversion="([^"]+)"/i', $xmlHead, $match) === 1) {
            $version = trimValue($match[1]);
            if ($version !== '') {
                return $version;
            }
        }
    }

    $packagePattern = '/var/log/packages/zfs-autosnapshot-*';
    $packageFiles = glob($packagePattern);
    if (is_array($packageFiles) && count($packageFiles) > 0) {
        natsort($packageFiles);
        $latest = (string) end($packageFiles);
        $packageName = basename($latest);
        if (preg_match('/^zfs-autosnapshot-(.+)-[^-]+-[0-9]+$/', $packageName, $match) === 1) {
            $version = trimValue($match[1]);
            if ($version !== '') {
                return $version;
            }
        }
    }

    return 'unknown';
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

function buildDatasetRows($availableDatasets, $configuredDatasetMap, $sendDestinationDatasets = [])
{
    $rows = [];
    $seen = [];

    foreach ($availableDatasets as $dataset) {
        $pool = datasetPoolName($dataset);
        $locked = isset($sendDestinationDatasets[$dataset]);
        $rows[] = [
            'dataset' => $dataset,
            'pool' => $pool,
            'selected' => (!$locked && isset($configuredDatasetMap[$dataset])),
            'threshold' => isset($configuredDatasetMap[$dataset]) ? $configuredDatasetMap[$dataset] : '100G',
            'available' => true,
            'locked' => $locked,
        ];
        $seen[$dataset] = true;
    }

    foreach ($configuredDatasetMap as $dataset => $threshold) {
        if (isset($seen[$dataset])) {
            continue;
        }

        $pool = datasetPoolName($dataset);
        $locked = isset($sendDestinationDatasets[$dataset]);
        $rows[] = [
            'dataset' => $dataset,
            'pool' => $pool,
            'selected' => !$locked,
            'threshold' => $threshold,
            'available' => false,
            'locked' => $locked,
        ];
    }

    return sortDatasetRows($rows);
}

function buildDatasetRowsFromPost($postedNames, $postedSelected, $postedThresholds, $availableDatasets, $configuredDatasetMap, $sendDestinationDatasets = [])
{
    $rows = [];
    $seen = [];
    $availableSet = array_fill_keys($availableDatasets, true);

    foreach ($postedNames as $index => $datasetRaw) {
        $dataset = trimValue($datasetRaw);
        if ($dataset === '' || isset($seen[$dataset])) {
            continue;
        }

        if (!isValidDatasetName($dataset)) {
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
            'selected' => (!isset($sendDestinationDatasets[$dataset]) && isset($postedSelected[$index]) && (string) $postedSelected[$index] === '1'),
            'threshold' => strtoupper(str_replace(' ', '', $threshold)),
            'available' => isset($availableSet[$dataset]),
            'locked' => isset($sendDestinationDatasets[$dataset]),
        ];
    }

    return sortDatasetRows($rows);
}

function buildDatasetsCsvFromPost($postedNames, $postedSelected, $postedThresholds, &$errors, $sendDestinationDatasets = [])
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

        $isLocked = isset($sendDestinationDatasets[$dataset]);
        $isSelected = (!$isLocked && isset($postedSelected[$index]) && (string) $postedSelected[$index] === '1');
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

function cronHasSafeCharacters($cron)
{
    return preg_match('/^[A-Za-z0-9*\/,\- ]+$/', trim((string) $cron)) === 1;
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
        if (!cronHasSafeCharacters($cron)) {
            $errors[] = 'Custom cron expression contains unsupported characters.';
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

$isPostRequest = (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST');
$isAjaxSaveRequest = ((defined('ZFSAS_FORCE_AJAX_SAVE') && ZFSAS_FORCE_AJAX_SAVE) || ($isPostRequest && isAjaxSaveRequest()));

$installedVersion = $isAjaxSaveRequest ? '' : detectInstalledPluginVersion($pluginName);
$defaultSettingsReturnUrl = pluginSettingsPageUrl($settingsPagePath, ['saved' => null]);

$config = parseConfigFile($configFile, $defaults);
$errors = [];
$notices = [];
$sendConfig = zfsas_send_parse_config_file($sendConfigFile, $sendDefaults);
$sendParseErrors = [];
$sendParseWarnings = [];
$sendJobs = zfsas_send_parse_jobs($sendConfig['SEND_JOBS'] ?? '', $sendParseErrors, $sendParseWarnings);
$sendDestinationCandidates = array_values(array_unique(array_merge($availableDatasets, array_keys($configuredDatasetMap))));
$sendDestinationDatasets = zfsas_send_destination_datasets_from_jobs($sendJobs, $sendDestinationCandidates);
$initialSection = trim((string) ($_GET['section'] ?? 'main'));
if (!in_array($initialSection, ['main', 'special-features', 'repair-tools', 'snapshot-manager'], true)) {
    $initialSection = 'main';
}

if (!$isAjaxSaveRequest && (($_GET['saved'] ?? '') === '1')) {
    $notices[] = 'Settings saved and schedule applied.';
}

$datasetParseWarnings = [];
$configuredDatasetMap = parseDatasetsCsv($config['DATASETS'], $datasetParseWarnings);

$datasetDiscoveryError = null;
$availableDatasets = [];
$datasetRows = [];
$datasetPools = [];

if ($isAjaxSaveRequest) {
    $datasetRows = buildDatasetRows([], $configuredDatasetMap, $sendDestinationDatasets);
    $datasetPools = buildDatasetPools($datasetRows);
} else {
    $availableDatasets = listZfsDatasets($datasetDiscoveryError);
    $sendDestinationCandidates = array_values(array_unique(array_merge($availableDatasets, array_keys($configuredDatasetMap))));
    $sendDestinationDatasets = zfsas_send_destination_datasets_from_jobs($sendJobs, $sendDestinationCandidates);
    $datasetRows = buildDatasetRows($availableDatasets, $configuredDatasetMap, $sendDestinationDatasets);
    $datasetPools = buildDatasetPools($datasetRows);
}

if (!$isAjaxSaveRequest && !empty($datasetParseWarnings)) {
    foreach ($datasetParseWarnings as $warning) {
        $notices[] = $warning;
    }
}

if (!$isAjaxSaveRequest && !empty($sendParseWarnings)) {
    foreach ($sendParseWarnings as $warning) {
        $notices[] = $warning;
    }
}

if ($isPostRequest) {
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

    $datasetRows = buildDatasetRowsFromPost($postDatasetNames, $postDatasetSelected, $postDatasetThresholds, $availableDatasets, $configuredDatasetMap, $sendDestinationDatasets);
    $datasetPools = buildDatasetPools($datasetRows);

    if (count($postDatasetNames) === 0) {
        $errors[] = 'Dataset selection data was not submitted. Refresh the page and try again.';
    } else {
        $datasetCsv = buildDatasetsCsvFromPost($postDatasetNames, $postDatasetSelected, $postDatasetThresholds, $errors, $sendDestinationDatasets);
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
                if (!$isAjaxSaveRequest) {
                    $postSaveWarnings = [];
                    $configuredDatasetMap = parseDatasetsCsv($config['DATASETS'], $postSaveWarnings);
                    $datasetRows = buildDatasetRows($availableDatasets, $configuredDatasetMap, $sendDestinationDatasets);
                    $datasetPools = buildDatasetPools($datasetRows);

                    $returnTarget = zfsas_normalize_return_url($_POST['return_to'] ?? '', $defaultSettingsReturnUrl);
                    $redirectUrl = pluginSettingsPageUrl($returnTarget, [
                        'saved' => '1',
                    ]);

                    if ($redirectUrl !== '') {
                        zfsas_send_redirect_page($redirectUrl);
                    }
                }

                $notices[] = 'Settings saved and schedule applied.';
            }
        }
    }

    if ($isAjaxSaveRequest) {
        $ajaxNotices = $notices;
        $ajaxErrors = $errors;
        $ajaxResolvedCron = trim((string) ($config['CRON_SCHEDULE'] ?? ''));
        if ($ajaxResolvedCron === '') {
            $ajaxResolvedCron = '(disabled)';
        }

        zfsas_emit_marked_json([
            'ok' => empty($ajaxErrors),
            'errors' => array_values($ajaxErrors),
            'notices' => array_values($ajaxNotices),
            'resolvedCron' => $ajaxResolvedCron,
            'prefix' => (string) ($config['PREFIX'] ?? ''),
        ], empty($ajaxErrors) ? 200 : 400);
    }
}

$resolvedCron = trim((string) ($config['CRON_SCHEDULE'] ?? ''));
if ($resolvedCron === '') {
    $resolvedCron = '(disabled)';
}
$renderStandalonePage = !empty($GLOBALS['zfsas_render_standalone_page']);
?>
<?php if ($renderStandalonePage) : ?>
<!doctype html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ZFS Auto Snapshot Settings</title>
</head>
<body>
<?php endif; ?>
<style>
.zfsas-wrap {
  margin: 16px;
  max-width: 1440px;
  font-family: "Segoe UI", Tahoma, Geneva, Verdana, sans-serif;
  color: var(--text-color, #1f2933);
}

.zfsas-header {
  display: flex;
  align-items: center;
  gap: 10px;
  flex-wrap: wrap;
}

.zfsas-title {
  margin: 0;
}

.zfsas-subtitle {
  color: var(--text-color, #444);
  opacity: 0.85;
  margin: 6px 0 16px;
}

.zfsas-version {
  display: inline-flex;
  align-items: center;
  padding: 3px 10px;
  font-size: 12px;
  font-weight: 600;
  border: 1px solid var(--border-color, #bfd3ff);
  border-radius: 999px;
  background: var(--input-background-color, var(--background-color, rgba(82, 126, 235, 0.08)));
  color: inherit;
}

.zfsas-card {
  background: var(--background-color, #fff);
  border: 1px solid var(--border-color, #d9e1ea);
  border-radius: 10px;
  padding: 16px;
  margin-bottom: 14px;
  box-shadow: 0 1px 2px rgba(0, 0, 0, 0.04);
  color: var(--text-color, #1f2933);
}

.zfsas-section-nav {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
  margin-bottom: 14px;
}

.zfsas-section-tab {
  appearance: none;
  border: 1px solid var(--border-color, #cfd8e3);
  border-radius: 999px;
  background: var(--input-background-color, var(--background-color, #fff));
  color: inherit;
  padding: 8px 14px;
  font-size: 13px;
  font-weight: 600;
  cursor: pointer;
  transition: background 0.15s ease, border-color 0.15s ease, box-shadow 0.15s ease;
}

.zfsas-section-tab:hover {
  border-color: rgba(82, 126, 235, 0.45);
}

.zfsas-section-tab.is-active {
  background: rgba(82, 126, 235, 0.12);
  border-color: rgba(82, 126, 235, 0.45);
  box-shadow: inset 0 0 0 1px rgba(82, 126, 235, 0.12);
}

.zfsas-section-panel {
  display: none;
}

.zfsas-section-panel.is-active {
  display: block;
}

.zfsas-placeholder-copy {
  max-width: 760px;
}

.zfsas-placeholder-title {
  margin: 0 0 6px;
}

.zfsas-embedded-shell {
  max-width: none;
  overflow: visible;
}

.zfsas-embedded-shell .zfsas-help {
  margin-bottom: 12px;
}

.zfsas-embedded-frame-wrap {
  border: 1px solid var(--border-color, #d9e1ea);
  border-radius: 10px;
  overflow-x: auto;
  overflow-y: hidden;
  background: var(--background-color, #fff);
}

#zfsas_panel_snapshot_manager .zfsas-embedded-shell {
  padding-bottom: 0;
}

#zfsas_panel_snapshot_manager .zfsas-embedded-frame-wrap {
  margin-left: -16px;
  margin-right: -16px;
  margin-bottom: -16px;
  border-left: 0;
  border-right: 0;
  border-bottom: 0;
  border-radius: 0 0 10px 10px;
}

.zfsas-embedded-frame {
  display: block;
  width: 100%;
  min-height: 980px;
  border: 0;
  background: transparent;
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
  color: var(--text-color, #4f5a66);
  opacity: 0.82;
  font-size: 12px;
  line-height: 1.4;
}

.zfsas-input,
.zfsas-select {
  width: 100%;
  box-sizing: border-box;
  padding: 8px 10px;
  border: 1px solid var(--input-border-color, var(--border-color, #b8c5d1));
  border-radius: 8px;
  background: var(--input-background-color, var(--background-color, #fff));
  color: var(--text-color, #1f2933);
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
  background: rgba(176, 0, 32, 0.08);
  border: 1px solid rgba(176, 0, 32, 0.28);
  color: inherit;
}

.zfsas-alert-ok {
  background: rgba(46, 125, 50, 0.1);
  border: 1px solid rgba(46, 125, 50, 0.28);
  color: inherit;
}

.zfsas-alert-warn {
  background: rgba(180, 120, 0, 0.1);
  border: 1px solid rgba(180, 120, 0, 0.28);
  color: inherit;
}

.zfsas-dataset-toolbar {
  display: flex;
  gap: 10px;
  align-items: center;
  margin-top: 12px;
  flex-wrap: wrap;
  padding: 10px;
  border: 1px solid var(--border-color, #e1e8ef);
  border-radius: 8px;
  background: rgba(82, 126, 235, 0.06);
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
  background: rgba(82, 126, 235, 0.12);
  border: 1px solid rgba(82, 126, 235, 0.25);
  color: inherit;
}

.zfsas-row-hidden {
  display: none;
}

.zfsas-table-wrap {
  margin-top: 10px;
  border: 1px solid var(--border-color, #e1e8ef);
  border-radius: 8px;
  overflow-x: auto;
}

.zfsas-table {
  width: 100%;
  border-collapse: collapse;
  min-width: 0;
}

.zfsas-table th,
.zfsas-table td {
  padding: 10px 12px;
  border-bottom: 1px solid var(--border-color, #edf2f7);
  vertical-align: top;
}

.zfsas-table th {
  background: rgba(82, 126, 235, 0.06);
  text-align: left;
  font-size: 13px;
  color: var(--text-color, #1f2933);
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
  white-space: normal;
  overflow-wrap: anywhere;
  word-break: break-word;
}

.zfsas-dataset-cell {
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.zfsas-threshold-col {
  width: 180px;
}

.zfsas-threshold-input {
  width: 120px;
  max-width: 100%;
  min-width: 0;
}

.zfsas-badge {
  display: inline-block;
  margin-left: 8px;
  padding: 2px 6px;
  font-size: 11px;
  border-radius: 99px;
  background: rgba(180, 120, 0, 0.1);
  border: 1px solid rgba(180, 120, 0, 0.28);
  color: inherit;
}

.zfsas-row-locked {
  opacity: 0.6;
}

.zfsas-empty {
  margin-top: 12px;
  padding: 12px;
  border: 1px dashed var(--border-color, #c8d5e3);
  border-radius: 8px;
  background: rgba(82, 126, 235, 0.04);
  color: var(--text-color, #455261);
}

.zfsas-schedule-row {
  display: none;
}

.zfsas-preview {
  margin-top: 10px;
  padding: 10px;
  background: var(--background-color, rgba(82, 126, 235, 0.08));
  border: 1px solid var(--border-color, rgba(82, 126, 235, 0.24));
  border-radius: 8px;
  color: inherit;
}

.zfsas-log-toolbar {
  margin-top: 10px;
  display: flex;
  gap: 8px;
  align-items: center;
  flex-wrap: wrap;
}

.zfsas-log-toolbar .zfsas-select {
  width: auto;
  min-width: 140px;
}

.zfsas-log-status {
  margin-left: auto;
  font-size: 12px;
  color: var(--text-color, #4f5a66);
  opacity: 0.82;
}

.zfsas-log-status.error {
  color: var(--text-color, #8f2d2a);
  opacity: 1;
}

.zfsas-log-output {
  margin-top: 10px;
  min-height: 260px;
  max-height: 420px;
  overflow: auto;
  padding: 10px 12px;
  border-radius: 8px;
  border: 1px solid var(--border-color, #1f2f40);
  background: #0d1724;
  color: #d9edf7;
  font: 12px/1.35 Consolas, Menlo, Monaco, monospace;
  white-space: pre-wrap;
}

.zfsas-actions {
  display: flex;
  justify-content: flex-end;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
  margin-top: 12px;
}

.zfsas-manual-status {
  margin-right: auto;
  font-size: 12px;
  color: var(--text-color, #4f5a66);
  opacity: 0.82;
}

.zfsas-manual-status.error {
  color: var(--text-color, #8f2d2a);
  opacity: 1;
}

.zfsas-save-feedback-inline {
  flex: 0 0 360px;
  width: 360px;
  min-height: 28px;
  display: flex;
  align-items: center;
  justify-content: flex-end;
}

.zfsas-save-feedback-inline .zfsas-alert {
  width: 100%;
  margin-bottom: 0;
  padding: 8px 10px;
  font-size: 12px;
}

.zfsas-sm-toolbar {
  display: flex;
  gap: 8px;
  align-items: center;
  flex-wrap: wrap;
  margin-top: 12px;
}

.zfsas-sm-toolbar-status {
  margin-left: auto;
  font-size: 12px;
  color: var(--text-color, #4f5a66);
  opacity: 0.82;
}

.zfsas-sm-toolbar-status.error {
  color: var(--text-color, #8f2d2a);
  opacity: 1;
}

.zfsas-sm-summary-table th:last-child,
.zfsas-sm-summary-table td:last-child {
  text-align: right;
}

.zfsas-sm-status-chip {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 2px 8px;
  border-radius: 999px;
  font-size: 11px;
  border: 1px solid var(--border-color, #d9e1ea);
  background: rgba(82, 126, 235, 0.06);
}

.zfsas-sm-status-chip.is-busy {
  background: rgba(180, 120, 0, 0.1);
  border-color: rgba(180, 120, 0, 0.28);
}

.zfsas-sm-status-chip.is-error {
  background: rgba(176, 0, 32, 0.08);
  border-color: rgba(176, 0, 32, 0.28);
}

.zfsas-sm-drawer-backdrop {
  position: fixed;
  inset: 0;
  background: rgba(15, 23, 42, 0.45);
  z-index: 1040;
}

.zfsas-sm-drawer {
  position: fixed;
  top: 0;
  right: 0;
  width: min(860px, 100vw);
  height: 100vh;
  z-index: 1050;
  display: flex;
  justify-content: flex-end;
}

.zfsas-sm-drawer-panel {
  width: min(860px, 100vw);
  height: 100vh;
  overflow: auto;
  background: var(--background-color, #fff);
  color: var(--text-color, #1f2933);
  box-shadow: -12px 0 32px rgba(15, 23, 42, 0.18);
  padding: 20px 18px 24px;
}

.zfsas-sm-drawer-header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 12px;
  margin-bottom: 12px;
}

.zfsas-sm-drawer-title {
  margin: 0;
}

.zfsas-sm-drawer-subtitle {
  margin-top: 6px;
  color: var(--text-color, #4f5a66);
  opacity: 0.85;
  font-size: 13px;
}

.zfsas-sm-bulk-bar {
  position: sticky;
  top: 0;
  z-index: 2;
  display: flex;
  gap: 8px;
  align-items: center;
  flex-wrap: wrap;
  padding: 10px 0 12px;
  background: linear-gradient(to bottom, var(--background-color, #fff) 75%, rgba(255,255,255,0));
}

.zfsas-sm-bulk-count {
  margin-left: auto;
  font-size: 12px;
  color: var(--text-color, #4f5a66);
  opacity: 0.82;
}

.zfsas-sm-feedback {
  margin: 10px 0 0;
}

.zfsas-sm-feedback .zfsas-alert {
  margin-bottom: 0;
}

.zfsas-sm-table .zfsas-select-cell {
  width: 38px;
  text-align: center;
}

.zfsas-sm-table .zfsas-actions-cell {
  min-width: 220px;
  text-align: right;
}

.zfsas-sm-table .zfsas-actions-cell .btn {
  margin-left: 6px;
  margin-top: 4px;
}

.zfsas-sm-snapshot-meta {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
  margin-top: 4px;
}

.zfsas-sm-meta-chip {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  font-size: 11px;
  padding: 2px 6px;
  border-radius: 999px;
  background: rgba(82, 126, 235, 0.06);
  border: 1px solid var(--border-color, #d9e1ea);
}

.zfsas-sm-meta-chip.is-protected {
  background: rgba(180, 120, 0, 0.1);
  border-color: rgba(180, 120, 0, 0.28);
}

@media (max-width: 900px) {
  .zfsas-grid {
    grid-template-columns: 1fr;
  }

  .zfsas-header {
    align-items: flex-start;
    flex-direction: column;
    gap: 6px;
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

  .zfsas-log-status {
    margin-left: 0;
    width: 100%;
  }

  .zfsas-manual-status {
    margin-right: 0;
    width: 100%;
  }

  .zfsas-save-feedback-inline {
    flex: 1 1 100%;
    width: 100%;
    justify-content: flex-start;
  }

  .zfsas-sm-toolbar-status,
  .zfsas-sm-bulk-count {
    margin-left: 0;
    width: 100%;
  }

  .zfsas-sm-drawer-panel {
    padding: 18px 14px 24px;
  }

  .zfsas-sm-table .zfsas-actions-cell {
    min-width: 160px;
  }
}
</style>

<div class="zfsas-wrap">
  <div class="zfsas-header">
    <h2 class="zfsas-title">ZFS Auto Snapshot</h2>
    <span class="zfsas-version">Version <?php echo h($installedVersion); ?></span>
  </div>
  <div class="zfsas-subtitle">
    Manage dataset selection, retention policy, and automatic run schedule.
  </div>

  <div id="compat_feedback"></div>

  <?php if ($datasetDiscoveryError !== null) : ?>
    <div class="zfsas-alert zfsas-alert-warn">
      <?php echo h($datasetDiscoveryError); ?>
      Existing configured datasets are still shown.
    </div>
  <?php endif; ?>

  <form method="post" action="<?php echo h($saveApiUrl); ?>" data-ajax-action="<?php echo h($saveApiUrl); ?>" id="zfsas_settings_form">
    <input type="hidden" name="return_to" value="<?php echo h($defaultSettingsReturnUrl); ?>">
    <div class="zfsas-section-nav" role="tablist" aria-label="Plugin sections">
      <button type="button" class="zfsas-section-tab is-active" id="zfsas_tab_main" data-section-target="main" role="tab" aria-selected="true" aria-controls="zfsas_panel_main">Main Page</button>
      <button type="button" class="zfsas-section-tab" id="zfsas_tab_features" data-section-target="special-features" role="tab" aria-selected="false" aria-controls="zfsas_panel_special_features">Special Features</button>
      <button type="button" class="zfsas-section-tab" id="zfsas_tab_repairs" data-section-target="repair-tools" role="tab" aria-selected="false" aria-controls="zfsas_panel_repair_tools">Repair Tools</button>
      <button type="button" class="zfsas-section-tab" id="zfsas_tab_snapshot_manager" data-section-target="snapshot-manager" role="tab" aria-selected="false" aria-controls="zfsas_panel_snapshot_manager">Snapshot Manager</button>
    </div>

    <div class="zfsas-section-panel is-active" id="zfsas_panel_main" data-section-panel="main" role="tabpanel" aria-labelledby="zfsas_tab_main">
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
                  <th class="zfsas-threshold-col">Pool free-space target</th>
                </tr>
              </thead>
              <tbody>
                <?php foreach ($datasetRows as $index => $row) : ?>
                  <tr class="zfsas-dataset-row<?php echo !empty($row['locked']) ? ' zfsas-row-locked' : ''; ?>" data-pool="<?php echo h($row['pool']); ?>">
                    <td class="zfsas-center">
                      <input type="hidden" name="dataset_name[<?php echo (int) $index; ?>]" value="<?php echo h($row['dataset']); ?>">
                      <input class="zfsas-dataset-checkbox" type="checkbox" name="dataset_selected[<?php echo (int) $index; ?>]" value="1" <?php echo $row['selected'] ? 'checked' : ''; ?> <?php echo !empty($row['locked']) ? 'disabled' : ''; ?>>
                    </td>
                    <td>
                      <div class="zfsas-dataset-cell">
                        <div>
                          <code><?php echo h($row['dataset']); ?></code>
                          <span class="zfsas-pool-chip"><?php echo h($row['pool']); ?></span>
                          <?php if (!empty($row['locked'])) : ?>
                            <span class="zfsas-badge">Reserved for ZFS Send destination</span>
                          <?php endif; ?>
                          <?php if (!$row['available']) : ?>
                            <span class="zfsas-badge">Not currently detected</span>
                          <?php endif; ?>
                        </div>
                      </div>
                    </td>
                    <td class="zfsas-threshold-col">
                      <input class="zfsas-input zfsas-threshold-input" name="dataset_threshold[<?php echo (int) $index; ?>]" value="<?php echo h($row['threshold']); ?>" <?php echo !empty($row['locked']) ? 'disabled' : ''; ?>>
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
            Safety guard: only snapshots containing the prefix <code id="prefix_preview"><?php echo h($config['PREFIX']); ?></code> are eligible for automatic deletion.
          </div>
        </div>

        <div class="zfsas-field" style="margin-top: 12px;">
          <label for="dry_run">Mode</label>
          <label class="zfsas-checkline" for="dry_run">
            <input type="checkbox" id="dry_run" name="dry_run" value="1" <?php echo ($config['DRY_RUN'] === '1') ? 'checked' : ''; ?>>
            <span>Dry run (preview only, no snapshot create/delete)</span>
          </label>
          <div class="zfsas-help">
            Leave this unchecked for normal operation. In Dry Run mode, use Debug Log view to see each action that would be taken.
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
          Current cron expression: <code id="resolved_cron_value"><?php echo h($resolvedCron); ?></code>
        </div>
      </div>

      <div class="zfsas-actions">
        <div id="manual_run_status" class="zfsas-manual-status">Manual run is ready.</div>
        <div id="save_feedback" class="zfsas-save-feedback-inline">
          <?php if (!empty($errors)) : ?>
            <div class="zfsas-alert zfsas-alert-error">
              <?php foreach ($errors as $error) : ?>
                <div><?php echo h($error); ?></div>
              <?php endforeach; ?>
            </div>
          <?php endif; ?>
        </div>
        <button type="button" class="btn" id="manual_run">Run Now</button>
        <button
          type="button"
          class="btn btn-primary"
          id="zfsas_save_btn"
          <?php if (!empty($notices)) : ?>data-show-saved="1"<?php endif; ?>
        >Save Settings</button>
        <noscript><button type="submit" class="btn btn-primary">Save Settings</button></noscript>
      </div>

      <div class="zfsas-card" id="live_run_log">
        <h3>Run Output</h3>
        <div class="zfsas-help">
          Default view shows a concise one-run summary.
          Use "Show Debug Log" to inspect the verbose debug log.
          These logs are stored in protected root-owned system paths and are only exposed through this page.
          "Download Logs" exports both logs in one text file.
        </div>
        <div class="zfsas-log-toolbar">
          <button type="button" class="btn" id="log_view_toggle">Show Debug Log</button>
          <button type="button" class="btn" id="log_toggle">Pause Live View</button>
          <button type="button" class="btn" id="log_refresh">Refresh Now</button>
          <button type="button" class="btn" id="log_download">Download Logs</button>
          <select id="log_lines" class="zfsas-select">
            <option value="200">Last 200 lines</option>
            <option value="400" selected>Last 400 lines</option>
            <option value="800">Last 800 lines</option>
            <option value="1200">Last 1200 lines</option>
          </select>
          <div id="log_status" class="zfsas-log-status">Loading live log...</div>
        </div>
        <pre id="log_output" class="zfsas-log-output">Loading log output...</pre>
      </div>
    </div>

    <div class="zfsas-section-panel" id="zfsas_panel_special_features" data-section-panel="special-features" role="tabpanel" aria-labelledby="zfsas_tab_features" hidden>
      <div class="zfsas-card zfsas-placeholder-copy">
        <h3 class="zfsas-placeholder-title">Special Features</h3>
        <div class="zfsas-help">
          Optional power-user features live here. ZFS Send keeps its own config and queue page, and the dataset migrator has its own guided workflow because it needs container handling, verification progress, and rollback safety.
        </div>
        <div style="margin-top: 14px;">
          <button type="button" class="btn btn-primary" id="open_send_settings">Open ZFS Send</button>
          <button type="button" class="btn" id="open_dataset_migrator">Open Dataset Migrator</button>
        </div>
      </div>
    </div>

    <div class="zfsas-section-panel" id="zfsas_panel_repair_tools" data-section-panel="repair-tools" role="tabpanel" aria-labelledby="zfsas_tab_repairs" hidden>
      <div class="zfsas-card zfsas-placeholder-copy">
        <h3 class="zfsas-placeholder-title">Repair Tools</h3>
        <div class="zfsas-help">
          Guided repair and recovery utilities live on their own page so they can surface scrub state, corruption diagnostics, and recovery actions without cluttering the main settings page.
        </div>
        <div style="margin-top: 14px;">
          <button type="button" class="btn btn-primary" id="open_recovery_tools">Open Recovery Tools</button>
        </div>
      </div>
    </div>

    <div class="zfsas-section-panel" id="zfsas_panel_snapshot_manager" data-section-panel="snapshot-manager" role="tabpanel" aria-labelledby="zfsas_tab_snapshot_manager" hidden>
      <div class="zfsas-card zfsas-embedded-shell">
        <h3 class="zfsas-placeholder-title">Snapshot Manager</h3>
        <div class="zfsas-help">
          Snapshot Manager is available directly in this tab. It still stays lightweight by waiting to load the full dataset summary and drawer UI until you switch here.
        </div>
        <div class="zfsas-embedded-frame-wrap">
          <iframe
            id="snapshot_manager_frame"
            class="zfsas-embedded-frame"
            title="Snapshot Manager"
            loading="lazy"
            data-src="<?php echo h($snapshotManagerEmbeddedUrl); ?>"
          ></iframe>
        </div>
      </div>
    </div>
  </form>
</div>

<script>
(function () {
  function byId(id) {
    return document.getElementById(id);
  }

  var logPollIntervalMs = <?php echo (int) $logPollIntervalMs; ?>;
  var logApiUrl = <?php echo json_encode($logApiUrl); ?>;
  var logStreamApiUrl = <?php echo json_encode($logStreamApiUrl); ?>;
  var runApiUrl = <?php echo json_encode($runApiUrl); ?>;
  var saveApiUrl = <?php echo json_encode($saveApiUrl); ?>;
  var sendSettingsUrl = <?php echo json_encode($sendSettingsUrl); ?>;
  var migrateDatasetsUrl = <?php echo json_encode($migrateDatasetsUrl); ?>;
  var snapshotManagerEmbeddedUrl = <?php echo json_encode($snapshotManagerEmbeddedUrl); ?>;
  var recoveryToolsUrl = <?php echo json_encode($recoveryToolsUrl); ?>;
  var snapshotManagerListUrl = <?php echo json_encode($snapshotManagerListUrl); ?>;
  var snapshotManagerDatasetUrl = <?php echo json_encode($snapshotManagerDatasetUrl); ?>;
  var snapshotManagerActionUrl = <?php echo json_encode($snapshotManagerActionUrl); ?>;
  var initialSection = <?php echo json_encode($initialSection); ?>;
  var logView = 'summary';
  var logPaused = false;
  var logTimer = null;
  var logStreamSource = null;
  var logFingerprint = '';
  var saveForm = byId('zfsas_settings_form');
  var saveButton = byId('zfsas_save_btn');
  var saveButtonDefaultText = saveButton ? saveButton.textContent : 'Save Settings';
  var saveBusy = false;
  var saveSuccessTimer = null;
  var sectionTabs = document.querySelectorAll('.zfsas-section-tab');
  var sectionPanels = document.querySelectorAll('.zfsas-section-panel');
  var snapshotManagerLoaded = false;
  var snapshotManagerLoading = false;
  var snapshotManagerCurrentDataset = '';
  var snapshotManagerSelection = {};
  var snapshotManagerFrame = byId('snapshot_manager_frame');
  var snapshotManagerFrameLoaded = false;

  function escapeHtml(text) {
    return String(text)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function activateSection(sectionName) {
    if (typeof sectionName !== 'string' || sectionName === '') {
      sectionName = 'main';
    }

    sectionTabs.forEach(function (tab) {
      var isActive = tab.getAttribute('data-section-target') === sectionName;
      tab.classList.toggle('is-active', isActive);
      tab.setAttribute('aria-selected', isActive ? 'true' : 'false');
    });

    sectionPanels.forEach(function (panel) {
      var isActive = panel.getAttribute('data-section-panel') === sectionName;
      panel.classList.toggle('is-active', isActive);
      panel.hidden = !isActive;
    });

    if (sectionName === 'snapshot-manager') {
      ensureSnapshotManagerEmbeddedLoaded();
    }

  }

  function requestSnapshotManagerEmbeddedHeight() {
    if (!snapshotManagerFrame || !snapshotManagerFrame.contentWindow) {
      return;
    }

    try {
      snapshotManagerFrame.contentWindow.postMessage({
        type: 'zfsas:snapshot-manager:request-height'
      }, window.location.origin);
    } catch (error) {
      // Ignore postMessage errors here.
    }
  }

  function ensureSnapshotManagerEmbeddedLoaded() {
    if (!snapshotManagerFrame || snapshotManagerFrameLoaded) {
      return;
    }

    var src = snapshotManagerFrame.getAttribute('data-src') || snapshotManagerEmbeddedUrl;
    if (!src) {
      return;
    }

    snapshotManagerFrameLoaded = true;
    snapshotManagerFrame.src = src;
  }

  function snapshotManagerDatasetRowsEl() {
    return byId('snapshot_manager_dataset_rows');
  }

  function snapshotManagerSnapshotRowsEl() {
    return byId('snapshot_manager_snapshot_rows');
  }

  function setSnapshotManagerToolbarStatus(message, isError) {
    var el = byId('snapshot_manager_toolbar_status');
    if (!el) {
      return;
    }
    el.textContent = message;
    el.classList.toggle('error', !!isError);
  }

  function renderSnapshotManagerFeedback(messages, isError) {
    var el = byId('snapshot_manager_feedback');
    if (!el) {
      return;
    }

    if (!Array.isArray(messages) || messages.length === 0) {
      el.innerHTML = '';
      return;
    }

    var html = '<div class="zfsas-alert ' + (isError ? 'zfsas-alert-error' : 'zfsas-alert-warn') + '">';
    messages.forEach(function (message) {
      html += '<div>' + escapeHtml(message) + '</div>';
    });
    html += '</div>';
    el.innerHTML = html;
  }

  function snapshotManagerSelectedSnapshots() {
    return Object.keys(snapshotManagerSelection).filter(function (key) {
      return !!snapshotManagerSelection[key];
    });
  }

  function refreshSnapshotManagerBulkCount() {
    var el = byId('snapshot_manager_bulk_count');
    if (!el) {
      return;
    }

    if (!snapshotManagerCurrentDataset) {
      el.textContent = 'No dataset selected.';
      return;
    }

    var selectedCount = snapshotManagerSelectedSnapshots().length;
    var pendingRow = byId('snapshot_manager_dataset_title');
    var label = selectedCount + ' snapshot' + (selectedCount === 1 ? '' : 's') + ' selected';
    if (pendingRow && pendingRow.textContent) {
      label += ' on ' + pendingRow.textContent + '.';
    }
    el.textContent = label;
  }

  function closeSnapshotManagerDrawer() {
    var drawer = byId('snapshot_manager_drawer');
    var backdrop = byId('snapshot_manager_backdrop');
    if (drawer) {
      drawer.hidden = true;
    }
    if (backdrop) {
      backdrop.hidden = true;
    }
    snapshotManagerSelection = {};
    refreshSnapshotManagerBulkCount();
  }

  function openSnapshotManagerDrawer() {
    var drawer = byId('snapshot_manager_drawer');
    var backdrop = byId('snapshot_manager_backdrop');
    if (drawer) {
      drawer.hidden = false;
    }
    if (backdrop) {
      backdrop.hidden = false;
    }
  }

  function snapshotManagerDatasetStatusHtml(row) {
    var label = 'Idle';
    var classes = ['zfsas-sm-status-chip'];

    if (row.lastError) {
      label = row.lastError;
      classes.push('is-error');
    } else if (row.busy && row.currentAction) {
      label = row.currentAction;
      classes.push('is-busy');
    } else if (row.pendingCount > 0) {
      label = row.pendingCount + ' queued';
      classes.push('is-busy');
    } else if (row.lastMessage) {
      label = row.lastMessage;
    }

    return '<span class="' + classes.join(' ') + '">' + escapeHtml(label) + '</span>';
  }

  function renderSnapshotManagerDatasets(datasets) {
    var tbody = snapshotManagerDatasetRowsEl();
    if (!tbody) {
      return;
    }

    if (!Array.isArray(datasets) || datasets.length === 0) {
      tbody.innerHTML = '<tr><td colspan="4" class="zfsas-help">No datasets were found for Snapshot Manager.</td></tr>';
      return;
    }

    var html = '';
    datasets.forEach(function (row) {
      html += '<tr data-dataset="' + escapeHtml(row.dataset) + '">';
      html += '<td><code>' + escapeHtml(row.dataset) + '</code></td>';
      html += '<td class="zfsas-center">' + String(row.snapshotCount || 0) + '</td>';
      html += '<td>' + snapshotManagerDatasetStatusHtml(row) + '</td>';
      html += '<td><button type="button" class="btn snapshot-manager-open" data-dataset="' + escapeHtml(row.dataset) + '">Manage</button></td>';
      html += '</tr>';
    });

    tbody.innerHTML = html;
  }

  function ensureSnapshotManagerLoaded() {
    if (snapshotManagerLoaded || snapshotManagerLoading) {
      return;
    }
    loadSnapshotManagerDatasets();
  }

  function loadSnapshotManagerDatasets() {
    snapshotManagerLoading = true;
    setSnapshotManagerToolbarStatus('Loading dataset snapshot counts...', false);

    requestJson(
      snapshotManagerListUrl + '?_=' + Date.now(),
      function (data) {
        snapshotManagerLoading = false;
        snapshotManagerLoaded = true;
        renderSnapshotManagerDatasets(data.datasets || []);
        setSnapshotManagerToolbarStatus('Snapshot Manager dataset list refreshed.', false);
      },
      function (error) {
        snapshotManagerLoading = false;
        snapshotManagerLoaded = false;
        renderSnapshotManagerDatasets([]);
        setSnapshotManagerToolbarStatus('Snapshot Manager load failed: ' + error.message, true);
      }
    );
  }

  function renderSnapshotRows(dataset, snapshots, status) {
    var tbody = snapshotManagerSnapshotRowsEl();
    if (!tbody) {
      return;
    }

    if (!Array.isArray(snapshots) || snapshots.length === 0) {
      tbody.innerHTML = '<tr><td colspan="7" class="zfsas-help">No snapshots were found for this dataset.</td></tr>';
      return;
    }

    var html = '';
    snapshots.forEach(function (row) {
      var isSelected = !!snapshotManagerSelection[row.snapshot];
      var holdLabel = row.held ? 'Release' : 'Hold';
      var deleteDisabled = row.sendProtected ? ' disabled' : '';
      var rollbackDisabled = row.sendProtected ? ' disabled' : '';
      html += '<tr data-snapshot="' + escapeHtml(row.snapshot) + '">';
      html += '<td class="zfsas-select-cell"><input type="checkbox" class="snapshot-manager-select" value="' + escapeHtml(row.snapshot) + '"' + (isSelected ? ' checked' : '') + '></td>';
      html += '<td><code>' + escapeHtml(row.snapshotName) + '</code><div class="zfsas-sm-snapshot-meta">';
      if (row.sendProtected) {
        html += '<span class="zfsas-sm-meta-chip is-protected">Protected send checkpoint</span>';
      }
      if (row.held) {
        html += '<span class="zfsas-sm-meta-chip">Held: ' + escapeHtml((row.holdTags || []).join(', ') || 'yes') + '</span>';
      }
      html += '</div></td>';
      html += '<td>' + escapeHtml(row.createdText) + '</td>';
      html += '<td class="zfsas-center">' + escapeHtml(row.usedText) + '</td>';
      html += '<td class="zfsas-center">' + escapeHtml(row.writtenText) + '</td>';
      html += '<td class="zfsas-center">' + String(row.userrefs || 0) + '</td>';
      html += '<td class="zfsas-actions-cell">';
      html += '<button type="button" class="btn snapshot-manager-row-action" data-action="rollback" data-snapshot="' + escapeHtml(row.snapshot) + '"' + rollbackDisabled + '>Rollback</button>';
      html += '<button type="button" class="btn snapshot-manager-row-action" data-action="delete" data-snapshot="' + escapeHtml(row.snapshot) + '"' + deleteDisabled + '>Delete</button>';
      html += '<button type="button" class="btn snapshot-manager-row-action" data-action="' + (row.held ? 'release' : 'hold') + '" data-snapshot="' + escapeHtml(row.snapshot) + '">' + holdLabel + '</button>';
      html += '<button type="button" class="btn snapshot-manager-row-action" data-action="send" data-snapshot="' + escapeHtml(row.snapshot) + '">Send</button>';
      html += '</td>';
      html += '</tr>';
    });

    tbody.innerHTML = html;

    var titleEl = byId('snapshot_manager_dataset_title');
    if (titleEl) {
      titleEl.textContent = dataset;
    }

    var subtitleParts = ['Snapshots listed oldest to newest.'];
    if (status && status.pending_count > 0) {
      subtitleParts.push(String(status.pending_count) + ' queued operation(s).');
    } else if (status && status.current_action_label) {
      subtitleParts.push(status.current_action_label + ' is running.');
    }
    var subtitleEl = byId('snapshot_manager_dataset_subtitle');
    if (subtitleEl) {
      subtitleEl.textContent = subtitleParts.join(' ');
    }

    var selectAllEl = byId('snapshot_manager_select_all');
    if (selectAllEl) {
      selectAllEl.checked = false;
    }
  }

  function loadSnapshotManagerDataset(dataset) {
    snapshotManagerCurrentDataset = dataset;
    snapshotManagerSelection = {};
    refreshSnapshotManagerBulkCount();
    renderSnapshotManagerFeedback([], false);
    openSnapshotManagerDrawer();
    renderSnapshotRows(dataset, [], null);

    requestJson(
      snapshotManagerDatasetUrl + '?dataset=' + encodeURIComponent(dataset) + '&_=' + Date.now(),
      function (data) {
        renderSnapshotRows(dataset, data.snapshots || [], data.status || null);
        refreshSnapshotManagerBulkCount();
      },
      function (error) {
        renderSnapshotManagerFeedback(['Unable to load snapshots for ' + dataset + ': ' + error.message], true);
      }
    );
  }

  function requestSnapshotManagerAction(body, onSuccess) {
    requestJsonPost(
      snapshotManagerActionUrl,
      body,
      function (data) {
        renderSnapshotManagerFeedback([data.message || 'Snapshot manager action accepted.'], false);
        loadSnapshotManagerDatasets();
        if (snapshotManagerCurrentDataset) {
          window.setTimeout(function () {
            loadSnapshotManagerDataset(snapshotManagerCurrentDataset);
          }, 400);
        }
        if (typeof onSuccess === 'function') {
          onSuccess(data);
        }
      },
      function (error, payload) {
        if (payload && payload.error) {
          renderSnapshotManagerFeedback([payload.error], true);
        } else {
          renderSnapshotManagerFeedback([error.message], true);
        }
      }
    );
  }

  function requestTargetUrl(form) {
    var action = form ? form.getAttribute('action') : '';
    if (typeof action === 'string' && action.trim() !== '') {
      return action;
    }
    return window.location.pathname + window.location.search;
  }

  function renderSaveFeedback(errors, notices) {
    var feedbackEl = byId('save_feedback');
    if (!feedbackEl) {
      return;
    }

    var html = '';
    if (Array.isArray(errors) && errors.length > 0) {
      html += '<div class="zfsas-alert zfsas-alert-error">';
      errors.forEach(function (message) {
        html += '<div>' + escapeHtml(message) + '</div>';
      });
      html += '</div>';
    }

    feedbackEl.innerHTML = html;
  }

  function clearSaveButtonSuccessState() {
    if (!saveButton) {
      return;
    }

    if (saveSuccessTimer !== null) {
      window.clearTimeout(saveSuccessTimer);
      saveSuccessTimer = null;
    }
    saveButton.textContent = saveButtonDefaultText;
  }

  function renderCompatibilityFeedback(message) {
    var feedbackEl = byId('compat_feedback');
    if (!feedbackEl) {
      return;
    }

    if (typeof message !== 'string' || message.trim() === '') {
      feedbackEl.innerHTML = '';
      return;
    }

    feedbackEl.innerHTML =
      '<div class="zfsas-alert zfsas-alert-warn">'
      + '<div>' + escapeHtml(message) + '</div>'
      + '</div>';
  }

  function extractMarkedJson(raw) {
    var beginMarker = 'ZFSAS_JSON_BEGIN';
    var endMarker = 'ZFSAS_JSON_END';
    var start = raw.indexOf(beginMarker);
    if (start === -1) {
      return null;
    }

    var contentStart = start + beginMarker.length;
    var end = raw.indexOf(endMarker, contentStart);
    if (end === -1 || end <= contentStart) {
      return null;
    }

    return raw.slice(contentStart, end).trim();
  }

  function parsePossiblyWrappedJson(rawText) {
    var raw = String(rawText == null ? '' : rawText).trim();
    var parseError = null;

    if (raw === '') {
      throw new Error('Empty response.');
    }

    var marked = extractMarkedJson(raw);
    if (marked !== null) {
      var markedPayload = JSON.parse(marked);
      if (isExpectedJsonPayload(markedPayload)) {
        return markedPayload;
      }
      parseError = new Error('Unexpected JSON response shape.');
    }

    try {
      var directPayload = JSON.parse(raw);
      if (isExpectedJsonPayload(directPayload)) {
        return directPayload;
      }
      parseError = new Error('Unexpected JSON response shape.');
    } catch (error) {
      parseError = error;
    }

    var start = raw.indexOf('{');
    var end = raw.lastIndexOf('}');
    if (start !== -1 && end > start) {
      var candidate = raw.slice(start, end + 1);
      try {
        var payload = JSON.parse(candidate);
        if (isExpectedJsonPayload(payload)) {
          return payload;
        }
      } catch (candidateError) {
        parseError = parseError || candidateError;
      }
    }

    throw parseError || new Error('Invalid JSON response.');
  }

  function isExpectedJsonPayload(payload) {
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
      return false;
    }

    if (!Object.prototype.hasOwnProperty.call(payload, 'ok') || typeof payload.ok !== 'boolean') {
      return false;
    }

    if (Object.prototype.hasOwnProperty.call(payload, 'errors') && !Array.isArray(payload.errors)) {
      return false;
    }

    if (Object.prototype.hasOwnProperty.call(payload, 'notices') && !Array.isArray(payload.notices)) {
      return false;
    }

    return true;
  }

  function discoverCsrfToken() {
    var globalCandidates = [window.csrf_token, window.CSRF_TOKEN, window.csrfToken];
    for (var i = 0; i < globalCandidates.length; i += 1) {
      var value = globalCandidates[i];
      if (typeof value === 'string' && value.length > 0) {
        return value;
      }
    }

    var inputSelectors = [
      'input[name="csrf_token"]',
      'input[name="csrf-token"]',
      'input[name="_csrf"]'
    ];
    for (var j = 0; j < inputSelectors.length; j += 1) {
      var csrfInput = document.querySelector(inputSelectors[j]);
      if (csrfInput && typeof csrfInput.value === 'string' && csrfInput.value.length > 0) {
        return csrfInput.value;
      }
    }

    var metaSelectors = [
      'meta[name="csrf_token"]',
      'meta[name="csrf-token"]',
      'meta[name="x-csrf-token"]'
    ];
    for (var k = 0; k < metaSelectors.length; k += 1) {
      var metaTag = document.querySelector(metaSelectors[k]);
      if (metaTag) {
        var content = metaTag.getAttribute('content');
        if (typeof content === 'string' && content.length > 0) {
          return content;
        }
      }
    }

    return '';
  }

  function requestJsonFormPost(form, targetUrl, onSuccess, onError, onComplete) {
    var xhr = new XMLHttpRequest();
    var finished = false;

    function finalize() {
      if (finished) {
        return;
      }
      finished = true;
      if (typeof onComplete === 'function') {
        onComplete();
      }
    }

    xhr.open('POST', targetUrl || requestTargetUrl(form), true);
    xhr.timeout = 45000;
    xhr.setRequestHeader('Accept', 'application/json');
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');
    xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');

    var formData = new FormData(form);
    var requestParams = new URLSearchParams();
    formData.forEach(function (value, key) {
      requestParams.append(key, value);
    });
    requestParams.append('ajax', 'save');

    var csrfToken = discoverCsrfToken();

    if (csrfToken !== '') {
      xhr.setRequestHeader('X-CSRF-Token', csrfToken);
      if (!requestParams.has('csrf_token')) {
        requestParams.append('csrf_token', csrfToken);
      }
    }

    xhr.onreadystatechange = function () {
      if (xhr.readyState !== 4) {
        return;
      }

      var payload;
      try {
        payload = parsePossiblyWrappedJson(xhr.responseText);
      } catch (parseError) {
        try {
          var raw = String(xhr.responseText || '').trim();
          if (raw.charAt(0) === '<') {
            onError(new Error('Save response was wrapped by the web UI or theme. Reload the page and try again.'));
          } else {
            onError(new Error('Invalid save response.'));
          }
        } finally {
          finalize();
        }
        return;
      }

      if (xhr.status < 200 || xhr.status >= 300) {
        try {
          onError(new Error((payload && payload.errors && payload.errors[0]) ? payload.errors[0] : ('HTTP ' + xhr.status)), payload);
        } finally {
          finalize();
        }
        return;
      }

      try {
        onSuccess(payload);
      } finally {
        finalize();
      }
    };

    xhr.onerror = function () {
      try {
        onError(new Error('Network error while saving settings.'));
      } finally {
        finalize();
      }
    };

    xhr.ontimeout = function () {
      try {
        onError(new Error('Save request timed out. The settings may still be applying; reload the page and confirm.'));
      } finally {
        finalize();
      }
    };

    xhr.onabort = function () {
      try {
        onError(new Error('Save request was interrupted. Reload the page and try again.'));
      } finally {
        finalize();
      }
    };

    xhr.send(requestParams.toString());
  }

  function setSaveButtonState(isBusy) {
    saveBusy = !!isBusy;
    if (!saveButton) {
      return;
    }

    if (saveBusy) {
      clearSaveButtonSuccessState();
      saveButton.disabled = true;
      saveButton.setAttribute('disabled', 'disabled');
      saveButton.setAttribute('aria-busy', 'true');
      saveButton.textContent = 'Saving...';
      return;
    }

    saveButton.disabled = false;
    saveButton.removeAttribute('disabled');
    saveButton.setAttribute('aria-busy', 'false');
    if (saveSuccessTimer === null) {
      saveButton.textContent = saveButtonDefaultText;
    }
    saveButton.blur();
  }

  function showSaveButtonSavedState() {
    if (!saveButton) {
      return;
    }

    clearSaveButtonSuccessState();
    saveButton.textContent = 'Saved';
    saveSuccessTimer = window.setTimeout(function () {
      clearSaveButtonSuccessState();
    }, 5000);
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
      if (box.disabled) {
        box.checked = false;
        return;
      }
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

  function setLogStatus(message, isError) {
    var statusEl = byId('log_status');
    if (!statusEl) {
      return;
    }
    statusEl.textContent = message;
    statusEl.classList.toggle('error', !!isError);
  }

  function setManualRunStatus(message, isError) {
    var statusEl = byId('manual_run_status');
    if (!statusEl) {
      return;
    }

    statusEl.textContent = message;
    statusEl.classList.toggle('error', !!isError);
  }

  function currentLogViewLabel() {
    return (logView === 'debug') ? 'debug log' : 'run summary';
  }

  function refreshLogViewControls() {
    var toggleBtn = byId('log_view_toggle');
    var linesEl = byId('log_lines');

    if (toggleBtn) {
      toggleBtn.textContent = (logView === 'debug') ? 'Show Run Summary' : 'Show Debug Log';
    }

    if (linesEl) {
      linesEl.disabled = (logView === 'summary');
    }
  }

  function buildLogApiUrl(download) {
    if (download) {
      return logApiUrl + '?download=1&_=' + Date.now();
    }

    var linesEl = byId('log_lines');
    var lines = linesEl ? parseInt(linesEl.value, 10) : 400;
    if (isNaN(lines) || lines < 50) {
      lines = 400;
    }

    var url = logApiUrl
      + '?type=' + encodeURIComponent(logView)
      + '&lines=' + encodeURIComponent(lines);

    return url + '&_=' + Date.now();
  }

  function buildLogStreamUrl() {
    var linesEl = byId('log_lines');
    var lines = linesEl ? parseInt(linesEl.value, 10) : 400;
    if (isNaN(lines) || lines < 50) {
      lines = 400;
    }

    return logStreamApiUrl
      + '?type=' + encodeURIComponent(logView)
      + '&lines=' + encodeURIComponent(lines)
      + '&_=' + Date.now();
  }

  function buildLogFingerprint(data, content) {
    var head = content.slice(0, 128);
    var tail = content.slice(-128);
    return String(data.mtime || 0)
      + ':' + String(data.size || 0)
      + ':' + String(content.length)
      + ':' + head
      + ':' + tail;
  }

  function applyLogPayload(data, forceScrollToBottom) {
    var outputEl = byId('log_output');
    if (!outputEl) {
      return;
    }

    if (!data || data.ok !== true) {
      setLogStatus('Log refresh failed: Unexpected response payload.', true);
      return;
    }

    var shouldFollowTail = !!forceScrollToBottom || (outputEl.scrollTop + outputEl.clientHeight >= outputEl.scrollHeight - 40);
    var content = '';
    if (data.unsafe) {
      content = 'Selected log file path failed safety checks and was blocked.';
    } else if (!data.exists) {
      if (logView === 'debug') {
        content = 'Debug log does not exist yet. Start a run and this view will populate.';
      } else {
        content = 'Run summary is not available yet. Start a run and this view will populate.';
      }
    } else if (!data.readable) {
      content = 'Selected log file exists but is not readable by the web UI process.';
    } else if (!data.content) {
      if (logView === 'debug') {
        content = 'Debug log is currently empty.';
      } else {
        content = 'Run summary is currently empty.';
      }
    } else {
      content = data.content;
      if (data.truncated) {
        content = '[Showing the latest portion of the selected log]\n' + content;
      }
    }

    var fingerprint = buildLogFingerprint(data, content);
    if (fingerprint !== logFingerprint || forceScrollToBottom) {
      outputEl.textContent = content;
      logFingerprint = fingerprint;
    }

    if (shouldFollowTail) {
      outputEl.scrollTop = outputEl.scrollHeight;
    }

    var prefix = logPaused ? 'Paused' : 'Live';
    setLogStatus(prefix + ' ' + currentLogViewLabel() + ' | Last refresh: ' + new Date().toLocaleTimeString(), false);
  }

  function requestJson(url, onSuccess, onError) {
    var xhr = new XMLHttpRequest();
    xhr.open('GET', url, true);
    xhr.setRequestHeader('Accept', 'application/json');

    xhr.onreadystatechange = function () {
      if (xhr.readyState !== 4) {
        return;
      }

      if (xhr.status < 200 || xhr.status >= 300) {
        onError(new Error('HTTP ' + xhr.status));
        return;
      }

      var payload;
      try {
        payload = parsePossiblyWrappedJson(xhr.responseText);
      } catch (parseError) {
        var raw = String(xhr.responseText || '').trim();
        if (raw.charAt(0) === '<') {
          onError(new Error('Session expired or security token was rejected. Reload the page and try again.'));
        } else {
          onError(new Error('Invalid JSON response.'));
        }
        return;
      }

      onSuccess(payload);
    };

    xhr.onerror = function () {
      onError(new Error('Network error.'));
    };

    xhr.send();
  }

  function requestJsonPost(url, bodyParams, onSuccess, onError) {
    bodyParams = bodyParams || {};
    var xhr = new XMLHttpRequest();
    xhr.open('POST', url, true);
    xhr.timeout = 15000;
    xhr.setRequestHeader('Accept', 'application/json');
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');
    xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');

    var csrfToken = discoverCsrfToken();

    if (csrfToken !== '') {
      xhr.setRequestHeader('X-CSRF-Token', csrfToken);
    }

    xhr.onreadystatechange = function () {
      if (xhr.readyState !== 4) {
        return;
      }

      if (xhr.status < 200 || xhr.status >= 300) {
        var errorPayload = null;
        try {
          errorPayload = parsePossiblyWrappedJson(xhr.responseText);
        } catch (ignoredParseError) {
          errorPayload = null;
        }

        onError(new Error((errorPayload && errorPayload.error) ? errorPayload.error : ('HTTP ' + xhr.status)), errorPayload);
        return;
      }

      var payload;
      try {
        payload = parsePossiblyWrappedJson(xhr.responseText);
      } catch (parseError) {
        var raw = String(xhr.responseText || '').trim();
        if (raw.charAt(0) === '<') {
          onError(new Error('Session expired or security token was rejected. Reload the page and try again.'));
        } else {
          onError(new Error('Invalid JSON response.'));
        }
        return;
      }

      onSuccess(payload);
    };

    xhr.onerror = function () {
      onError(new Error('Network error.'));
    };

    xhr.ontimeout = function () {
      onError(new Error('Request timed out.'));
    };

    var requestParams = new URLSearchParams();
    Object.keys(bodyParams).forEach(function (key) {
      var value = bodyParams[key];
      if (Array.isArray(value)) {
        value.forEach(function (entry) {
          requestParams.append(key, entry);
        });
        return;
      }
      if (value !== undefined && value !== null) {
        requestParams.append(key, value);
      }
    });

    if (csrfToken !== '') {
      requestParams.append('csrf_token', csrfToken);
    }

    xhr.send(requestParams.toString());
  }

  function runSaveCompatibilityProbe() {
    requestJsonPost(
      saveApiUrl,
      {probe: '1'},
      function (data) {
        if (data && data.ok === true && data.probe === true) {
          renderCompatibilityFeedback('');
          return;
        }

        renderCompatibilityFeedback('Save endpoint compatibility probe returned an unexpected result. If saving fails on this server, another plugin or theme may be altering plugin responses.');
      },
      function (error) {
        renderCompatibilityFeedback('Save endpoint compatibility probe failed: ' + error.message + ' If saving is unreliable on this server, another plugin or theme may be altering plugin responses.');
      }
    );
  }

  function fetchLiveLog(forceScrollToBottom) {
    var outputEl = byId('log_output');
    if (!outputEl) {
      return;
    }

    setLogStatus((logPaused ? 'Paused' : 'Updating') + ' ' + currentLogViewLabel() + '...', false);

    requestJson(
      buildLogApiUrl(false),
      function (data) {
        applyLogPayload(data, forceScrollToBottom);
      },
      function (error) {
        setLogStatus('Log refresh failed: ' + error.message, true);
      }
    );
  }

  function stopLogPolling() {
    if (logTimer !== null) {
      clearInterval(logTimer);
      logTimer = null;
    }
  }

  function startLogPolling() {
    stopLogPolling();

    logTimer = setInterval(function () {
      if (logPaused) {
        return;
      }
      fetchLiveLog(false);
    }, logPollIntervalMs);
  }

  function stopLogStream() {
    if (logStreamSource) {
      logStreamSource.close();
      logStreamSource = null;
    }
  }

  function startLogStream() {
    if (typeof window.EventSource !== 'function') {
      return false;
    }

    stopLogStream();
    stopLogPolling();

    try {
      logStreamSource = new EventSource(buildLogStreamUrl());
    } catch (error) {
      logStreamSource = null;
      return false;
    }

    function handleStreamPayload(event) {
      var payload;
      try {
        payload = JSON.parse(String(event.data || ''));
      } catch (parseError) {
        return;
      }
      applyLogPayload(payload, false);
    }

    logStreamSource.addEventListener('payload', handleStreamPayload);
    logStreamSource.onmessage = handleStreamPayload;

    logStreamSource.onerror = function () {
      stopLogStream();
      setLogStatus('Live stream interrupted. Falling back to refresh mode...', true);
      startLogPolling();
      fetchLiveLog(false);
    };

    return true;
  }

  function restartLogTransport(forceScrollToBottom) {
    stopLogStream();
    stopLogPolling();

    if (logPaused) {
      setLogStatus('Paused.', false);
      return;
    }

    logFingerprint = '';
    if (!startLogStream()) {
      startLogPolling();
      fetchLiveLog(!!forceScrollToBottom);
    } else if (forceScrollToBottom) {
      fetchLiveLog(true);
    }
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
    if (box.disabled) {
      box.checked = false;
    }
    box.addEventListener('change', refreshDatasetCount);
  });

  sectionTabs.forEach(function (tab) {
    tab.addEventListener('click', function () {
      activateSection(tab.getAttribute('data-section-target') || 'main');
    });
  });

  var logToggleBtn = byId('log_toggle');
  if (logToggleBtn) {
    logToggleBtn.addEventListener('click', function () {
      logPaused = !logPaused;
      logToggleBtn.textContent = logPaused ? 'Resume Live View' : 'Pause Live View';
      if (!logPaused) {
        restartLogTransport(true);
      } else {
        stopLogStream();
        stopLogPolling();
        setLogStatus('Paused.', false);
      }
    });
  }

  var logViewToggleBtn = byId('log_view_toggle');
  if (logViewToggleBtn) {
    logViewToggleBtn.addEventListener('click', function () {
      logView = (logView === 'debug') ? 'summary' : 'debug';
      logFingerprint = '';
      refreshLogViewControls();
      restartLogTransport(true);
    });
  }

  var logRefreshBtn = byId('log_refresh');
  if (logRefreshBtn) {
    logRefreshBtn.addEventListener('click', function () {
      fetchLiveLog(true);
    });
  }

  var logDownloadBtn = byId('log_download');
  if (logDownloadBtn) {
    logDownloadBtn.addEventListener('click', function () {
      window.location.href = buildLogApiUrl(true);
    });
  }

  var logLinesSelect = byId('log_lines');
  if (logLinesSelect) {
    logLinesSelect.addEventListener('change', function () {
      restartLogTransport(true);
    });
  }

  var manualRunBtn = byId('manual_run');
  var openSendSettingsBtn = byId('open_send_settings');
  var openDatasetMigratorBtn = byId('open_dataset_migrator');
  var openRecoveryToolsBtn = byId('open_recovery_tools');
  var manualRunBusy = false;
  if (openSendSettingsBtn) {
    openSendSettingsBtn.addEventListener('click', function () {
      window.location.href = sendSettingsUrl;
    });
  }

  if (openDatasetMigratorBtn) {
    openDatasetMigratorBtn.addEventListener('click', function () {
      window.location.href = migrateDatasetsUrl;
    });
  }

  if (openRecoveryToolsBtn) {
    openRecoveryToolsBtn.addEventListener('click', function () {
      window.location.href = recoveryToolsUrl;
    });
  }

  if (snapshotManagerFrame) {
    snapshotManagerFrame.addEventListener('load', function () {
      requestSnapshotManagerEmbeddedHeight();
    });
  }

  window.addEventListener('message', function (event) {
    if (event.origin !== window.location.origin) {
      return;
    }

    var data = event.data;
    if (!data || data.type !== 'zfsas:snapshot-manager:height') {
      return;
    }

    var nextHeight = parseInt(data.height, 10);
    if (snapshotManagerFrame && !isNaN(nextHeight) && nextHeight > 0) {
      snapshotManagerFrame.style.height = Math.max(nextHeight, 980) + 'px';
    }
  });

  var snapshotManagerRefreshBtn = byId('snapshot_manager_refresh');
  if (snapshotManagerRefreshBtn) {
    snapshotManagerRefreshBtn.addEventListener('click', function () {
      loadSnapshotManagerDatasets();
    });
  }

  var snapshotManagerCloseBtn = byId('snapshot_manager_close');
  if (snapshotManagerCloseBtn) {
    snapshotManagerCloseBtn.addEventListener('click', closeSnapshotManagerDrawer);
  }

  var snapshotManagerBackdrop = byId('snapshot_manager_backdrop');
  if (snapshotManagerBackdrop) {
    snapshotManagerBackdrop.addEventListener('click', closeSnapshotManagerDrawer);
  }

  var snapshotManagerRefreshDatasetBtn = byId('snapshot_manager_refresh_dataset');
  if (snapshotManagerRefreshDatasetBtn) {
    snapshotManagerRefreshDatasetBtn.addEventListener('click', function () {
      if (!snapshotManagerCurrentDataset) {
        renderSnapshotManagerFeedback(['Choose a dataset first.'], true);
        return;
      }
      loadSnapshotManagerDataset(snapshotManagerCurrentDataset);
    });
  }

  var snapshotManagerDatasetRows = snapshotManagerDatasetRowsEl();
  if (snapshotManagerDatasetRows) {
    snapshotManagerDatasetRows.addEventListener('click', function (event) {
      var button = event.target.closest('.snapshot-manager-open');
      if (!button) {
        return;
      }

      var dataset = button.getAttribute('data-dataset') || '';
      if (!dataset) {
        return;
      }

      loadSnapshotManagerDataset(dataset);
    });
  }

  var snapshotManagerSnapshotRows = snapshotManagerSnapshotRowsEl();
  if (snapshotManagerSnapshotRows) {
    snapshotManagerSnapshotRows.addEventListener('change', function (event) {
      var checkbox = event.target.closest('.snapshot-manager-select');
      if (!checkbox) {
        return;
      }
      snapshotManagerSelection[checkbox.value] = checkbox.checked;
      refreshSnapshotManagerBulkCount();
    });

    snapshotManagerSnapshotRows.addEventListener('click', function (event) {
      var button = event.target.closest('.snapshot-manager-row-action');
      if (!button) {
        return;
      }

      var action = button.getAttribute('data-action') || '';
      var snapshot = button.getAttribute('data-snapshot') || '';
      if (!snapshotManagerCurrentDataset || !snapshot) {
        return;
      }

      if (action === 'delete') {
        if (!window.confirm('Queue deletion for snapshot ' + snapshot + '?')) {
          return;
        }
      } else if (action === 'rollback') {
        if (!window.confirm('Rollback ' + snapshotManagerCurrentDataset + ' to ' + snapshot + '? This removes newer snapshots and can discard recent changes.')) {
          return;
        }
      }

      var body = {
        action: action,
        dataset: snapshotManagerCurrentDataset,
        snapshots: [snapshot]
      };

      if (action === 'send') {
        var destination = window.prompt('Destination dataset for one-off send from ' + snapshot + ':', '');
        if (destination === null) {
          return;
        }
        destination = destination.trim();
        if (destination === '') {
          renderSnapshotManagerFeedback(['Destination dataset is required for one-off send.'], true);
          return;
        }
        body.destination = destination;
      }

      requestSnapshotManagerAction(body);
    });
  }

  var snapshotManagerSelectAll = byId('snapshot_manager_select_all');
  if (snapshotManagerSelectAll) {
    snapshotManagerSelectAll.addEventListener('change', function () {
      document.querySelectorAll('.snapshot-manager-select').forEach(function (checkbox) {
        checkbox.checked = snapshotManagerSelectAll.checked;
        snapshotManagerSelection[checkbox.value] = checkbox.checked;
      });
      refreshSnapshotManagerBulkCount();
    });
  }

  var snapshotManagerTakeSnapshotBtn = byId('snapshot_manager_take_snapshot');
  if (snapshotManagerTakeSnapshotBtn) {
    snapshotManagerTakeSnapshotBtn.addEventListener('click', function () {
      if (!snapshotManagerCurrentDataset) {
        renderSnapshotManagerFeedback(['Choose a dataset first.'], true);
        return;
      }

      var defaultName = 'manual-' + new Date().toISOString().replace(/[:T]/g, '-').slice(0, 19);
      var snapshotName = window.prompt('New snapshot name for ' + snapshotManagerCurrentDataset + ':', defaultName);
      if (snapshotName === null) {
        return;
      }
      snapshotName = snapshotName.trim();
      if (snapshotName === '') {
        renderSnapshotManagerFeedback(['Snapshot name cannot be empty.'], true);
        return;
      }

      requestSnapshotManagerAction({
        action: 'take_snapshot',
        dataset: snapshotManagerCurrentDataset,
        snapshot_name: snapshotName
      });
    });
  }

  function queueSelectedSnapshotManagerAction(action, confirmMessage) {
    if (!snapshotManagerCurrentDataset) {
      renderSnapshotManagerFeedback(['Choose a dataset first.'], true);
      return;
    }

    var snapshots = snapshotManagerSelectedSnapshots();
    if (snapshots.length === 0) {
      renderSnapshotManagerFeedback(['Select at least one snapshot first.'], true);
      return;
    }

    if (confirmMessage && !window.confirm(confirmMessage.replace('{count}', String(snapshots.length)))) {
      return;
    }

    requestSnapshotManagerAction({
      action: action,
      dataset: snapshotManagerCurrentDataset,
      snapshots: snapshots
    }, function () {
      snapshotManagerSelection = {};
      if (snapshotManagerSelectAll) {
        snapshotManagerSelectAll.checked = false;
      }
      refreshSnapshotManagerBulkCount();
    });
  }

  var snapshotManagerDeleteSelectedBtn = byId('snapshot_manager_delete_selected');
  if (snapshotManagerDeleteSelectedBtn) {
    snapshotManagerDeleteSelectedBtn.addEventListener('click', function () {
      queueSelectedSnapshotManagerAction('delete', 'Queue deletion for {count} selected snapshot(s)?');
    });
  }

  var snapshotManagerHoldSelectedBtn = byId('snapshot_manager_hold_selected');
  if (snapshotManagerHoldSelectedBtn) {
    snapshotManagerHoldSelectedBtn.addEventListener('click', function () {
      queueSelectedSnapshotManagerAction('hold', '');
    });
  }

  var snapshotManagerReleaseSelectedBtn = byId('snapshot_manager_release_selected');
  if (snapshotManagerReleaseSelectedBtn) {
    snapshotManagerReleaseSelectedBtn.addEventListener('click', function () {
      queueSelectedSnapshotManagerAction('release', '');
    });
  }

  if (manualRunBtn) {
    manualRunBtn.addEventListener('click', function () {
      if (manualRunBusy) {
        return;
      }

      manualRunBusy = true;
      manualRunBtn.disabled = true;
      setManualRunStatus('Starting manual run...', false);

      requestJsonPost(
        runApiUrl,
        {},
        function (data) {
          manualRunBusy = false;
          manualRunBtn.disabled = false;

          if (!data || data.ok !== true) {
            setManualRunStatus('Manual run start failed: Unexpected response.', true);
            return;
          }

          var message = (typeof data.message === 'string' && data.message.length > 0)
            ? data.message
            : 'Manual run started.';

          setManualRunStatus(message, false);
          logPaused = false;
          if (logToggleBtn) {
            logToggleBtn.textContent = 'Pause Live View';
          }
          restartLogTransport(true);
        },
        function (error) {
          manualRunBusy = false;
          manualRunBtn.disabled = false;
          setManualRunStatus('Manual run start failed: ' + error.message, true);
        }
      );
    });
  }

  function startSave(event) {
    if (event) {
      event.preventDefault();
      if (typeof event.stopImmediatePropagation === 'function') {
        event.stopImmediatePropagation();
      }
      if (typeof event.stopPropagation === 'function') {
        event.stopPropagation();
      }
    }

    if (!saveForm) {
      renderSaveFeedback(['Save form is unavailable. Reload the page and try again.'], []);
      return;
    }

    if (saveBusy) {
      return;
    }

    var saveFailsafeTimer = null;
    setSaveButtonState(true);
    renderSaveFeedback([], []);

    saveFailsafeTimer = window.setTimeout(function () {
      if (!saveBusy) {
        return;
      }
      setSaveButtonState(false);
      renderSaveFeedback(['Save is taking longer than expected. Reload the page and verify whether the settings were applied.'], []);
    }, 50000);

    try {
      requestJsonFormPost(
        saveForm,
        saveForm.getAttribute('data-ajax-action') || requestTargetUrl(saveForm),
        function (data) {
          var notices = Array.isArray(data.notices) ? data.notices : [];
          renderSaveFeedback(data.errors || [], []);
          if (!Array.isArray(data.errors) || data.errors.length === 0) {
            showSaveButtonSavedState();
          } else {
            clearSaveButtonSuccessState();
          }

          var cronValueEl = byId('resolved_cron_value');
          if (cronValueEl && typeof data.resolvedCron === 'string') {
            cronValueEl.textContent = data.resolvedCron;
          }

          var prefixPreviewEl = byId('prefix_preview');
          var prefixInputEl = byId('prefix');
          if (prefixPreviewEl) {
            prefixPreviewEl.textContent = (typeof data.prefix === 'string' && data.prefix.length > 0)
              ? data.prefix
              : (prefixInputEl ? prefixInputEl.value : '');
          }
        },
        function (error, payload) {
          if (payload && Array.isArray(payload.errors)) {
            renderSaveFeedback(payload.errors, payload.notices || []);
          } else {
            renderSaveFeedback([error.message], []);
          }
          clearSaveButtonSuccessState();
        },
        function () {
          if (saveFailsafeTimer !== null) {
            window.clearTimeout(saveFailsafeTimer);
          }
          setSaveButtonState(false);
        }
      );
    } catch (error) {
      if (saveFailsafeTimer !== null) {
        window.clearTimeout(saveFailsafeTimer);
      }
      setSaveButtonState(false);
      clearSaveButtonSuccessState();
      renderSaveFeedback(['Save request could not be started: ' + String(error && error.message ? error.message : error)], []);
    }
  }

  if (saveButton) {
    saveButton.addEventListener('click', startSave, true);
  }

  if (saveForm) {
    saveForm.addEventListener('submit', startSave, true);
  }

  if (saveButton && saveButton.getAttribute('data-show-saved') === '1') {
    showSaveButtonSavedState();
    saveButton.removeAttribute('data-show-saved');
  }

  activateSection(initialSection);
  applyPoolFilter();
  refreshScheduleUI();
  refreshDatasetCount();
  refreshLogViewControls();
  runSaveCompatibilityProbe();

  if (byId('log_output')) {
    restartLogTransport(true);
  }

  window.addEventListener('beforeunload', function () {
    stopLogStream();
    stopLogPolling();
  });
})();
</script>
<?php if ($renderStandalonePage) : ?>
</body>
</html>
<?php endif; ?>
