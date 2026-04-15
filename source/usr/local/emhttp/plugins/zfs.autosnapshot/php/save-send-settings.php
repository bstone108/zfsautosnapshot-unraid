<?php
ob_start();
@ini_set('display_errors', '0');

require_once __DIR__ . '/response-helpers.php';

$defaultReturnUrl = '/plugins/zfs.autosnapshot/php/send-settings.php';
$requestMethod = strtoupper($_SERVER['REQUEST_METHOD'] ?? '');
$requestedWith = (string) ($_SERVER['HTTP_X_REQUESTED_WITH'] ?? '');
$postAjax = trim((string) ($_POST['ajax'] ?? '')) === 'save';
$expectsJson = $postAjax || (strcasecmp($requestedWith, 'XMLHttpRequest') === 0);
$returnUrl = zfsas_normalize_return_url($_POST['return_to'] ?? '', $defaultReturnUrl);

set_error_handler(function ($severity, $message, $file, $line) {
    error_log(sprintf(
        'zfs.autosnapshot save-send-settings warning: %s in %s:%d',
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

    if (!empty($GLOBALS['zfsas_send_save_endpoint_expects_json'])) {
        zfsas_emit_marked_json([
            'ok' => false,
            'errors' => ['ZFS send settings failed before a valid response could be returned. Reload the page and try again.'],
            'notices' => [],
        ], 500);
    }

    zfsas_send_standalone_error_page(
        'ZFS Send Save Failed',
        'The ZFS send save request failed before a valid response could be returned. Reload the send settings page and try again.',
        (string) ($GLOBALS['zfsas_send_save_endpoint_return_url'] ?? '/plugins/zfs.autosnapshot/php/send-settings.php'),
        500
    );
});

set_exception_handler(function ($throwable) {
    error_log(sprintf(
        'zfs.autosnapshot save-send-settings exception: %s in %s:%d',
        (string) $throwable->getMessage(),
        (string) $throwable->getFile(),
        (int) $throwable->getLine()
    ));

    if (!empty($GLOBALS['zfsas_send_save_endpoint_expects_json'])) {
        zfsas_emit_marked_json([
            'ok' => false,
            'errors' => ['ZFS send settings failed unexpectedly. Reload the page and try again.'],
            'notices' => [],
        ], 500);
    }

    zfsas_send_standalone_error_page(
        'ZFS Send Save Failed',
        'The ZFS send save request failed unexpectedly. Reload the send settings page and try again.',
        (string) ($GLOBALS['zfsas_send_save_endpoint_return_url'] ?? '/plugins/zfs.autosnapshot/php/send-settings.php'),
        500
    );
});

$GLOBALS['zfsas_send_save_endpoint_expects_json'] = $expectsJson;
$GLOBALS['zfsas_send_save_endpoint_return_url'] = $returnUrl;

if ($requestMethod !== 'POST') {
    if ($expectsJson) {
        zfsas_emit_marked_json([
            'ok' => false,
            'errors' => ['Use POST for ZFS send save requests.'],
            'notices' => [],
        ], 405);
    }

    zfsas_send_redirect_page($returnUrl, 'Returning to the ZFS send settings page...');
}

if ($expectsJson && !defined('ZFSAS_FORCE_SEND_AJAX_SAVE')) {
    define('ZFSAS_FORCE_SEND_AJAX_SAVE', true);
}

if ($expectsJson) {
    $_POST['ajax'] = 'save';
    $_REQUEST['ajax'] = 'save';
    $_SERVER['HTTP_X_REQUESTED_WITH'] = 'XMLHttpRequest';
}

require __DIR__ . '/send-settings.php';

if ($expectsJson) {
    zfsas_emit_marked_json([
        'ok' => false,
        'errors' => ['ZFS send settings handler returned unexpectedly. Reload the page and try again.'],
        'notices' => [],
    ], 500);
}
