<?php

if (!defined('ZFSAS_RESPONSE_HELPERS_LOADED')) {
    define('ZFSAS_RESPONSE_HELPERS_LOADED', true);
}

if (!defined('ZFSAS_JSON_BEGIN')) {
    define('ZFSAS_JSON_BEGIN', 'ZFSAS_JSON_BEGIN');
}

if (!defined('ZFSAS_JSON_END')) {
    define('ZFSAS_JSON_END', 'ZFSAS_JSON_END');
}

function zfsas_is_valid_dataset_name($dataset)
{
    return preg_match('/^[A-Za-z0-9._\/:+\-]+$/', (string) $dataset) === 1;
}

function zfsas_get_csrf_token()
{
    static $cachedToken = null;

    if ($cachedToken !== null) {
        return $cachedToken;
    }

    $cachedToken = '';

    if (session_status() === PHP_SESSION_NONE) {
        @session_start();
    }

    if (session_status() === PHP_SESSION_ACTIVE && isset($_SESSION['csrf_token'])) {
        $candidate = trim((string) $_SESSION['csrf_token']);
        if ($candidate !== '') {
            $cachedToken = $candidate;
            return $cachedToken;
        }
    }

    if (isset($GLOBALS['var']) && is_array($GLOBALS['var']) && isset($GLOBALS['var']['csrf_token'])) {
        $candidate = trim((string) $GLOBALS['var']['csrf_token']);
        if ($candidate !== '') {
            $cachedToken = $candidate;
            return $cachedToken;
        }
    }

    if (isset($GLOBALS['csrf_token'])) {
        $candidate = trim((string) $GLOBALS['csrf_token']);
        if ($candidate !== '') {
            $cachedToken = $candidate;
            return $cachedToken;
        }
    }

    $varIniPath = '/var/local/emhttp/var.ini';
    if (is_file($varIniPath) && is_readable($varIniPath)) {
        $parsed = @parse_ini_file($varIniPath, false, INI_SCANNER_RAW);
        if (is_array($parsed) && isset($parsed['csrf_token'])) {
            $candidate = trim((string) $parsed['csrf_token']);
            if ($candidate !== '') {
                $cachedToken = $candidate;
                return $cachedToken;
            }
        }
    }

    return $cachedToken;
}

function zfsas_get_submitted_csrf_token()
{
    $candidates = [
        $_POST['csrf_token'] ?? null,
        $_POST['csrf-token'] ?? null,
        $_POST['_csrf'] ?? null,
        $_SERVER['HTTP_X_CSRF_TOKEN'] ?? null,
        $_SERVER['HTTP_CSRF_TOKEN'] ?? null,
    ];

    foreach ($candidates as $candidate) {
        if (!is_string($candidate)) {
            continue;
        }

        $candidate = trim($candidate);
        if ($candidate !== '') {
            return $candidate;
        }
    }

    return '';
}

function zfsas_validate_csrf_token(&$error = null)
{
    $error = null;

    $expectedToken = zfsas_get_csrf_token();
    if ($expectedToken === '') {
        $error = 'Security token is unavailable. Reload the page and try again.';
        return false;
    }

    $submittedToken = zfsas_get_submitted_csrf_token();
    if ($submittedToken === '') {
        $error = 'Security token is missing. Reload the page and try again.';
        return false;
    }

    if (!hash_equals($expectedToken, $submittedToken)) {
        $error = 'Security token validation failed. Reload the page and try again.';
        return false;
    }

    return true;
}

function zfsas_emit_marked_json($payload, $statusCode = 200)
{
    $GLOBALS['zfsas_json_response_sent'] = true;

    while (ob_get_level() > 0) {
        @ob_end_clean();
    }

    if (!headers_sent()) {
        http_response_code((int) $statusCode);
        header('Content-Type: text/plain; charset=UTF-8');
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

function zfsas_send_redirect_page($url, $message = 'Settings saved. Returning to the settings page...')
{
    if (!headers_sent()) {
        header('Location: ' . (string) $url, true, 303);
        header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
        header('Pragma: no-cache');
        exit;
    }

    $target = htmlspecialchars((string) $url, ENT_QUOTES, 'UTF-8');
    $text = htmlspecialchars((string) $message, ENT_QUOTES, 'UTF-8');

    echo '<div style="padding:16px;">';
    echo '<div>' . $text . '</div>';
    echo '<div style="margin-top:10px;"><a href="' . $target . '">Continue</a></div>';
    echo '</div>';
    echo '<script>window.location.replace(' . json_encode((string) $url) . ');</script>';
    exit;
}

function zfsas_send_standalone_error_page($title, $message, $continueUrl = '', $statusCode = 500)
{
    if (!headers_sent()) {
        http_response_code((int) $statusCode);
        header('Content-Type: text/html; charset=UTF-8');
        header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0');
        header('Pragma: no-cache');
    }

    $safeTitle = htmlspecialchars((string) $title, ENT_QUOTES, 'UTF-8');
    $safeMessage = htmlspecialchars((string) $message, ENT_QUOTES, 'UTF-8');
    $safeContinueUrl = htmlspecialchars((string) $continueUrl, ENT_QUOTES, 'UTF-8');

    echo '<!doctype html><html><head><meta charset="UTF-8">';
    echo '<meta name="viewport" content="width=device-width, initial-scale=1">';
    echo '<title>' . $safeTitle . '</title>';
    echo '<style>';
    echo 'body{font-family:Segoe UI,Tahoma,Geneva,Verdana,sans-serif;background:#f6f7f9;color:#1f2933;margin:0;padding:24px;}';
    echo '.zfsas-error{max-width:760px;margin:0 auto;background:#fff;border:1px solid #d9e2ec;border-radius:10px;padding:24px;box-shadow:0 8px 24px rgba(15,23,42,.08);}';
    echo '.zfsas-error h1{margin:0 0 12px;font-size:24px;}';
    echo '.zfsas-error p{margin:0 0 16px;line-height:1.5;}';
    echo '.zfsas-error a{color:#0f62fe;text-decoration:none;font-weight:600;}';
    echo '</style></head><body><div class="zfsas-error">';
    echo '<h1>' . $safeTitle . '</h1>';
    echo '<p>' . $safeMessage . '</p>';
    if ($safeContinueUrl !== '') {
        echo '<p><a href="' . $safeContinueUrl . '">Return to settings</a></p>';
    }
    echo '</div></body></html>';
    exit;
}

function zfsas_normalize_return_url($url, $fallback = '/Settings/ZFSAutoSnapshot')
{
    $candidate = trim((string) $url);
    if ($candidate === '') {
        return (string) $fallback;
    }

    $crlfMatch = preg_match('/[\r\n]/', $candidate);
    if ($crlfMatch === false || $crlfMatch === 1) {
        return (string) $fallback;
    }

    $parts = @parse_url($candidate);
    if (!is_array($parts)) {
        return (string) $fallback;
    }

    if (isset($parts['scheme']) || isset($parts['host']) || isset($parts['user']) || isset($parts['pass'])) {
        return (string) $fallback;
    }

    $path = (string) ($parts['path'] ?? '');
    if ($path === '' || $path[0] !== '/') {
        return (string) $fallback;
    }

    $query = isset($parts['query']) ? ('?' . $parts['query']) : '';
    return $path . $query;
}
