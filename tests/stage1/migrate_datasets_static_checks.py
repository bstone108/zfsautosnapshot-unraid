#!/usr/bin/env python3
"""Static contracts for the Dataset Migrator WebGUI page."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
PAGE = ROOT / "source/usr/local/emhttp/plugins/zfs.autosnapshot/php/migrate-datasets.php"
text = PAGE.read_text(encoding="utf-8")


def require(pattern: str, message: str, flags: int = 0) -> None:
    if not re.search(pattern, text, flags):
        raise AssertionError(message)


# The migrator must have a dedicated preview/scan action separate from the
# destructive start action so users can build and review the folder list first.
require(
    r'<button\b[^>]*id="migrate_preview"[^>]*>\s*Preview Migration\s*</button>',
    "Dataset Migrator page must expose an explicit Preview Migration button before Start Migration.",
    re.S,
)
require(
    r'var\s+previewButton\s*=\s*byId\(\'migrate_preview\'\);',
    "Preview button must be wired in JavaScript.",
)
require(
    r'previewButton\.addEventListener\(\'click\'\s*,\s*function\s*\(\)\s*{.*?refreshStatus\(\);.*?}\s*\);',
    "Preview button must trigger a non-destructive status/preview refresh.",
    re.S,
)
require(
    r'renderPageStatus\(\'Previewing top-level folders\.\.\.\'\s*,\s*false\)',
    "Preview action must tell the user it is scanning/building the review list.",
)

# Start remains a distinct POST-only action and must not be the only way to
# populate the preview table.
require(
    r'<button\b[^>]*id="migrate_start"[^>]*>\s*Start Migration\s*</button>',
    "Start Migration button must remain present.",
    re.S,
)
require(
    r'\{action:\s*\'start\'\s*,\s*dataset:\s*dataset\}',
    "Start button must remain the only action that posts the start request.",
)

print("PASS: Dataset Migrator static UI contracts")
