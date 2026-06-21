#!/usr/bin/env python3
"""Static contracts for send settings safety when PHP is unavailable in CI/dev."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SEND_HELPERS = ROOT / "source/usr/local/emhttp/plugins/zfs.autosnapshot/php/send-helpers.php"
SEND_SETTINGS = ROOT / "source/usr/local/emhttp/plugins/zfs.autosnapshot/php/send-settings.php"
SEND_EXAMPLE = ROOT / "source/usr/local/emhttp/plugins/zfs.autosnapshot/config/zfs_send.conf.example"
README = ROOT / "README.md"


def assert_contains(text: str, needle: str, message: str) -> None:
    if needle not in text:
        raise AssertionError(message)


def main() -> int:
    text = SEND_HELPERS.read_text()
    settings = SEND_SETTINGS.read_text()
    example = SEND_EXAMPLE.read_text()
    readme = README.read_text()
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
        "function zfsas_send_gui_transport_options",
        "send settings must keep a separate GUI transport list so unfinished transports can remain wired but hidden",
    )
    assert_contains(
        text,
        "unset($options['spiped'])",
        "send settings GUI must hide unfinished spiped transport while preserving backend config parsing",
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
        "SEND_SPIPED_LISTEN_HOST",
        "send settings must persist spiped receiver listen host before enabling spiped transport",
    )
    assert_contains(
        text,
        "SEND_SPIPED_PORT",
        "send settings must persist spiped receiver port before enabling spiped transport",
    )
    assert_contains(
        text,
        "SEND_SPIPED_KEY_PATH",
        "send settings must persist a spiped key path without storing raw key material",
    )
    assert_contains(
        text,
        "SEND_SPIPED_REMOTE_HOST",
        "send settings must persist the remote spiped receiver host before spiped sender pipelines can run",
    )
    assert_contains(
        text,
        "SEND_SPIPED_REMOTE_PORT",
        "send settings must persist the remote spiped receiver port separately from the local listener",
    )
    for hidden_field in (
        'name="send_spiped_key_path"',
        'name="send_spiped_remote_host"',
        'name="send_spiped_port"',
        'name="send_spiped_listen_host"',
        'name="send_spiped_remote_port"',
    ):
        if hidden_field in settings:
            raise AssertionError("send settings UI must not expose unfinished spiped fields")
    assert_contains(
        settings,
        "zfsas_send_gui_transport_options()",
        "send settings UI must use the GUI-safe transport options list",
    )
    assert_contains(
        settings,
        "Unavailable transport saved in config",
        "send settings UI must preserve existing hidden/future transports without exposing them for new selection",
    )
    assert_contains(
        settings,
        "SSH sends run zfs send through an audited ssh receive command",
        "send settings UI must explain that SSH transport is an active transfer path, not only saved future metadata",
    )
    if "spiped" in settings.lower():
        raise AssertionError("send settings UI must not show unfinished spiped copy or controls")
    if "spiped sends stream through the configured remote spipe endpoint" in settings:
        raise AssertionError("send settings UI must not claim spiped jobs are active while worker fail-closed receiver inventory is still pending")
    if "Network transport choices are saved for future receiver plumbing; local sends remain the active transfer path." in settings:
        raise AssertionError("send settings UI must not keep stale network-transport copy after SSH pipeline support is wired")
    assert_contains(
        example,
        "SEND_SPIPED_KEY_PATH",
        "example send config must document spiped receiver key-path settings",
    )
    assert_contains(
        example,
        "SEND_SPIPED_REMOTE_HOST",
        "example send config must document sender-side remote spiped endpoint settings",
    )
    assert_contains(
        example,
        "SSH transports actively run zfs send through non-interactive ssh",
        "example send config must document that SSH is an active network send path",
    )
    assert_contains(
        example,
        "spiped transports fail closed until receiver-side snapshot inventory",
        "example send config must document spiped's current fail-closed receiver-safety limitation separately from SSH",
    )
    assert_contains(
        example,
        "receive verification are implemented",
        "example send config must document that spiped receive verification is still pending",
    )
    if "Network transports are stored for receiver setup plumbing and fail closed" in example:
        raise AssertionError("example send config must not incorrectly describe all network transports as fail-closed after SSH support is active")
    assert_contains(
        readme,
        "SSH transport can send over the network using non-interactive SSH",
        "README ZFS Send section must document SSH as an active network transport",
    )
    assert_contains(
        readme,
        "spiped code and config plumbing are retained for future encrypted transport work, but the feature is incomplete and intentionally hidden from the WebGUI",
        "README ZFS Send section must document spiped's incomplete hidden status",
    )
    assert_contains(
        readme,
        "remote SSH destination snapshots",
        "README ZFS Send section must mention remote SSH destination cleanup/protection semantics",
    )
    if "network transports are stored for future plumbing" in readme.lower():
        raise AssertionError("README must not describe all network transports as future-only after SSH support is active")
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
