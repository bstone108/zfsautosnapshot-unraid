<?php
$scriptPath = '/usr/local/sbin/zfs_autosnapshot_send';
$debugLogFile = '/var/log/zfs_autosnapshot_send.log';
$runtimeDir = '/var/run/zfs-autosnapshot-send';
$lockFile = $runtimeDir . '/zfs_autosnapshot_send.lock';
$lockDir = $runtimeDir . '/zfs_autosnapshot_send.lockdir';

umask(0077);

function sendJson($payload, $statusCode = 200)
{
    if (!headers_sent()) {
        http_response_code((int) $statusCode);
        header('Content-Type: application/json; charset=UTF-8');
        header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
        header('Pragma: no-cache');
        header('X-Content-Type-Options: nosniff');
    }

    echo json_encode($payload);
    exit;
}

function ensureRuntimeDir($runtimeDir)
{
    clearstatcache(true, $runtimeDir);

    if (is_link($runtimeDir)) {
        return 'Runtime directory path is unsafe.';
    }

    if (file_exists($runtimeDir) && !is_dir($runtimeDir)) {
        return 'Runtime directory path is not a directory.';
    }

    if (!file_exists($runtimeDir) && !@mkdir($runtimeDir, 0700, true) && !is_dir($runtimeDir)) {
        return 'Unable to create runtime directory.';
    }

    @chmod($runtimeDir, 0700);
    @chown($runtimeDir, 0);
    @chgrp($runtimeDir, 0);
    return null;
}

function ensureSafeRegularFile($path, $mode)
{
    clearstatcache(true, $path);

    if (is_link($path)) {
        return 'Requested file path is unsafe.';
    }

    $parent = dirname($path);
    clearstatcache(true, $parent);

    if (is_link($parent) || !is_dir($parent)) {
        return 'Requested file parent directory is unsafe.';
    }

    if (file_exists($path) && !is_file($path)) {
        return 'Requested file path is not a regular file.';
    }

    if (!file_exists($path) && !@touch($path)) {
        return 'Unable to create the requested file.';
    }

    @chmod($path, $mode);
    @chown($path, 0);
    @chgrp($path, 0);
    return null;
}

function isSafeRuntimePath($path, $expectDirectory = false)
{
    clearstatcache(true, $path);

    if (is_link($path)) {
        return false;
    }

    if (!file_exists($path)) {
        return true;
    }

    if ($expectDirectory) {
        return is_dir($path);
    }

    return is_file($path);
}

function isRunInProgress($lockFile, $lockDir)
{
    if (is_string($lockDir) && $lockDir !== '' && is_dir($lockDir)) {
        return true;
    }

    if (!is_string($lockFile) || $lockFile === '') {
        return false;
    }

    $fh = @fopen($lockFile, 'c');
    if ($fh === false) {
        return false;
    }

    $locked = @flock($fh, LOCK_EX | LOCK_NB);
    if ($locked === false) {
        @fclose($fh);
        return true;
    }

    @flock($fh, LOCK_UN);
    @fclose($fh);
    return false;
}

if (strtoupper($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    sendJson([
        'ok' => false,
        'error' => 'Use POST for manual ZFS send requests.',
    ], 405);
}

if (!is_file($scriptPath) || !is_executable($scriptPath)) {
    sendJson([
        'ok' => false,
        'error' => 'ZFS send script is missing or not executable.',
    ], 500);
}

$runtimeError = ensureRuntimeDir($runtimeDir);
if ($runtimeError !== null) {
    sendJson([
        'ok' => false,
        'error' => $runtimeError,
    ], 500);
}

if (($logError = ensureSafeRegularFile($debugLogFile, 0600)) !== null) {
    sendJson([
        'ok' => false,
        'error' => $logError,
    ], 500);
}

if (!isSafeRuntimePath($lockFile, false) || !isSafeRuntimePath($lockDir, true)) {
    sendJson([
        'ok' => false,
        'error' => 'ZFS send runtime paths are unsafe. Check the server filesystem and try again.',
    ], 500);
}

if (isRunInProgress($lockFile, $lockDir)) {
    sendJson([
        'ok' => false,
        'error' => 'A ZFS send run is already in progress. Wait for it to finish, then try again.',
    ], 409);
}

$command = 'nohup ' . escapeshellarg($scriptPath) . ' >> ' . escapeshellarg($debugLogFile) . ' 2>&1 < /dev/null & echo $!';
$output = [];
$exitCode = 0;
@exec($command, $output, $exitCode);

if ($exitCode !== 0 || count($output) === 0) {
    sendJson([
        'ok' => false,
        'error' => 'Failed to start manual ZFS send run.',
    ], 500);
}

$pidRaw = trim((string) end($output));
$pid = (preg_match('/^[0-9]+$/', $pidRaw) === 1) ? (int) $pidRaw : 0;

sendJson([
    'ok' => true,
    'pid' => $pid,
    'message' => ($pid > 0)
        ? "Manual ZFS send run started (PID {$pid})."
        : 'Manual ZFS send run started.',
]);
