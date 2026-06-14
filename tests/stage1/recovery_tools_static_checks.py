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
        page,
        r'cleanCandidates.*?local snapshot.*?ZFS send destination',
        "Recovery option rows must render readable local snapshot and ZFS send destination candidates when discovery finds them.",
        re.S,
    )
    require(
        page,
        r'function\s+performRecoveryAction\s*\(.*?confirmation.*?perform_recovery_action',
        "Recovery Tools UI must submit guarded recovery actions only through an explicit confirmation flow.",
        re.S,
    )
    require(
        page,
        r'restore_clean_copy.*?candidate\.sha256',
        "Recovery Tools UI must identify selected clean-copy candidates by discovered sha256 when requesting restore.",
        re.S,
    )
    require(
        helpers,
        r'function\s+zfsas_recovery_perform_guarded_action\s*\(',
        "Recovery helpers must expose a guarded backend action dispatcher for confirmed repair actions.",
    )
    require(
        helpers,
        r'READ.*?RESTORE.*?DELETE',
        "Guarded recovery actions must require explicit action-specific confirmation tokens.",
        re.S,
    )
    require(
        helpers,
        r'cleanCandidates.*?candidateSha256',
        "Clean-copy restore must validate the selected candidate against discovered candidates for the affected file.",
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
        r"'recoveryOptions'\s*=>\s*zfsas_recovery_option_candidates\(\$poolStatus\s*,\s*\$scans\s*,\s*\$datasets",
        "Recovery status endpoint must reuse the already-loaded dataset list when building recoveryOptions so every poll does not run an extra zfs list.",
    )
    require(
        page,
        r'function\s+renderDatasetOptions\s*\(.*?document\.activeElement\s*===\s*select.*?return;',
        "Polling refresh must not rebuild the manual diagnostic dataset selector while the user is actively selecting a dataset.",
        re.S,
    )
    require(
        page,
        r'setInterval\(loadStatus,\s*(?:[3-9]\d{4}|\d{6,})\)',
        "Recovery Tools status polling must not rerun expensive snapshot discovery every 5 seconds.",
    )
    require(
        page,
        r'function\s+clearRecoveryScan\s*\(.*?action:\s*[\'\"]clear_scan[\'\"].*?loadStatus\s*\(',
        "Manual diagnostic scan rows must have a UI action that clears stale scan entries and refreshes the list.",
        re.S,
    )
    require(
        page,
        r'zfsas-clear-scan.*?data-dataset.*?scan\.dataset',
        "Manual diagnostic scan rows must render a per-scan Clear button tied to the scan dataset.",
        re.S,
    )
    require(
        page,
        r"state\s*===\s*'queued'.*?state\s*===\s*'running'.*?zfsas-clear-scan",
        "Clear buttons must be disabled while a diagnostic scan is queued or running.",
        re.S,
    )
    require(
        page,
        r'<th>Actions</th>',
        "Manual diagnostic scan table must include an Actions column for clearing stale scans.",
    )
    require(
        helpers,
        r'function\s+zfsas_recovery_clear_scan\s*\(.*?\[\'queued\'\s*,\s*\'running\'\].*?unlink\(\$resultsFile\).*?unlink\(\$statusPath\)',
        "Recovery helpers must clear terminal manual diagnostic scan status/results but reject queued/running scans.",
        re.S,
    )
    require(
        PAGE.with_name("recovery-action.php").read_text(encoding="utf-8"),
        r"\$action\s*===\s*'clear_scan'.*?zfsas_recovery_clear_scan",
        "Recovery action endpoint must expose the clear_scan action through the guarded POST endpoint.",
        re.S,
    )

    print("PASS: Recovery Tools repair-option static contracts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
