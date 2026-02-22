# Changelog

This file is written for everyday users in plain English.
It answers one question: "What changed for me?"

## Public Releases

### 2026.02.21.6 (2026-02-21)

- Raised minimum supported Unraid version to `6.12.0` to match native ZFS availability.
- Updated release metadata/docs accordingly.

### 2026.02.21.4 (2026-02-21)

- Updated official support metadata to use the Unraid forum support thread.
- This completes the support-link requirement expected by Community Applications.

### 2026.02.21.2 (2026-02-21)

- Improved publishing compatibility for plugin catalogs and Community Applications.
- Fixed plugin icon sourcing so the custom icon can resolve consistently outside the settings page.
- Added clearer plugin metadata (description and support link) used by catalog consumers.
- Release artifacts now include a standalone icon file next to the `.plg` and `.txz`.

### 2026.02.20.1 (2026-02-20)

- Fixed the Run Now button failing with "Invalid JSON response" by sending the required Unraid security token on manual-run requests.
- Added clearer Run Now failure messaging when your session expires or security token is rejected.
- Added protection against overlapping manual runs by reporting when a run is already in progress.
- Hardened config parsing in the snapshot engine and scheduler (no direct shell sourcing of config values).
- Added stricter safety checks so unsafe prefix/config values fail fast with plain-English guidance in the Latest Run Summary.
- Improved lock cleanup reliability by merging exit handling into one path.
- Improved low-space cleanup resilience by skipping pools that fail availability checks instead of aborting the whole run.
- Removed obsolete legacy log API code from the settings page backend.
- Improved log refresh change detection reliability in the WebUI.

## Planned For Testing Branch

- Evaluate replacing poll-based log refresh with true streaming log transport (only if stability is maintained).

### 2026.02.19.4 (2026-02-19)

- Added a new "Run Now" button beside Save Settings for one-click manual runs.
- Added a Latest Run Summary view (default): short, one-run results only.
- Added a Debug Log view: verbose technical details.
- Added a "Download Current Log" button that downloads whichever log view is active.
- Latest Run Summary now shows created/deleted totals for each cleanup category and is replaced every run (never appended).

### 2026.02.19.3 (2026-02-19)

- Fixed a low-space cleanup bug that could stop the run early with a sorting/broken-pipe error while deleting old snapshots.

### 2026.02.19.2 (2026-02-19)

- Fixed plugin icon on the Installed Plugins page so it now shows the custom icon instead of the generic one.

### 2026.02.19.1 (2026-02-18)

- Improved reboot reliability: your schedule is now re-applied automatically after startup.

### 2026.02.17.30 (2026-02-18)

- Added automatic log cleanup so the run log keeps only the most recent run history.

### 2026.02.17.29 (2026-02-16)

- Fixed an issue where "Schedule Disabled" might not stay disabled during install/update.

### 2026.02.17.28 (2026-02-16)

- Install/update now applies scheduling immediately, without requiring a manual save.

### 2026.02.17.27 (2026-02-16)

- Changing schedule settings now takes effect right away.

### 2026.02.17.26 (2026-02-16)

- Fixed a fresh-install problem caused by extra metadata files from macOS.

### 2026.02.17.25 (2026-02-16)

- Improved first-time install reliability checks.

### 2026.02.17.24 (2026-02-16)

- Moved "Save Settings" above the live log area for easier use.

### 2026.02.17.23 (2026-02-16)

- Fixed live log viewer errors that showed invalid responses.

### 2026.02.17.22 (2026-02-16)

- Fixed live log refresh issues.
- Removed a non-working extra log button.

### 2026.02.17.21 (2026-02-16)

- Added plugin version display on the settings page.

### 2026.02.17.20 (2026-02-16)

- Made the live log section easier to find on the page.

### 2026.02.17.19 (2026-02-16)

- Added a real-time run log viewer to the WebUI.

### 2026.02.17.18 (2026-02-16)

- Safety text now clearly shows the snapshot prefix you configured.

### 2026.02.17.17 (2026-02-16)

- Installer now applies your schedule automatically.

### 2026.02.17.16 (2026-02-16)

- Fixed scheduled runs not launching because of cron format issues.

### 2026.02.17.15 (2026-02-16)

- Fixed overlap between the Snapshot Prefix field and Dry Run option.

### 2026.02.17.14 (2026-02-16)

- Added "Every N minutes" scheduling.
- Continued improving dataset selection layout.

### 2026.02.17.13 (2026-02-16)

- Improved dataset discovery and pool-based filtering in the selector.

### 2026.02.17.12 (2026-02-16)

- Improved install compatibility and reliability.

### 2026.02.17.11 (2026-02-16)

- Simplified UI placement to a single Utilities entry.

### 2026.02.17.10 (2026-02-16)

- Improved install reliability with an additional package download path.

### 2026.02.17.9 (2026-02-16)

- Fixed package download/verification handling during install.

### 2026.02.17.7 (2026-02-16)

- Re-release used during installer reliability fixes.

### 2026.02.17.6 (2026-02-16)

- Fixed install script path handling.

### 2026.02.17.4 (2026-02-16)

- Reworked settings page registration/layout.

### 2026.02.17.3 (2026-02-16)

- Fixed plugin page visibility and icon compatibility.

### 2026.02.17.2 (2026-02-16)

- Added custom plugin icon.

### 2026.02.17.1 (2026-02-16)

- Fixed settings page tile registration.

### 2026.02.17 (2026-02-16)

- First published release.

## Early Internal Build Labels

These were internal pre-release labels from the first day of development and can be ignored by most users.

### 2026.02.17-verified (2026-02-16)

- Internal pre-release build label.

### 2026.02.17-datasets-ui (2026-02-16)

- Internal pre-release build label.

### 2026.02.16-webui2 (2026-02-16)

- Internal pre-release build label.

### 2026.02.16-webui (2026-02-16)

- Internal pre-release build label.

### 2026.02.16-ui (2026-02-16)

- Internal pre-release build label.

### 2026.02.16 (2026-02-16)

- Initial project scaffold.

## Notes

- Version numbers `2026.02.17.5` and `2026.02.17.8` were skipped (no release published with those numbers).
