<?php
require_once __DIR__ . '/response-helpers.php';
require_once __DIR__ . '/send-queue-helpers.php';

function zfsas_send_log_download_safe_path($path)
{
    $allowedRoot = '/var/log';
    $failedLogsRoot = zfsas_ops_failed_send_logs_dir();

    if (!is_string($path) || $path === '') {
        return false;
    }

    if (is_link($path)) {
        return false;
    }

    if (file_exists($path) && !is_file($path)) {
        return false;
    }

    $dirReal = realpath(dirname($path));
    if ($dirReal === false) {
        return false;
    }

    $allowedRoots = [$allowedRoot];
    $allowedRootReal = realpath($allowedRoot);
    if ($allowedRootReal !== false) {
        $allowedRoots[] = $allowedRootReal;
    }
    $allowedRoots[] = $failedLogsRoot;
    $failedLogsReal = realpath($failedLogsRoot);
    if ($failedLogsReal !== false) {
        $allowedRoots[] = $failedLogsReal;
    }
    $allowedRoots = array_values(array_unique($allowedRoots));

    $allowed = false;
    foreach ($allowedRoots as $root) {
        if ($dirReal === $root || strpos($dirReal, $root . DIRECTORY_SEPARATOR) === 0) {
            $allowed = true;
            break;
        }
    }

    if (!$allowed) {
        return false;
    }

    $real = realpath($path);
    if ($real !== false) {
        $allowed = false;
        foreach ($allowedRoots as $root) {
            if ($real === $root || strpos($real, $root . DIRECTORY_SEPARATOR) === 0) {
                $allowed = true;
                break;
            }
        }
        if (!$allowed) {
            return false;
        }
    }

    return true;
}

function zfsas_send_log_stream_text($path)
{
    if (!zfsas_send_log_download_safe_path($path)) {
        echo "Requested send log path failed safety checks.\n";
        return;
    }

    if (!is_file($path)) {
        echo "Requested send log file is not present.\n";
        return;
    }

    if (!is_readable($path)) {
        echo "Requested send log file exists but is not readable.\n";
        return;
    }

    readfile($path);
    if (@filesize($path) > 0) {
        echo "\n";
    }
}

$jobId = trim((string) ($_GET['job_id'] ?? ''));
$preservedPath = ($jobId !== '') ? zfsas_ops_failed_send_log_path($jobId) : '';
$sharedPath = zfsas_ops_shared_send_log_path();
$sharedArchivePath = zfsas_ops_shared_send_log_archive_path();

$downloadName = 'zfs_autosnapshot_send.log';
if ($jobId !== '') {
    $downloadName = 'zfs_autosnapshot_send_' . zfsas_ops_sanitize_job_id_for_path($jobId) . '.log';
}

if (!headers_sent()) {
    header('Content-Type: text/plain; charset=UTF-8');
    header('Content-Disposition: attachment; filename="' . $downloadName . '"');
    header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
    header('Pragma: no-cache');
    header('X-Content-Type-Options: nosniff');
}

echo "ZFS Send Log Export\n";
echo "Generated: " . gmdate('Y-m-d H:i:s') . " UTC\n";
if ($jobId !== '') {
    echo "Job ID: " . $jobId . "\n";
}

if ($jobId !== '') {
    echo "Preserved failure log: " . basename($preservedPath) . "\n";
}

echo "\n";

if ($jobId !== '' && is_file($preservedPath)) {
    echo "===== Preserved Failure Log =====\n";
    zfsas_send_log_stream_text($preservedPath);
    exit;
}

if ($jobId !== '') {
    echo "No preserved failure log exists for this job yet. Falling back to the current shared send log.\n\n";
}

if (is_file($sharedArchivePath)) {
    echo "===== Archived Shared Send Log =====\n";
    zfsas_send_log_stream_text($sharedArchivePath);
    echo "\n";
}

echo "===== Current Shared Send Log =====\n";
zfsas_send_log_stream_text($sharedPath);
