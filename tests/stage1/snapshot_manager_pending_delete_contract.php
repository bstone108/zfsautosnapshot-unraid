<?php
$root = dirname(__DIR__, 2);
require_once $root . '/source/usr/local/emhttp/plugins/zfs.autosnapshot/php/snapshot-manager-helpers.php';

function fail_contract($message)
{
    fwrite(STDERR, "FAIL: " . $message . PHP_EOL);
    exit(1);
}

$tmp = sys_get_temp_dir() . '/zfsas_sm_pending_delete_' . getmypid();
$bin = $tmp . '/bin';
$opsRoot = '/tmp/zfs-autosnapshot-ops';
$dataset = 'tank/appdata';
$snapshot = $dataset . '@autosnap_2026-05-20_0700';
$snapshotName = 'autosnap_2026-05-20_0700';

@mkdir($bin, 0775, true);
@mkdir($opsRoot, 0775, true);
@unlink($opsRoot . '/delete-queue.inbox');
@unlink($opsRoot . '/status/delete-queue.state');

$fakeZfs = <<<'SH'
#!/usr/bin/env bash
if [[ "$1 $2 $3 $4 $5 $6 $7 $8 $9" == *"list -H -p -s creation -t snapshot"* ]]; then
  printf 'tank/appdata@autosnap_2026-05-20_0700\t1779260400\t1024\t512\t0\n'
  exit 0
fi
if [[ "$1 $2 $3" == "list -H -o"* ]]; then
  printf 'tank/appdata\n'
  exit 0
fi
if [[ "$1" == "holds" ]]; then
  exit 0
fi
exit 1
SH;
file_put_contents($bin . '/zfs', $fakeZfs);
chmod($bin . '/zfs', 0775);
$oldPath = getenv('PATH');
putenv('PATH=' . $bin . PATH_SEPARATOR . $oldPath);

$line = implode("\t", [
    'ENQUEUE',
    'delete-test-job',
    '1779260410',
    '1779260400',
    $dataset,
    $snapshot,
    $snapshotName,
    '1779260400',
    'guid-123',
    'txg-123',
    'tank',
    '1024',
    '0',
    'snapshot',
    '',
]);
file_put_contents($opsRoot . '/delete-queue.inbox', $line . PHP_EOL);

$error = null;
$rows = zfsas_sm_dataset_snapshots($dataset, $error);
if ($error !== null) {
    fail_contract('snapshot list returned error: ' . $error);
}
if (count($rows) !== 1) {
    fail_contract('queued delete snapshot should remain visible and marked pending, got ' . count($rows) . ' rows');
}
$row = $rows[0];
if (($row['snapshot'] ?? '') !== $snapshot) {
    fail_contract('unexpected snapshot row returned');
}
if (empty($row['pendingDelete'])) {
    fail_contract('queued delete snapshot row must expose pendingDelete=true');
}
if (($row['pendingDeleteState'] ?? '') !== 'queued') {
    fail_contract('queued delete snapshot row must expose pendingDeleteState=queued');
}
if (($row['pendingDeleteJobId'] ?? '') !== 'delete-test-job') {
    fail_contract('queued delete snapshot row must expose the pending delete job id');
}

@unlink($opsRoot . '/delete-queue.inbox');
putenv('PATH=' . $oldPath);

echo "PASS: Snapshot Manager marks queued deletes as pending rows\n";
