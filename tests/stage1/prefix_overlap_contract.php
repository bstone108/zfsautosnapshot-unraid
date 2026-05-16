<?php
require_once __DIR__ . '/../../source/usr/local/emhttp/plugins/zfs.autosnapshot/php/send-helpers.php';

function assert_true($condition, $message) {
    if (!$condition) {
        fwrite(STDERR, "FAIL: {$message}\n");
        exit(1);
    }
}

function assert_false($condition, $message) {
    assert_true(!$condition, $message);
}

function assert_contains($needle, $haystack, $message) {
    assert_true(strpos((string) $haystack, $needle) !== false, $message . "\nExpected to find: {$needle}\nIn: {$haystack}");
}

assert_false(zfsas_snapshot_prefixes_conflict('autosnapshot-', 'zfs-send-'), 'distinct default prefixes should be allowed');
assert_true(zfsas_snapshot_prefixes_conflict('zfs-send-', 'zfs-send-'), 'identical auto/send prefixes must be rejected');
assert_true(zfsas_snapshot_prefixes_conflict('zfs-', 'zfs-send-'), 'auto prefix that can match send checkpoints must be rejected');
assert_true(zfsas_snapshot_prefixes_conflict('zfs-send-daily-', 'zfs-send-'), 'auto prefix under the send checkpoint namespace must be rejected');

$message = zfsas_snapshot_prefix_conflict_message('zfs-', 'zfs-send-');
assert_contains('Auto-snapshot prefix', $message, 'conflict message should identify the auto-snapshot prefix');
assert_contains('zfs-', $message, 'conflict message should include the auto prefix');
assert_contains('zfs-send-', $message, 'conflict message should include the send prefix');

$tempDir = sys_get_temp_dir() . '/zfsas-prefix-contract-' . getmypid();
mkdir($tempDir, 0770, true);
$syncScript = $tempDir . '/sync-cron.sh';
file_put_contents($syncScript, "#!/bin/sh\nexit 0\n");
chmod($syncScript, 0755);
$configFile = $tempDir . '/zfs_send.conf';

$config = zfsas_send_defaults();
$post = [
    'send_snapshot_prefix' => 'zfs-send-',
    'send_max_parallel' => '1',
    'send_prep_extra_workers' => '16',
    'send_keep_all_for_days' => '14',
    'send_keep_daily_until_days' => '30',
    'send_keep_weekly_until_days' => '183',
];

$result = zfsas_send_handle_save_request($post, $tempDir, $configFile, $syncScript, $config, '/Settings/ZFSAutoSnapshotSend', 'zfs-');
assert_false($result['saved'], 'send settings save should be refused when send prefix overlaps current auto prefix');
assert_true(!file_exists($configFile), 'refused send settings save must not write zfs_send.conf');
assert_contains('Auto-snapshot prefix', implode("\n", $result['errors']), 'send settings save error should be visible and specific');

array_map('unlink', glob($tempDir . '/*'));
rmdir($tempDir);

print("PASS: prefix overlap contracts\n");
