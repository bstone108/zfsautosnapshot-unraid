#!/usr/bin/env python3
"""Static UI contracts for Snapshot Manager queue-aware controls."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PAGE = ROOT / "source/usr/local/emhttp/plugins/zfs.autosnapshot/php/snapshot-manager-page.php"


def assert_contains(text: str, needle: str, message: str) -> None:
    if needle not in text:
        raise AssertionError(message)


def extract_select_all_handler(page: str) -> str:
    marker = "byId('snapshot_manager_select_all').addEventListener('change', function () {"
    start = page.find(marker)
    if start == -1:
        raise AssertionError("Snapshot Manager must define a select-all change handler")
    end_marker = "  });"
    end = page.find(end_marker, start + len(marker))
    if end == -1:
        raise AssertionError("Snapshot Manager select-all handler must be closed")
    return page[start : end + len(end_marker)]


def main() -> int:
    page = PAGE.read_text()
    handler = extract_select_all_handler(page)

    assert_contains(
        page,
        'disabled title="Snapshot deletion is already queued."',
        "pending-delete rows must render disabled selection checkboxes",
    )
    assert_contains(
        handler,
        "if (checkbox.disabled) {",
        "select-all must skip disabled pending-delete checkboxes instead of selecting queued deletes",
    )
    assert_contains(
        handler,
        "delete currentSelection[checkbox.value];",
        "select-all must clear any stale selection state for disabled pending-delete rows",
    )

    print("PASS: Snapshot Manager UI static contracts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
