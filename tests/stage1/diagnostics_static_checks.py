#!/usr/bin/env python3
"""Static contracts for the GitHub issue help/diagnostics workflow."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLUGIN = ROOT / "source/usr/local/emhttp/plugins/zfs.autosnapshot"
SETTINGS_PAGE = PLUGIN / "php/settings.php"
DIAGNOSTICS_PAGE = PLUGIN / "php/diagnostics.php"


def assert_contains(text: str, needle: str, message: str) -> None:
    if needle not in text:
        raise AssertionError(message)


def main() -> int:
    settings = SETTINGS_PAGE.read_text()
    if not DIAGNOSTICS_PAGE.is_file():
        raise AssertionError("diagnostics.php endpoint must exist")
    diagnostics = DIAGNOSTICS_PAGE.read_text()

    assert_contains(
        settings,
        "data-section-target=\"help\"",
        "settings page must expose a Help tab",
    )
    assert_contains(
        settings,
        "https://github.com/bstone108/zfsautosnapshot-unraid/issues",
        "Help tab must link to the repository's GitHub issues page",
    )
    assert_contains(
        settings,
        "zfs_autosnapshot_diagnostics.zip",
        "Help tab must provide a diagnostics zip download button",
    )
    assert_contains(
        settings,
        "/plugins/zfs.autosnapshot/php/diagnostics.php",
        "Help tab diagnostics button must call the diagnostics endpoint",
    )

    assert_contains(
        diagnostics,
        "function zfsas_diagnostics_redact",
        "diagnostics endpoint must redact sensitive values before writing files",
    )
    for token in ["PASSWORD", "API_KEY", "TOKEN", "SECRET"]:
        assert_contains(
            diagnostics,
            token,
            f"diagnostics redaction must cover {token} style secrets",
        )
    assert_contains(
        diagnostics,
        "ZipArchive",
        "diagnostics endpoint must create a zip archive",
    )
    assert_contains(
        diagnostics,
        "/var/log/zfs_autosnapshot.log",
        "diagnostics archive must include the main plugin debug log when present",
    )
    assert_contains(
        diagnostics,
        "/var/log/zfs_autosnapshot_send.log",
        "diagnostics archive must include the send log when present",
    )
    assert_contains(
        diagnostics,
        "/boot/config/plugins/zfs.autosnapshot/zfs_autosnapshot.conf",
        "diagnostics archive must include redacted auto-snapshot config when present",
    )
    assert_contains(
        diagnostics,
        "/boot/config/plugins/zfs.autosnapshot/zfs_send.conf",
        "diagnostics archive must include redacted send config when present",
    )
    assert_contains(
        diagnostics,
        "zfs list",
        "diagnostics archive must collect read-only ZFS dataset/snapshot state",
    )
    assert_contains(
        diagnostics,
        "zpool status",
        "diagnostics archive must collect read-only zpool status",
    )

    print("PASS: diagnostics help/export static contracts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
