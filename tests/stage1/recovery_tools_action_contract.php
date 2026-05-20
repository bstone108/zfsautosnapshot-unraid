<?php
// Focused contracts for guarded Recovery Tools actions.
$root = dirname(__DIR__, 2);
require_once $root . '/source/usr/local/emhttp/plugins/zfs.autosnapshot/php/recovery-helpers.php';

function assert_true($condition, $message) {
    if (!$condition) {
        fwrite(STDERR, "FAIL: {$message}\n");
        exit(1);
    }
}

$tmp = sys_get_temp_dir() . '/zfsas_recovery_action_' . getmypid();
$sourceMount = $tmp . '/mnt/tank/appdata';
$destMount = $tmp . '/mnt/backup/appdata';
@mkdir($sourceMount . '/config', 0775, true);
@mkdir($sourceMount . '/.zfs/snapshot/good/config', 0775, true);
@mkdir($destMount . '/.zfs/snapshot/zfs-send-good/config', 0775, true);
$affectedPath = $sourceMount . '/config/db.sqlite';
$localCandidatePath = $sourceMount . '/.zfs/snapshot/good/config/db.sqlite';
$sendCandidatePath = $destMount . '/.zfs/snapshot/zfs-send-good/config/db.sqlite';
file_put_contents($affectedPath, 'bad-current');
file_put_contents($localCandidatePath, 'snapshot-clean');
file_put_contents($sendCandidatePath, 'send-clean');

$datasetRows = [
    ['dataset' => 'tank/appdata', 'mountpoint' => $sourceMount],
    ['dataset' => 'backup/appdata', 'mountpoint' => $destMount],
];
$sendJobs = [
    ['source' => 'tank/appdata', 'destination' => 'backup/appdata', 'children' => '0'],
];

$error = null;
$result = zfsas_recovery_perform_guarded_action([
    'recovery_action' => 'delete_file',
    'dataset' => 'tank/appdata',
    'path' => $affectedPath,
], $datasetRows, $sendJobs, $error);
assert_true($result === false, 'delete must fail without explicit confirmation');
assert_true(is_file($affectedPath), 'delete without confirmation must not remove the affected file');
assert_true(stripos((string) $error, 'confirmation') !== false, 'missing confirmation error must be explicit');

$error = null;
$result = zfsas_recovery_perform_guarded_action([
    'recovery_action' => 'restore_clean_copy',
    'dataset' => 'tank/appdata',
    'path' => $affectedPath,
    'candidate_sha256' => hash_file('sha256', $localCandidatePath),
    'confirmation' => 'RESTORE',
], $datasetRows, $sendJobs, $error);
assert_true(is_array($result) && ($result['ok'] ?? false) === true, 'restore must succeed with a discovered readable candidate and explicit RESTORE confirmation');
assert_true(file_get_contents($affectedPath) === 'snapshot-clean', 'restore must copy the selected clean candidate over the affected file');
assert_true(($result['candidate']['path'] ?? '') === $localCandidatePath, 'restore must report the exact selected candidate path');

file_put_contents($affectedPath, 'bad-current-again');
$error = null;
$result = zfsas_recovery_perform_guarded_action([
    'recovery_action' => 'restore_clean_copy',
    'dataset' => 'tank/appdata',
    'path' => $affectedPath,
    'candidate_sha256' => hash('sha256', 'not-a-discovered-copy'),
    'confirmation' => 'RESTORE',
], $datasetRows, $sendJobs, $error);
assert_true($result === false, 'restore must reject candidate hashes that were not discovered for this affected file');
assert_true(file_get_contents($affectedPath) === 'bad-current-again', 'rejected restore must leave the affected file unchanged');

$error = null;
$result = zfsas_recovery_perform_guarded_action([
    'recovery_action' => 'aggressive_read',
    'dataset' => 'tank/appdata',
    'path' => $affectedPath,
    'confirmation' => 'READ',
], $datasetRows, $sendJobs, $error);
assert_true(is_array($result) && ($result['ok'] ?? false) === true, 'aggressive read must succeed with explicit READ confirmation');
assert_true(($result['sha256'] ?? '') === hash_file('sha256', $affectedPath), 'aggressive read must hash the existing affected file without modifying it');
assert_true(file_get_contents($affectedPath) === 'bad-current-again', 'aggressive read must not modify or delete the affected file');

$error = null;
$result = zfsas_recovery_perform_guarded_action([
    'recovery_action' => 'delete_file',
    'dataset' => 'tank/appdata',
    'path' => $affectedPath,
    'confirmation' => 'DELETE',
], $datasetRows, $sendJobs, $error);
assert_true(is_array($result) && ($result['ok'] ?? false) === true, 'delete must succeed only with explicit DELETE confirmation');
assert_true(!file_exists($affectedPath), 'confirmed delete must remove the selected affected file');

exec('rm -rf ' . escapeshellarg($tmp));
echo "PASS: Recovery Tools guarded action contracts\n";
