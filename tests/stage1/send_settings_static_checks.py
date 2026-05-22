#!/usr/bin/env python3
"""Static contracts for send settings safety when PHP is unavailable in CI/dev."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SEND_HELPERS = ROOT / "source/usr/local/emhttp/plugins/zfs.autosnapshot/php/send-helpers.php"
SEND_SETTINGS = ROOT / "source/usr/local/emhttp/plugins/zfs.autosnapshot/php/send-settings.php"
SEND_EXAMPLE = ROOT / "source/usr/local/emhttp/plugins/zfs.autosnapshot/config/zfs_send.conf.example"


def assert_contains(text: str, needle: str, message: str) -> None:
    if needle not in text:
        raise AssertionError(message)


def main() -> int:
    text = SEND_HELPERS.read_text()
    settings = SEND_SETTINGS.read_text()
    example = SEND_EXAMPLE.read_text()
    assert_contains(
        text,
        "function zfsas_send_normalize_dataset_path",
        "send settings must normalize dataset paths before hashing/storing jobs",
    )
    assert_contains(
        text,
        "rtrim(zfsas_send_trim($value), '/')",
        "dataset normalization must trim trailing slashes so job IDs/prefixes stay stable",
    )
    assert_contains(
        text,
        "function zfsas_send_normalize_transport",
        "send settings must have explicit transport-mode normalization before network-send fields are accepted",
    )
    assert_contains(
        text,
        "$transportRaw = $pieces[6] ?? 'local';",
        "legacy six-field ZFS send jobs must default to local transport for backwards compatibility",
    )
    assert_contains(
        text,
        "jobid|source|destination|frequency|threshold|children|transport",
        "rendered config help must document the transport field in SEND_JOBS entries",
    )
    assert_contains(
        text,
        "$job['transport'] ?? 'local'",
        "rendered SEND_JOBS entries must persist transport with a local fallback",
    )
    assert_contains(
        settings,
        'name="new_job_transport"',
        "send settings UI must expose a transport selector for newly added jobs",
    )
    assert_contains(
        settings,
        'name="job_transport[<?php echo (int) $index; ?>]"',
        "send settings UI must preserve transport selection for existing jobs",
    )
    assert_contains(
        example,
        "jobid|source|destination|frequency|threshold|children|transport",
        "example send config must document the optional transport field",
    )
    assert_contains(
        text,
        "SEND_SSH_HOST",
        "send settings must persist SSH receiver host configuration before enabling SSH transport",
    )
    assert_contains(
        text,
        "SEND_SSH_PORT",
        "send settings must persist SSH receiver port configuration before enabling SSH transport",
    )
    assert_contains(
        text,
        "SEND_SSH_USER",
        "send settings must persist SSH receiver user configuration before enabling SSH transport",
    )
    assert_contains(
        text,
        "SEND_SSH_KEY_PATH",
        "send settings must persist SSH key path configuration without storing raw key material",
    )
    assert_contains(
        settings,
        'name="send_ssh_host"',
        "send settings UI must expose an SSH host field near network transport controls",
    )
    assert_contains(
        settings,
        'name="send_ssh_key_path"',
        "send settings UI must expose an SSH key path field rather than a raw private-key/password field",
    )
    assert_contains(
        example,
        "SEND_SSH_HOST",
        "example send config must document SSH receiver settings",
    )
    assert_contains(
        text,
        "function zfsas_send_write_config_atomically",
        "send settings must write zfs_send.conf through an atomic temp-file + rename helper",
    )
    assert_contains(
        text,
        "rename($tmpFile, $configFile)",
        "send settings config writes must publish with rename(), not a direct truncate/write",
    )
    direct_write = "file_put_contents($configFile, zfsas_send_render_config($config))"
    if direct_write in text:
        raise AssertionError("send settings must not directly truncate/write zfs_send.conf")
    print("PASS: send settings static safety contracts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
