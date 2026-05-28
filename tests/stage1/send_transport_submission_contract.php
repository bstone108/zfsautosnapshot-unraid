<?php
require_once __DIR__ . '/../../source/usr/local/emhttp/plugins/zfs.autosnapshot/php/send-helpers.php';

function assert_true($condition, $message) {
    if (!$condition) {
        fwrite(STDERR, "FAIL: {$message}\n");
        exit(1);
    }
}

function assert_error_contains($result, $needle, $message) {
    $errors = implode("\n", $result['errors'] ?? []);
    assert_true(strpos($errors, $needle) !== false, $message . " (errors: {$errors})");
}

function make_sync_script($dir) {
    $script = $dir . '/sync.sh';
    file_put_contents($script, "#!/bin/sh\nexit 0\n");
    chmod($script, 0755);
    return $script;
}

function base_post($transport) {
    return [
        'send_snapshot_prefix' => 'zfs-send-',
        'send_max_parallel' => '1',
        'send_prep_extra_workers' => '16',
        'send_keep_all_for_days' => '14',
        'send_keep_daily_until_days' => '30',
        'send_keep_weekly_until_days' => '183',
        'new_job_source' => 'source/data',
        'new_job_destination' => 'backup/data',
        'new_job_frequency' => '1d',
        'new_job_threshold' => '10G',
        'new_job_children' => '0',
        'new_job_transport' => $transport,
    ];
}

$tmpRoot = sys_get_temp_dir() . '/zfsas-send-transport-submit-' . getmypid() . '-' . bin2hex(random_bytes(4));
mkdir($tmpRoot, 0775, true);
$configDir = $tmpRoot . '/config';
$configFile = $configDir . '/zfs_send.conf';
$syncScript = make_sync_script($tmpRoot);
$config = zfsas_send_defaults();

$sshMissingHost = base_post('ssh');
$sshMissingHost['send_ssh_host'] = '';
$sshMissingHost['send_ssh_port'] = '22';
$sshMissingHost['send_ssh_user'] = 'root';
$sshResult = zfsas_send_handle_save_request($sshMissingHost, $configDir, $configFile, $syncScript, $config, '/Settings/ZFSSnapshots');
assert_true(!$sshResult['saved'], 'SSH jobs must not be saved without a configured SSH host.');
assert_error_contains($sshResult, 'SSH host is required when any ZFS send job uses SSH transport.', 'SSH missing-host validation should explain the required receiver host.');

$spipedMissingEndpoint = base_post('spiped');
$spipedMissingEndpoint['send_spiped_remote_host'] = '';
$spipedMissingEndpoint['send_spiped_remote_port'] = '8023';
$spipedMissingEndpoint['send_spiped_key_path'] = '/boot/config/plugins/zfs.autosnapshot/spiped/key.bin';
$spipedEndpointResult = zfsas_send_handle_save_request($spipedMissingEndpoint, $configDir, $configFile, $syncScript, $config, '/Settings/ZFSSnapshots');
assert_true(!$spipedEndpointResult['saved'], 'spiped jobs must not be saved without a configured remote receiver host.');
assert_error_contains($spipedEndpointResult, 'spiped remote host is required when any ZFS send job uses spiped transport.', 'spiped missing-host validation should explain the required receiver endpoint.');

$spipedMissingKey = base_post('spiped');
$spipedMissingKey['send_spiped_remote_host'] = 'receiver.example.test';
$spipedMissingKey['send_spiped_remote_port'] = '8023';
$spipedMissingKey['send_spiped_key_path'] = '';
$spipedKeyResult = zfsas_send_handle_save_request($spipedMissingKey, $configDir, $configFile, $syncScript, $config, '/Settings/ZFSSnapshots');
assert_true(!$spipedKeyResult['saved'], 'spiped jobs must not be saved without a configured symmetric-key path.');
assert_error_contains($spipedKeyResult, 'spiped key path is required when any ZFS send job uses spiped transport.', 'spiped missing-key validation should explain the required local key path.');

$validSsh = base_post('ssh');
$validSsh['send_ssh_host'] = 'receiver.example.test';
$validSsh['send_ssh_port'] = '22';
$validSsh['send_ssh_user'] = 'root';
$validSshResult = zfsas_send_handle_save_request($validSsh, $configDir, $configFile, $syncScript, $config, '/Settings/ZFSSnapshots');
assert_true($validSshResult['saved'], 'SSH jobs with receiver host and non-interactive/preconfigured auth should still save.');

@unlink($configFile);
@rmdir($configDir);
@unlink($syncScript);
@rmdir($tmpRoot);

echo "PASS: send transport submission contract\n";
