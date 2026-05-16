#!/usr/bin/env python3
"""Static contracts for send settings safety when PHP is unavailable in CI/dev."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SEND_HELPERS = ROOT / "source/usr/local/emhttp/plugins/zfs.autosnapshot/php/send-helpers.php"


def assert_contains(text: str, needle: str, message: str) -> None:
    if needle not in text:
        raise AssertionError(message)


def main() -> int:
    text = SEND_HELPERS.read_text()
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
