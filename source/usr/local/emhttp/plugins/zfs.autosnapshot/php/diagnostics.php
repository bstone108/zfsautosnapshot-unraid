<?php
$pluginName = 'zfs.autosnapshot';
$downloadName = 'zfs_autosnapshot_diagnostics.zip';
$configDir = "/boot/config/plugins/{$pluginName}";
$tempRoot = sys_get_temp_dir() . '/' . $pluginName . '-diagnostics-' . bin2hex(random_bytes(6));

function zfsas_diagnostics_send_error($message, $statusCode = 500)
{
    if (!headers_sent()) {
        http_response_code((int) $statusCode);
        header('Content-Type: text/plain; charset=UTF-8');
        header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
        header('Pragma: no-cache');
        header('X-Content-Type-Options: nosniff');
    }

    echo $message . "\n";
    exit;
}

function zfsas_diagnostics_rrmdir($path)
{
    if (!is_dir($path)) {
        return;
    }

    $items = scandir($path);
    if (!is_array($items)) {
        return;
    }

    foreach ($items as $item) {
        if ($item === '.' || $item === '..') {
            continue;
        }

        $child = $path . '/' . $item;
        if (is_dir($child) && !is_link($child)) {
            zfsas_diagnostics_rrmdir($child);
        } else {
            @unlink($child);
        }
    }

    @rmdir($path);
}

function zfsas_diagnostics_redact($text)
{
    $text = (string) $text;
    $patterns = [
        '/^.*\bsshd(?:-session)?\b.*\bAccepted\s+(?:password|keyboard-interactive\/pam|publickey)\b.*$/mi' => '[REDACTED_SSH_LOGIN]',
        '/^([A-Z][a-z]{2}\s+\d+\s+\d{2}:\d{2}:\d{2})\s+\S+/' => '$1 [REDACTED_HOST]',
        '/\b(PASSWORD|PASS|API_KEY|APIKEY|TOKEN|SECRET|ACCESS_KEY|PRIVATE_KEY|WEBHOOK|AUTH|BEARER)\b\s*=\s*"[^"]*"/i' => '$1="[REDACTED]"',
        '/\b(PASSWORD|PASS|API_KEY|APIKEY|TOKEN|SECRET|ACCESS_KEY|PRIVATE_KEY|WEBHOOK|AUTH|BEARER)\b\s*=\s*\'[^\']*\'/i' => '$1=\'[REDACTED]\'',
        '/\b(PASSWORD|PASS|API_KEY|APIKEY|TOKEN|SECRET|ACCESS_KEY|PRIVATE_KEY|WEBHOOK|AUTH|BEARER)\b\s*=\s*[^\s#;]+/i' => '$1=[REDACTED]',
        '/\b(Authorization:\s*(?:Bearer|Basic)\s+)[A-Za-z0-9._~+\/=:-]+/i' => '$1[REDACTED]',
        '/\b(Bearer\s+)[A-Za-z0-9._~+\/=:-]+/i' => '$1[REDACTED]',
        '/\b([A-Za-z0-9._%+\-]+)@([A-Za-z0-9.\-]+\.[A-Za-z]{2,})\b/' => '[REDACTED_EMAIL]@$2',
        '/\b(?:[A-Za-z0-9-]+\.)*[A-Za-z0-9-]+\.ts\.net\b/i' => '[REDACTED_HOST]',
        '/\b(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}\b/' => '[REDACTED_IP]',
        '/\b(?:[0-9a-f]{64}|[0-9a-f]{12,64})(?=\/merged|\b)/i' => '[REDACTED_DOCKER_ID]',
        '#/(?:mnt|boot|var|usr/local)/(?:cache|zfs|disk[0-9]+|user|user0|docker|plugins)[A-Za-z0-9_./@:-]*#' => '/[REDACTED_PATH]',
        '#\b(?:cache|zfs)/[A-Za-z0-9_./@:-]+#' => '[REDACTED_ZFS_PATH]',
    ];

    foreach ($patterns as $pattern => $replacement) {
        $redacted = preg_replace($pattern, $replacement, $text);
        if (is_string($redacted)) {
            $text = $redacted;
        }
    }

    return $text;
}

function zfsas_diagnostics_safe_source_path($path)
{
    if (!is_string($path) || $path === '' || is_link($path)) {
        return false;
    }

    if (!file_exists($path)) {
        return true;
    }

    if (!is_file($path)) {
        return false;
    }

    $real = realpath($path);
    if ($real === false) {
        return false;
    }

    $allowedExactPaths = [
        '/boot/config/plugins/zfs.autosnapshot.plg',
        '/var/log/plugins/zfs.autosnapshot.plg',
    ];
    if (in_array($real, $allowedExactPaths, true)) {
        return true;
    }

    $allowedRoots = [
        '/var/log',
        '/var/log/plugins',
        '/boot/config/plugins/zfs.autosnapshot',
        '/usr/local/emhttp/plugins/zfs.autosnapshot',
    ];

    foreach ($allowedRoots as $root) {
        if ($real === $root || strpos($real, $root . '/') === 0) {
            return true;
        }
    }

    return false;
}

function zfsas_diagnostics_write_file($baseDir, $relativePath, $content)
{
    $relativePath = trim((string) $relativePath, '/');
    if ($relativePath === '' || strpos($relativePath, '..') !== false) {
        return false;
    }

    $target = $baseDir . '/' . $relativePath;
    $dir = dirname($target);
    if (!is_dir($dir) && !mkdir($dir, 0700, true)) {
        return false;
    }

    return file_put_contents($target, zfsas_diagnostics_redact((string) $content)) !== false;
}

function zfsas_diagnostics_copy_text_file($baseDir, $relativePath, $sourcePath, $maxBytes = 1048576)
{
    if (!zfsas_diagnostics_safe_source_path($sourcePath)) {
        return zfsas_diagnostics_write_file($baseDir, $relativePath, "Source failed diagnostics safety checks: {$sourcePath}\n");
    }

    if (!is_file($sourcePath)) {
        return zfsas_diagnostics_write_file($baseDir, $relativePath, "File not present: {$sourcePath}\n");
    }

    if (!is_readable($sourcePath)) {
        return zfsas_diagnostics_write_file($baseDir, $relativePath, "File exists but is not readable: {$sourcePath}\n");
    }

    $maxBytes = max(4096, (int) $maxBytes);
    $size = (int) @filesize($sourcePath);
    $content = @file_get_contents($sourcePath, false, null, max(0, $size - $maxBytes), $maxBytes);
    if (!is_string($content)) {
        $content = "Unable to read file: {$sourcePath}\n";
    }

    if ($size > $maxBytes) {
        $content = "[truncated to last {$maxBytes} bytes from {$sourcePath}]\n" . $content;
    }

    return zfsas_diagnostics_write_file($baseDir, $relativePath, $content);
}

function zfsas_diagnostics_run_command($baseDir, $relativePath, $command)
{
    $output = [];
    $exitCode = 0;
    @exec($command . ' 2>&1', $output, $exitCode);
    $content = '$ ' . $command . "\n";
    $content .= implode("\n", $output);
    if ($content !== '' && substr($content, -1) !== "\n") {
        $content .= "\n";
    }
    $content .= "Exit code: {$exitCode}\n";

    return zfsas_diagnostics_write_file($baseDir, $relativePath, $content);
}

function zfsas_diagnostics_capture_command($command)
{
    $output = [];
    $exitCode = 0;
    @exec($command . ' 2>&1', $output, $exitCode);
    return [$output, $exitCode];
}

function zfsas_diagnostics_parse_size_bytes($value)
{
    $value = trim((string) $value);
    if ($value === '-' || $value === '') {
        return null;
    }
    if (!preg_match('/^([0-9]+(?:\.[0-9]+)?)([KMGTPE]?)(?:i?B?)?$/i', $value, $match)) {
        return null;
    }
    $units = ['' => 1, 'K' => 1024, 'M' => 1048576, 'G' => 1073741824, 'T' => 1099511627776, 'P' => 1125899906842624, 'E' => 1152921504606846976];
    $unit = strtoupper($match[2]);
    return (int) round((float) $match[1] * ($units[$unit] ?? 1));
}

function zfsas_diagnostics_count_values($values)
{
    $counts = [];
    foreach ($values as $value) {
        $key = (string) $value;
        if (!isset($counts[$key])) {
            $counts[$key] = 0;
        }
        $counts[$key]++;
    }
    ksort($counts, SORT_NATURAL);
    return $counts;
}

function zfsas_diagnostics_write_zfs_summary($baseDir)
{
    [$datasetLines, $datasetExit] = zfsas_diagnostics_capture_command('command -v zfs >/dev/null 2>&1 && zfs list -H -o name,type,used,avail,refer,mountpoint || true');
    [$snapshotLines, $snapshotExit] = zfsas_diagnostics_capture_command('command -v zfs >/dev/null 2>&1 && zfs list -H -t snapshot -o name,creation,used,refer -s creation || true');

    $datasetCount = 0;
    $poolNames = [];
    $datasetTypes = [];
    foreach ($datasetLines as $line) {
        $parts = explode("\t", $line);
        if (count($parts) < 2 || $parts[0] === '') {
            continue;
        }
        $datasetCount++;
        $pool = explode('/', $parts[0], 2)[0];
        $poolNames[$pool] = true;
        $datasetTypes[] = $parts[1];
    }

    $snapshotCount = 0;
    $snapshotsByPool = [];
    $snapshotsByDataset = [];
    $snapshotsByPrefix = [];
    $usedBytesTotal = 0;
    foreach ($snapshotLines as $line) {
        $parts = explode("\t", $line);
        if (count($parts) < 1 || strpos($parts[0], '@') === false) {
            continue;
        }
        [$dataset, $snapshot] = explode('@', $parts[0], 2);
        $snapshotCount++;
        $pool = explode('/', $dataset, 2)[0];
        if (!isset($poolNames[$pool])) {
            $poolNames[$pool] = true;
        }
        $poolIndex = array_search($pool, array_keys($poolNames), true);
        $poolAlias = 'pool-' . ($poolIndex + 1);
        $snapshotsByPool[$poolAlias] = ($snapshotsByPool[$poolAlias] ?? 0) + 1;
        $snapshotsByDataset[$dataset] = ($snapshotsByDataset[$dataset] ?? 0) + 1;
        $prefix = 'other';
        if (strpos($snapshot, 'autosnapshot-') === 0) {
            $prefix = 'autosnapshot';
        } elseif (strpos($snapshot, 'zfs-send-') === 0) {
            $prefix = 'zfs-send';
        }
        $snapshotsByPrefix[$prefix] = ($snapshotsByPrefix[$prefix] ?? 0) + 1;
        if (isset($parts[2])) {
            $bytes = zfsas_diagnostics_parse_size_bytes($parts[2]);
            if ($bytes !== null) {
                $usedBytesTotal += $bytes;
            }
        }
    }
    ksort($snapshotsByPool, SORT_NATURAL);
    ksort($snapshotsByPrefix, SORT_NATURAL);
    $maxSnapshots = 0;
    foreach ($snapshotsByDataset as $count) {
        $maxSnapshots = max($maxSnapshots, $count);
    }

    $content = "ZFS summary (public-safe, names omitted)\n";
    $content .= "Dataset command exit: {$datasetExit}\n";
    $content .= "Snapshot command exit: {$snapshotExit}\n";
    $content .= "Pools with datasets: " . count($poolNames) . "\n";
    $content .= "Datasets total: {$datasetCount}\n";
    $content .= "Dataset types: " . json_encode(zfsas_diagnostics_count_values($datasetTypes)) . "\n";
    $content .= "Snapshots total: {$snapshotCount}\n";
    $content .= "Snapshots by anonymized pool: " . json_encode($snapshotsByPool) . "\n";
    $content .= "Snapshots by prefix: " . json_encode($snapshotsByPrefix) . "\n";
    $content .= "Datasets with snapshots: " . count($snapshotsByDataset) . "\n";
    $content .= "Max snapshots on one dataset: {$maxSnapshots}\n";
    $content .= "Approx snapshot USED total bytes: {$usedBytesTotal}\n";
    return zfsas_diagnostics_write_file($baseDir, 'commands/zfs-summary.txt', $content);
}

function zfsas_diagnostics_write_send_summary($baseDir)
{
    [$snapshotLines, $snapshotExit] = zfsas_diagnostics_capture_command('command -v zfs >/dev/null 2>&1 && zfs list -H -t snapshot -o name -s creation || true');
    $sendByDataset = [];
    foreach ($snapshotLines as $line) {
        if (strpos($line, '@zfs-send-') === false) {
            continue;
        }
        [$dataset, $snapshot] = explode('@', $line, 2);
        $sendByDataset[$dataset] = ($sendByDataset[$dataset] ?? 0) + 1;
    }
    $distribution = [];
    $max = 0;
    $totalSendCheckpoints = 0;
    foreach ($sendByDataset as $count) {
        $max = max($max, $count);
        $totalSendCheckpoints += $count;
        $distribution[(string) $count] = ($distribution[(string) $count] ?? 0) + 1;
    }
    ksort($distribution, SORT_NATURAL);
    $content = "ZFS send checkpoint summary (public-safe, names omitted)\n";
    $content .= "Snapshot command exit: {$snapshotExit}\n";
    $content .= "Send checkpoints total: {$totalSendCheckpoints}\n";
    $content .= "Datasets with send checkpoints: " . count($sendByDataset) . "\n";
    $content .= "Max send checkpoints on one dataset: {$max}\n";
    $content .= "Send checkpoints per dataset distribution: " . json_encode($distribution) . "\n";
    return zfsas_diagnostics_write_file($baseDir, 'commands/send-summary.txt', $content);
}

function zfsas_diagnostics_write_config_summary($baseDir, $autoConfigPath, $sendConfigPath)
{
    $content = "Configuration summary (public-safe, dataset names omitted)\n";
    $auto = is_readable($autoConfigPath) ? (string) @file_get_contents($autoConfigPath) : '';
    $send = is_readable($sendConfigPath) ? (string) @file_get_contents($sendConfigPath) : '';
    if ($auto !== '') {
        foreach (['PREFIX', 'DRY_RUN', 'KEEP_ALL_FOR_DAYS', 'KEEP_DAILY_UNTIL_DAYS', 'KEEP_WEEKLY_UNTIL_DAYS', 'SCHEDULE_MODE', 'SCHEDULE_EVERY_MINUTES', 'SCHEDULE_EVERY_HOURS', 'SCHEDULE_DAILY_HOUR', 'SCHEDULE_DAILY_MINUTE', 'CRON_SCHEDULE'] as $key) {
            if (preg_match('/^' . preg_quote($key, '/') . '=([^\n]*)/m', $auto, $match)) {
                $content .= "Auto {$key}: " . trim($match[1], " \t\"'") . "\n";
            }
        }
        if (preg_match('/^DATASETS="(.*)"/m', $auto, $match)) {
            $content .= "Configured autosnapshot datasets: " . substr_count($match[1], ':') . "\n";
        }
    } else {
        $content .= "Autosnapshot config: missing or unreadable\n";
    }
    if ($send !== '') {
        foreach (['SEND_SNAPSHOT_PREFIX', 'SEND_MAX_PARALLEL', 'SEND_PREP_EXTRA_WORKERS', 'SEND_KEEP_ALL_FOR_DAYS', 'SEND_KEEP_DAILY_UNTIL_DAYS', 'SEND_KEEP_WEEKLY_UNTIL_DAYS'] as $key) {
            if (preg_match('/^' . preg_quote($key, '/') . '=([^\n]*)/m', $send, $match)) {
                $content .= "Send {$key}: " . trim($match[1], " \t\"'") . "\n";
            }
        }
        if (preg_match('/^SEND_JOBS="(.*)"/m', $send, $match)) {
            $content .= "Configured send jobs: " . ($match[1] === '' ? 0 : count(explode(';', $match[1]))) . "\n";
        }
    } else {
        $content .= "Send config: missing or unreadable\n";
    }
    return zfsas_diagnostics_write_file($baseDir, 'config/config-summary.txt', $content);
}

function zfsas_diagnostics_write_log_summary($baseDir, $relativePath, $sourcePath, $maxBytes = 1048576)
{
    if (!is_file($sourcePath) || !is_readable($sourcePath)) {
        return zfsas_diagnostics_write_file($baseDir, $relativePath, "Log not present or not readable: {$sourcePath}\n");
    }
    $size = (int) @filesize($sourcePath);
    $text = @file_get_contents($sourcePath, false, null, max(0, $size - $maxBytes), $maxBytes);
    if (!is_string($text)) {
        $text = '';
    }
    $lines = preg_split('/\R/', $text) ?: [];
    $notable = [];
    $patterns = [
        'error' => '/\berror\b/i',
        'warning' => '/\bwarn(?:ing)?\b/i',
        'failed' => '/\bfailed\b/i',
        'cannot' => '/\bcannot\b/i',
        'command_not_found' => '/command not found/i',
        'permission_denied' => '/permission denied/i',
        'traceback' => '/traceback/i',
        'testing_debug_marker' => '/TESTING_DEBUG_MARKER/',
    ];
    $counts = array_fill_keys(array_keys($patterns), 0);
    foreach ($lines as $line) {
        foreach ($patterns as $key => $pattern) {
            if (preg_match($pattern, $line)) {
                $counts[$key]++;
                if ($key !== 'testing_debug_marker') {
                    $notable[] = $line;
                }
            }
        }
    }
    $notable = array_slice($notable, -80);
    $content = "Log summary for {$sourcePath}\n";
    $content .= "Original bytes: {$size}\n";
    $content .= "Bytes scanned from tail: " . strlen($text) . "\n";
    $content .= "Lines scanned: " . count($lines) . "\n";
    foreach ($counts as $key => $count) {
        $content .= "{$key}: {$count}\n";
    }
    $content .= "Recent notable lines (redacted):\n";
    foreach ($notable as $line) {
        $content .= zfsas_diagnostics_redact($line) . "\n";
    }
    return zfsas_diagnostics_write_file($baseDir, $relativePath, $content);
}

function zfsas_diagnostics_write_directory_summary($baseDir, $relativePath, $sourceDir)
{
    $content = "Directory summary for {$sourceDir}\n";
    if (!is_dir($sourceDir) || is_link($sourceDir)) {
        return zfsas_diagnostics_write_file($baseDir, $relativePath, $content . "Status: not present\n");
    }
    $items = scandir($sourceDir);
    if (!is_array($items)) {
        return zfsas_diagnostics_write_file($baseDir, $relativePath, $content . "Status: not readable\n");
    }
    $files = 0;
    $bytes = 0;
    foreach ($items as $item) {
        if ($item === '.' || $item === '..') {
            continue;
        }
        $path = $sourceDir . '/' . $item;
        if (is_file($path) && !is_link($path)) {
            $files++;
            $bytes += (int) @filesize($path);
        }
    }
    $content .= "Files: {$files}\nBytes: {$bytes}\n";
    return zfsas_diagnostics_write_file($baseDir, $relativePath, $content);
}

function zfsas_diagnostics_add_directory_files($baseDir, $targetDir, $sourceDir, $maxBytes = 524288)
{
    if (!is_dir($sourceDir) || is_link($sourceDir)) {
        zfsas_diagnostics_write_file($baseDir, $targetDir . '/README.txt', "Directory not present: {$sourceDir}\n");
        return;
    }

    $items = scandir($sourceDir);
    if (!is_array($items)) {
        zfsas_diagnostics_write_file($baseDir, $targetDir . '/README.txt', "Directory is not readable: {$sourceDir}\n");
        return;
    }

    foreach ($items as $item) {
        if ($item === '.' || $item === '..') {
            continue;
        }
        $path = $sourceDir . '/' . $item;
        if (is_file($path) && !is_link($path)) {
            zfsas_diagnostics_copy_text_file($baseDir, $targetDir . '/' . preg_replace('/[^A-Za-z0-9_.-]+/', '_', $item), $path, $maxBytes);
        }
    }
}

function zfsas_diagnostics_zip_dir($zip, $baseDir, $dir)
{
    $items = scandir($dir);
    if (!is_array($items)) {
        return;
    }

    foreach ($items as $item) {
        if ($item === '.' || $item === '..') {
            continue;
        }
        $path = $dir . '/' . $item;
        $localName = ltrim(substr($path, strlen($baseDir)), '/');
        if (is_dir($path)) {
            $zip->addEmptyDir($localName);
            zfsas_diagnostics_zip_dir($zip, $baseDir, $path);
        } elseif (is_file($path)) {
            $zip->addFile($path, $localName);
        }
    }
}

function zfsas_diagnostics_create_zip_archive($zipPath, $payloadDir)
{
    if (class_exists('ZipArchive')) {
        $zip = new ZipArchive();
        if ($zip->open($zipPath, ZipArchive::CREATE | ZipArchive::OVERWRITE) !== true) {
            return false;
        }
        zfsas_diagnostics_zip_dir($zip, $payloadDir, $payloadDir);
        $zip->close();
        return is_file($zipPath);
    }

    $zipBinary = trim((string) @shell_exec('command -v zip 2>/dev/null'));
    if ($zipBinary === '' || !is_executable($zipBinary)) {
        return false;
    }

    $previousCwd = getcwd();
    if (!chdir($payloadDir)) {
        return false;
    }

    $output = [];
    $exitCode = 0;
    @exec(escapeshellarg($zipBinary) . ' -qr ' . escapeshellarg($zipPath) . ' . 2>&1', $output, $exitCode);
    if (is_string($previousCwd) && $previousCwd !== '') {
        @chdir($previousCwd);
    }

    return $exitCode === 0 && is_file($zipPath);
}

if (!mkdir($tempRoot, 0700, true)) {
    zfsas_diagnostics_send_error('Unable to create diagnostics workspace.', 500);
}

$zipPath = $tempRoot . '/zfs_autosnapshot_diagnostics.zip';
$payloadDir = $tempRoot . '/payload';
if (!mkdir($payloadDir, 0700, true)) {
    zfsas_diagnostics_rrmdir($tempRoot);
    zfsas_diagnostics_send_error('Unable to create diagnostics payload workspace.', 500);
}

zfsas_diagnostics_write_file($payloadDir, 'README.txt', "ZFS Auto Snapshot diagnostics export\nGenerated: " . gmdate('Y-m-d H:i:s') . " UTC\nSecrets and public topology details are redacted or summarized before packaging.\nAttach this zip to a GitHub issue when reporting plugin problems.\n");
zfsas_diagnostics_write_file($payloadDir, 'metadata/environment.txt', "Generated UTC: " . gmdate('Y-m-d H:i:s') . "\nPHP: " . PHP_VERSION . "\nSAPI: " . PHP_SAPI . "\nPlugin: zfs.autosnapshot\n");

$files = [
    'logs/zfs_autosnapshot.last.log' => '/var/log/zfs_autosnapshot.last.log',
    'config/plugin_manifest.plg' => '/boot/config/plugins/zfs.autosnapshot.plg',
    'installed/plugin_manifest.plg' => '/var/log/plugins/zfs.autosnapshot.plg',
];

foreach ($files as $relativePath => $sourcePath) {
    zfsas_diagnostics_copy_text_file($payloadDir, $relativePath, $sourcePath, 262144);
}

zfsas_diagnostics_write_config_summary($payloadDir, '/boot/config/plugins/zfs.autosnapshot/zfs_autosnapshot.conf', '/boot/config/plugins/zfs.autosnapshot/zfs_send.conf');
zfsas_diagnostics_write_log_summary($payloadDir, 'logs/zfs_autosnapshot.summary.txt', '/var/log/zfs_autosnapshot.log');
zfsas_diagnostics_write_log_summary($payloadDir, 'logs/zfs_autosnapshot.archive.summary.txt', '/var/log/zfs_autosnapshot.archive.log');
zfsas_diagnostics_write_log_summary($payloadDir, 'logs/zfs_autosnapshot_send.summary.txt', '/var/log/zfs_autosnapshot_send.log');
zfsas_diagnostics_write_log_summary($payloadDir, 'logs/zfs_autosnapshot_send.archive.summary.txt', '/var/log/zfs_autosnapshot_send.archive.log');
zfsas_diagnostics_write_log_summary($payloadDir, 'logs/syslog.summary.txt', '/var/log/syslog');
zfsas_diagnostics_write_directory_summary($payloadDir, 'state/queue-summary.txt', $configDir . '/queue');
zfsas_diagnostics_write_directory_summary($payloadDir, 'state/failed-send-logs-summary.txt', $configDir . '/failed-send-logs');
zfsas_diagnostics_write_zfs_summary($payloadDir);
zfsas_diagnostics_write_send_summary($payloadDir);

$commands = [
    'commands/uname.txt' => 'uname -a',
    'commands/unraid-version.txt' => 'test -r /etc/unraid-version && cat /etc/unraid-version || true',
    'commands/zfs-version.txt' => 'command -v zfs >/dev/null 2>&1 && zfs version || true',
    'commands/zpool-status.txt' => 'command -v zpool >/dev/null 2>&1 && zpool status -x || true',
    'commands/plugin-package.txt' => 'ls -1 /var/log/packages/zfs-autosnapshot-* 2>/dev/null || true',
];

foreach ($commands as $relativePath => $command) {
    zfsas_diagnostics_run_command($payloadDir, $relativePath, $command);
}

if (!zfsas_diagnostics_create_zip_archive($zipPath, $payloadDir)) {
    zfsas_diagnostics_rrmdir($tempRoot);
    zfsas_diagnostics_send_error('Unable to create diagnostics zip archive. Install the PHP ZipArchive extension or the zip command.', 500);
}

if (!is_file($zipPath)) {
    zfsas_diagnostics_rrmdir($tempRoot);
    zfsas_diagnostics_send_error('Diagnostics zip archive was not created.', 500);
}

if (!headers_sent()) {
    header('Content-Type: application/zip');
    header('Content-Disposition: attachment; filename="' . $downloadName . '"');
    header('Content-Length: ' . (string) filesize($zipPath));
    header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
    header('Pragma: no-cache');
    header('X-Content-Type-Options: nosniff');
}

readfile($zipPath);
zfsas_diagnostics_rrmdir($tempRoot);
exit;
