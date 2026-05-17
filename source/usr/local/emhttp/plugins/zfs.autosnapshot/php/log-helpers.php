<?php

function zfsas_log_is_safe_path($path)
{
    clearstatcache(true, $path);
    $allowedRoot = '/var/log';

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
    if ($dirReal === false || ($dirReal !== $allowedRoot && strpos($dirReal, $allowedRoot . '/') !== 0)) {
        return false;
    }

    $real = realpath($path);
    if ($real !== false && $real !== $allowedRoot && strpos($real, $allowedRoot . '/') !== 0) {
        return false;
    }

    return true;
}

function zfsas_log_tail_file_lines($path, $lineCount, $maxBytes, &$wasTruncated = false)
{
    $wasTruncated = false;

    $lineCount = (int) $lineCount;
    if ($lineCount < 50) {
        $lineCount = 50;
    } elseif ($lineCount > 2000) {
        $lineCount = 2000;
    }

    $maxBytes = (int) $maxBytes;
    if ($maxBytes < 1024) {
        $maxBytes = 1024;
    }

    $output = [];
    $exitCode = 0;
    @exec('tail -n ' . $lineCount . ' ' . escapeshellarg($path) . ' 2>/dev/null', $output, $exitCode);

    if ($exitCode !== 0) {
        return '';
    }

    $text = implode("\n", $output);
    if ($text !== '') {
        $text .= "\n";
    }

    if (strlen($text) > $maxBytes) {
        $text = substr($text, -$maxBytes);
        $wasTruncated = true;
    }

    return $text;
}

function zfsas_log_resolve_type_and_file($requestedType, $summaryLogFile, $debugLogFile)
{
    $type = strtolower(trim((string) $requestedType));
    if ($type === 'debug') {
        return ['debug', $debugLogFile];
    }

    return ['summary', $summaryLogFile];
}
