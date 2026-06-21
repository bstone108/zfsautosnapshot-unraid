<?php
$root = dirname(__DIR__, 2);
require_once $root . '/source/usr/local/emhttp/plugins/zfs.autosnapshot/php/snapshot-manager-helpers.php';

function fail_contract($message)
{
    fwrite(STDERR, "FAIL: " . $message . PHP_EOL);
    exit(1);
}

if (!function_exists('zfsas_sm_actionable_snapshot_rows')) {
    fail_contract('Snapshot Manager must define a server-side action eligibility filter');
}

$rows = [
    [
        'snapshot' => 'tank/appdata@already-held',
        'snapshotName' => 'already-held',
        'createdEpoch' => 100,
        'held' => true,
        'pendingDelete' => false,
    ],
    [
        'snapshot' => 'tank/appdata@unheld',
        'snapshotName' => 'unheld',
        'createdEpoch' => 200,
        'held' => false,
        'pendingDelete' => false,
    ],
    [
        'snapshot' => 'tank/appdata@delete-queued',
        'snapshotName' => 'delete-queued',
        'createdEpoch' => 300,
        'held' => false,
        'pendingDelete' => true,
    ],
];

$holdRows = zfsas_sm_actionable_snapshot_rows('hold', $rows, $skippedHold);
if (array_column($holdRows, 'snapshot') !== ['tank/appdata@unheld']) {
    fail_contract('server-side hold filtering must skip already-held and pending-delete snapshots');
}
if ((int) $skippedHold !== 2) {
    fail_contract('server-side hold filtering must report skipped ineligible rows');
}

$releaseRows = zfsas_sm_actionable_snapshot_rows('release', $rows, $skippedRelease);
if (array_column($releaseRows, 'snapshot') !== ['tank/appdata@already-held']) {
    fail_contract('server-side release filtering must skip unheld and pending-delete snapshots');
}
if ((int) $skippedRelease !== 2) {
    fail_contract('server-side release filtering must report skipped ineligible rows');
}

$actionPhp = file_get_contents($root . '/source/usr/local/emhttp/plugins/zfs.autosnapshot/php/snapshot-manager-action.php');
if (strpos($actionPhp, 'zfsas_sm_actionable_snapshot_rows($action, $ordered') === false) {
    fail_contract('snapshot-manager-action.php must apply server-side eligibility before queueing operations');
}

echo "PASS: Snapshot Manager server-side action eligibility contract\n";
