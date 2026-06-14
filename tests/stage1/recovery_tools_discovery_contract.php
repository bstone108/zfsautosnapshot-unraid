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
@mkdir($sourceMount . '/.zfs/snapshot/bad-evidence/config', 0775, true);
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
assert_true(($discovered['actionsEnabled'] ?? false) === true, 'discovery must enable guarded restore/delete/read actions after candidate discovery reaches a terminal state');
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

file_put_contents($sourceMount . '/.zfs/snapshot/bad-evidence/config/db.sqlite', 'snapshot-evidence-should-map-to-current');
$snapshotEvidence = zfsas_recovery_discover_clean_copies_for_option([
    'dataset' => 'tank/appdata',
    'path' => $sourceMount . '/.zfs/snapshot/bad-evidence/config/db.sqlite',
    'source' => 'zpool status',
], $datasetRows, $sendJobs);
assert_true(($snapshotEvidence['state'] ?? '') === 'ready', 'snapshot evidence must be mapped to the original file when building repair options');
assert_true(($snapshotEvidence['path'] ?? '') === $sourceMount . '/config/db.sqlite', 'repair option path must show the original file, not the .zfs snapshot evidence path');
assert_true(($snapshotEvidence['relativePath'] ?? '') === 'config/db.sqlite', 'snapshot evidence must preserve the original dataset-relative path');
foreach (($snapshotEvidence['cleanCandidates'] ?? []) as $candidate) {
    assert_true(strpos((string) ($candidate['path'] ?? ''), '/.zfs/snapshot/bad-evidence/') === false, 'the corrupt snapshot evidence path must not be offered as a repair target or clean candidate');
}

$poolDerived = zfsas_recovery_option_candidates([
    'pools' => [
        ['identifiedFiles' => [$sourceMount . '/.zfs/snapshot/bad-evidence/config/db.sqlite']],
    ],
], [], $datasetRows, $sendJobs);
assert_true(count($poolDerived) === 1, 'zpool snapshot evidence must map to one repairable original-file row');
assert_true(($poolDerived[0]['dataset'] ?? '') === 'tank/appdata', 'repairable row must infer the mounted source dataset from the evidence path');
assert_true(($poolDerived[0]['path'] ?? '') === $sourceMount . '/config/db.sqlite', 'repairable row must show the original file path instead of the snapshot path');
assert_true(($poolDerived[0]['actionsEnabled'] ?? false) === true, 'repairable rows derived from zpool evidence must expose guarded actions after discovery');

$poolWithOriginalAndSnapshotEvidence = zfsas_recovery_option_candidates([
    'pools' => [
        ['identifiedFiles' => [
            $sourceMount . '/config/db.sqlite',
            $sourceMount . '/.zfs/snapshot/bad-evidence/config/db.sqlite',
        ]],
    ],
], [], $datasetRows, $sendJobs);
assert_true(count($poolWithOriginalAndSnapshotEvidence) === 1, 'zpool original-file evidence and matching snapshot evidence must collapse to one original repair row');
assert_true(($poolWithOriginalAndSnapshotEvidence[0]['path'] ?? '') === $sourceMount . '/config/db.sqlite', 'deduped repair row must preserve the original corrupt file path');
foreach (($poolWithOriginalAndSnapshotEvidence[0]['cleanCandidates'] ?? []) as $candidate) {
    assert_true(strpos((string) ($candidate['path'] ?? ''), '/.zfs/snapshot/bad-evidence/') === false, 'matching corrupt snapshot evidence must not be offered as a clean candidate when original evidence is also present');
}

$unknown = zfsas_recovery_discover_clean_copies_for_option([
    'dataset' => 'tank/appdata',
    'path' => $tmp . '/outside/file.txt',
], $datasetRows, $sendJobs);
assert_true(($unknown['state'] ?? '') === 'blocked', 'paths outside the dataset mount must be blocked instead of guessed');

exec('rm -rf ' . escapeshellarg($tmp));
echo "PASS: Recovery Tools clean-copy discovery contracts\n";
