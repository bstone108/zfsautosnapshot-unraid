#!/usr/bin/env python3
"""Static contracts for the emergency removal of broken Repair/Recovery Tools."""
from __future__ import annotations

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
PLUGIN = ROOT / "source/usr/local/emhttp/plugins/zfs.autosnapshot"
SETTINGS = PLUGIN / "php/settings.php"
PACKAGE_SOURCE = ROOT / "source"

REMOVED_PATHS = [
    PLUGIN / "php/recovery-tools.php",
    PLUGIN / "php/recovery-status.php",
    PLUGIN / "php/recovery-action.php",
    PLUGIN / "php/recovery-helpers.php",
    ROOT / "source/usr/local/sbin/zfs_autosnapshot_recovery_scan",
]

FORBIDDEN_SETTINGS_SNIPPETS = [
    "open_recovery_tools",
    "recoveryToolsUrl",
    "zfsas_tab_repairs",
    "zfsas_panel_repair_tools",
    "data-section-target=\"repair-tools\"",
    "data-section-panel=\"repair-tools\"",
]


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> int:
    for path in REMOVED_PATHS:
        if path.exists():
            fail(f"removed Repair/Recovery Tools path still exists: {path.relative_to(ROOT)}")

    settings = SETTINGS.read_text(encoding="utf-8")
    for snippet in FORBIDDEN_SETTINGS_SNIPPETS:
        if snippet in settings:
            fail(f"settings page still exposes Repair/Recovery Tools snippet: {snippet}")

    post_install = PLUGIN.joinpath("scripts/post-install.sh").read_text(encoding="utf-8")
    for stale_path in [
        "/usr/local/emhttp/plugins/zfs.autosnapshot/php/recovery-tools.php",
        "/usr/local/emhttp/plugins/zfs.autosnapshot/php/recovery-status.php",
        "/usr/local/emhttp/plugins/zfs.autosnapshot/php/recovery-action.php",
        "/usr/local/emhttp/plugins/zfs.autosnapshot/php/recovery-helpers.php",
        "/usr/local/sbin/zfs_autosnapshot_recovery_scan",
    ]:
        if f"rm -f {stale_path}" not in post_install:
            fail(f"post-install does not delete stale removed tool file: {stale_path}")

    print("PASS: Repair/Recovery Tools are removed from package and settings UI")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
