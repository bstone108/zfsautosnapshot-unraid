#!/usr/bin/env python3
"""Static contracts for Recovery Tools repair-option guidance and UI scaffolding."""
from __future__ import annotations

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
PLUGIN = ROOT / "source/usr/local/emhttp/plugins/zfs.autosnapshot"
PAGE = PLUGIN / "php/recovery-tools.php"
HELPERS = PLUGIN / "php/recovery-helpers.php"
STATUS_ENDPOINT = PLUGIN / "php/recovery-status.php"


def require(text: str, pattern: str, message: str, flags: int = 0) -> None:
    if not re.search(pattern, text, flags):
        raise AssertionError(message)


def main() -> int:
    page = PAGE.read_text(encoding="utf-8")
    helpers = HELPERS.read_text(encoding="utf-8")
    status_endpoint = STATUS_ENDPOINT.read_text(encoding="utf-8")

    require(
        page,
        r'Recovery techniques may or may not work.*?use them at your own risk.*?not a replacement for backups',
        "Recovery Tools must show the requested no-warranty/not-a-backup warning prominently on the page.",
        re.S,
    )
    require(
        page,
        r'id="recovery_options_rows"',
        "Recovery Tools must include a dedicated table/body for per-file recovery options.",
    )
    require(
        page,
        r'<th>Recovery options</th>',
        "Recovery option table must have a visible Recovery options column.",
    )
    require(
        page,
        r'function\s+renderRecoveryOptions\s*\(',
        "Recovery Tools JavaScript must render recovery-option rows without a page refresh.",
    )
    require(
        page,
        r'option\.state[^\n]+searching.*?Searching snapshots and ZFS send destinations',
        "Recovery option rows must show when background discovery is still searching snapshots/send destinations.",
        re.S,
    )
    require(
        page,
        r'No restore or delete action runs automatically.*?select an option and confirm it',
        "Recovery Tools must explicitly state that restore/delete actions require user selection and confirmation.",
        re.S,
    )
    require(
        helpers,
        r'function\s+zfsas_recovery_option_candidates\s*\(',
        "Recovery helpers must expose a recovery option candidate inventory function for the status endpoint.",
    )
    require(
        helpers,
        r'"aggressive_read".*?"snapshot_restore".*?"send_destination_restore".*?"delete_file"',
        "Recovery option candidates must reserve the requested recovery action types without enabling unguarded destructive actions.",
        re.S,
    )
    require(
        status_endpoint,
        r"'recoveryOptions'\s*=>\s*zfsas_recovery_option_candidates\(",
        "Recovery status endpoint must include recoveryOptions so the UI can update option rows during polling.",
    )

    print("PASS: Recovery Tools repair-option static contracts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
