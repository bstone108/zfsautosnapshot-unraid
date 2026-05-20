<?php
// Focused contracts for non-destructive Recovery Tools clean-copy discovery.
$root = dirname(__DIR__, 2);
require_once $root . '/source/usr/local/emhttp/plugins/zfs.autosnapshot/php/recovery-helpers.php';

function assert_true($condition, $message) {
    if (!$condition) {
        fwrite(STDERR, "FAIL: {$message}\n");
        exit(1);
    }
}

$tmp = sys_get_temp_dir() . '/zfsas_recovery_discovery_' . getmypid();
$sourceMount = $tmp . '/mnt/tank/appdata';
$destMount = $tmp . '/mnt/backup/appdata';
@mkdir($sourceMount . '/config', 0775, true);
@mkdir($sourceMount . '/.zfs/snapshot/good/config', 0775, true);
@mkdir($sourceMount . '/.zfs/snapshot/unreadable/config', 0775, true);
@mkdir($destMount . '/.zfs/snapshot/zfs-send-good/config', 0775, true);
file_put_contents($sourceMount . '/.zfs/snapshot/good/config/db.sqlite', 'snapshot-clean');
file_put_contents($destMount . '/.zfs/snapshot/zfs-send-good/config/db.sqlite', 'send-clean');
file_put_contents($sourceMount . '/config/db.sqlite', 'bad-current');

$option = [
    'dataset' => 'tank/appdata',
    'path' => $sourceMount . '/config/db.sqlite',
    'source' => 'manual readability scan',
];
$datasetRows = [
    ['dataset' => 'tank/appdata', 'mountpoint' => $sourceMount],
    ['dataset' => 'backup/appdata', 'mountpoint' => $destMount],
];
$sendJobs = [
    ['source' => 'tank/appdata', 'destination' => 'backup/appdata', 'children' => '0'],
];

$discovered = zfsas_recovery_discover_clean_copies_for_option($option, $datasetRows, $sendJobs);

assert_true(($discovered['state'] ?? '') === 'ready', 'discovery must mark the option ready when readable candidates are found');
assert_true(($discovered['actionsEnabled'] ?? true) === false, 'discovery must not enable restore/delete actions without the later guarded confirmation flow');
assert_true(($discovered['relativePath'] ?? '') === 'config/db.sqlite', 'discovery must derive a dataset-relative path for the affected file');
$candidates = $discovered['cleanCandidates'] ?? [];
assert_true(count($candidates) === 2, 'discovery must find both local snapshot and ZFS send-destination candidates');
$types = array_column($candidates, 'type');
assert_true(in_array('local_snapshot', $types, true), 'discovery must include local snapshot candidates');
assert_true(in_array('send_destination_snapshot', $types, true), 'discovery must include ZFS send destination snapshot candidates');
foreach ($candidates as $candidate) {
    assert_true(($candidate['readable'] ?? false) === true, 'candidate must be proven readable before being offered');
    assert_true(($candidate['path'] ?? '') !== $option['path'], 'candidate must not point back at the affected current file');
}

$unknown = zfsas_recovery_discover_clean_copies_for_option([
    'dataset' => 'tank/appdata',
    'path' => $tmp . '/outside/file.txt',
], $datasetRows, $sendJobs);
assert_true(($unknown['state'] ?? '') === 'blocked', 'paths outside the dataset mount must be blocked instead of guessed');

exec('rm -rf ' . escapeshellarg($tmp));
echo "PASS: Recovery Tools clean-copy discovery contracts\n";
