<?php
ob_start();
@ini_set('display_errors', '0');

if (!defined('ZFSAS_JSON_BEGIN')) {
    define('ZFSAS_JSON_BEGIN', 'ZFSAS_JSON_BEGIN');
}

if (!defined('ZFSAS_JSON_END')) {
    define('ZFSAS_JSON_END', 'ZFSAS_JSON_END');
}

function flushSaveJson($payload, $statusCode = 200)
{
    $GLOBALS['zfsas_json_response_sent'] = true;

    while (ob_get_level() > 0) {
        ob_end_clean();
    }

    if (!headers_sent()) {
        http_response_code((int) $statusCode);
        header('Content-Type: application/json; charset=UTF-8');
        header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
        header('Pragma: no-cache');
        header('X-Content-Type-Options: nosniff');
        header('X-Zfsas-Response-Mode: marked-json');
    }

    echo ZFSAS_JSON_BEGIN;
    echo json_encode($payload);
    echo ZFSAS_JSON_END;
    exit;
}

set_error_handler(function ($severity, $message, $file, $line) {
    error_log(sprintf(
        'zfs.autosnapshot save-settings warning: %s in %s:%d',
        (string) $message,
        (string) $file,
        (int) $line
    ));

    return true;
});

register_shutdown_function(function () {
    if (!empty($GLOBALS['zfsas_json_response_sent'])) {
        return;
    }

    $error = error_get_last();
    if ($error === null) {
        return;
    }

    $fatalTypes = [E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR, E_USER_ERROR];
    if (!in_array((int) ($error['type'] ?? 0), $fatalTypes, true)) {
        return;
    }

    flushSaveJson([
        'ok' => false,
        'errors' => ['Save request failed before a valid response could be returned. Reload the page and try again.'],
        'notices' => [],
    ], 500);
});

set_exception_handler(function ($throwable) {
    error_log(sprintf(
        'zfs.autosnapshot save-settings exception: %s in %s:%d',
        (string) $throwable->getMessage(),
        (string) $throwable->getFile(),
        (int) $throwable->getLine()
    ));

    flushSaveJson([
        'ok' => false,
        'errors' => ['Save request failed unexpectedly. Reload the page and try again.'],
        'notices' => [],
    ], 500);
});

if (strtoupper($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    flushSaveJson([
        'ok' => false,
        'errors' => ['Use POST for save requests.'],
        'notices' => [],
    ], 405);
}

if (!defined('ZFSAS_FORCE_AJAX_SAVE')) {
    define('ZFSAS_FORCE_AJAX_SAVE', true);
}

$_POST['ajax'] = 'save';
$_REQUEST['ajax'] = 'save';
$_SERVER['HTTP_X_REQUESTED_WITH'] = 'XMLHttpRequest';

if (trim((string) ($_POST['probe'] ?? '')) === '1') {
    flushSaveJson([
        'ok' => true,
        'probe' => true,
        'notices' => ['Save endpoint probe completed successfully.'],
        'errors' => [],
    ]);
}

require __DIR__ . '/settings.php';

flushSaveJson([
    'ok' => false,
    'errors' => ['Settings page save handler returned unexpectedly. Reload the page and try again.'],
    'notices' => [],
], 500);
