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
        '/\b(PASSWORD|PASS|API_KEY|APIKEY|TOKEN|SECRET|ACCESS_KEY|PRIVATE_KEY|WEBHOOK|AUTH|BEARER)\b\s*=\s*"[^"]*"/i' => '$1="[REDACTED]"',
        '/\b(PASSWORD|PASS|API_KEY|APIKEY|TOKEN|SECRET|ACCESS_KEY|PRIVATE_KEY|WEBHOOK|AUTH|BEARER)\b\s*=\s*\'[^\']*\'/i' => '$1=\'[REDACTED]\'',
        '/\b(PASSWORD|PASS|API_KEY|APIKEY|TOKEN|SECRET|ACCESS_KEY|PRIVATE_KEY|WEBHOOK|AUTH|BEARER)\b\s*=\s*[^\s#;]+/i' => '$1=[REDACTED]',
        '/\b(Authorization:\s*(?:Bearer|Basic)\s+)[A-Za-z0-9._~+\/=:-]+/i' => '$1[REDACTED]',
        '/\b(Bearer\s+)[A-Za-z0-9._~+\/=:-]+/i' => '$1[REDACTED]',
        '/\b([A-Za-z0-9._%+\-]+)@([A-Za-z0-9.\-]+\.[A-Za-z]{2,})\b/' => '[REDACTED_EMAIL]@$2',
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

zfsas_diagnostics_write_file($payloadDir, 'README.txt', "ZFS Auto Snapshot diagnostics export\nGenerated: " . gmdate('Y-m-d H:i:s') . " UTC\nSecrets matching PASSWORD/API_KEY/TOKEN/SECRET style keys are redacted as [REDACTED].\nAttach this zip to a GitHub issue when reporting plugin problems.\n");
zfsas_diagnostics_write_file($payloadDir, 'metadata/environment.txt', "Generated UTC: " . gmdate('Y-m-d H:i:s') . "\nPHP: " . PHP_VERSION . "\nSAPI: " . PHP_SAPI . "\nPlugin: zfs.autosnapshot\n");

$files = [
    'logs/zfs_autosnapshot.log' => '/var/log/zfs_autosnapshot.log',
    'logs/zfs_autosnapshot.archive.log' => '/var/log/zfs_autosnapshot.archive.log',
    'logs/zfs_autosnapshot.last.log' => '/var/log/zfs_autosnapshot.last.log',
    'logs/zfs_autosnapshot_send.log' => '/var/log/zfs_autosnapshot_send.log',
    'logs/zfs_autosnapshot_send.archive.log' => '/var/log/zfs_autosnapshot_send.archive.log',
    'logs/syslog.tail' => '/var/log/syslog',
    'config/zfs_autosnapshot.conf' => '/boot/config/plugins/zfs.autosnapshot/zfs_autosnapshot.conf',
    'config/zfs_send.conf' => '/boot/config/plugins/zfs.autosnapshot/zfs_send.conf',
    'config/plugin_manifest.plg' => '/boot/config/plugins/zfs.autosnapshot.plg',
    'installed/plugin_manifest.plg' => '/var/log/plugins/zfs.autosnapshot.plg',
];

foreach ($files as $relativePath => $sourcePath) {
    zfsas_diagnostics_copy_text_file($payloadDir, $relativePath, $sourcePath, 1048576);
}

zfsas_diagnostics_add_directory_files($payloadDir, 'state/queue', $configDir . '/queue', 524288);
zfsas_diagnostics_add_directory_files($payloadDir, 'state/failed-send-logs', $configDir . '/failed-send-logs', 524288);

$commands = [
    'commands/uname.txt' => 'uname -a',
    'commands/unraid-version.txt' => 'test -r /etc/unraid-version && cat /etc/unraid-version || true',
    'commands/zfs-version.txt' => 'command -v zfs >/dev/null 2>&1 && zfs version || true',
    'commands/zpool-status.txt' => 'command -v zpool >/dev/null 2>&1 && zpool status || true',
    'commands/zpool-list.txt' => 'command -v zpool >/dev/null 2>&1 && zpool list -v || true',
    'commands/zfs-list-datasets.txt' => 'command -v zfs >/dev/null 2>&1 && zfs list -H -o name,type,used,avail,refer,mountpoint || true',
    'commands/zfs-list-snapshots.txt' => 'command -v zfs >/dev/null 2>&1 && zfs list -H -t snapshot -o name,creation,used,refer -s creation || true',
    'commands/df.txt' => 'df -hT || true',
    'commands/mount.txt' => 'mount || true',
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
