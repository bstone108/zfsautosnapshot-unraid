<?php
ob_start();

function flushSaveJson($payload, $statusCode = 200)
{
    while (ob_get_level() > 0) {
        ob_end_clean();
    }

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

if (strtoupper($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    flushSaveJson([
        'ok' => false,
        'errors' => ['Use POST for save requests.'],
        'notices' => [],
    ], 405);
}

$_POST['ajax'] = 'save';
$_SERVER['HTTP_X_REQUESTED_WITH'] = 'XMLHttpRequest';

require __DIR__ . '/settings.php';

flushSaveJson([
    'ok' => false,
    'errors' => ['Settings page save handler returned unexpectedly. Reload the page and try again.'],
    'notices' => [],
], 500);
