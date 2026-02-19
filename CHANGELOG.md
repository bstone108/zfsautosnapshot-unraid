# Changelog

All notable changes to this project are documented in this file.

This changelog was backfilled from commit history and release artifacts on 2026-02-19.

## Released Versions

### 2026.02.19.1 (2026-02-18)

- Boot reliability fix: cron schedule is now auto-synced on startup/array mount via `event/disks_mounted`.
- Commit: `315756d`

### 2026.02.17.30 (2026-02-18)

- Log retention improvement: each run writes a `[RUN_START]` marker and prunes the log to keep only the latest 2 runs.
- Commit: `ccd81b0`

### 2026.02.17.29 (2026-02-16)

- Protected disabled schedule state during install/upgrade.
- Commit: `eb7b166`

### 2026.02.17.28 (2026-02-16)

- Install/upgrade now refreshes cron runtime so existing schedules activate without a manual Save.
- Commit: `5d4e854`

### 2026.02.17.27 (2026-02-16)

- Schedule apply/disable now restarts `crond` to ensure changes take effect immediately.
- Commit: `d9f4bbf`

### 2026.02.17.26 (2026-02-16)

- Fixed AppleDouble/macOS metadata pollution on fresh installs.
- Commit: `f448d27`

### 2026.02.17.25 (2026-02-16)

- Hardened fresh-install package registration checks.
- Commit: `8572759`

### 2026.02.17.24 (2026-02-16)

- Moved Save Settings button above the live log viewer.
- Commit: `0c15357`

### 2026.02.17.23 (2026-02-16)

- Fixed live-log invalid JSON by introducing a dedicated endpoint.
- Commit: `8131210`

### 2026.02.17.22 (2026-02-16)

- Fixed live-log polling path/transport.
- Removed the extra non-working log button.
- Commit: `32a7cba`

### 2026.02.17.21 (2026-02-16)

- Added installed version display on the settings page.
- Commit: `49ab5f7`

### 2026.02.17.20 (2026-02-16)

- Improved live log visibility/placement under Dry Run.
- Commit: `7e0c0cb`

### 2026.02.17.19 (2026-02-16)

- Added real-time dry-run/live run log viewer in the WebUI.
- Commit: `7b645c8`

### 2026.02.17.18 (2026-02-16)

- Safety helper text now shows the configured snapshot prefix value.
- Commit: `29cb6a6`

### 2026.02.17.17 (2026-02-16)

- Forced cron sync during plugin install.
- Commit: `cadeec2`

### 2026.02.17.16 (2026-02-16)

- Fixed generated cron format for Unraid BusyBox `/etc/cron.d`.
- Commit: `8004115`

### 2026.02.17.15 (2026-02-16)

- Fixed overlap of Snapshot Prefix and Dry Run controls by moving Dry Run below prefix.
- Commit: `b7985f8`

### 2026.02.17.14 (2026-02-16)

- Added every-N-minutes schedule mode.
- Continued dataset UI improvements with pool filtering.
- Commit: `8b674e6`

### 2026.02.17.13 (2026-02-16)

- Improved dataset discovery and pool-filtered dataset picker.
- Commit: `c5e387b`

### 2026.02.17.12 (2026-02-16)

- Switched install/remove runtime blocks to explicit `<INLINE>` execution for plugin manager compatibility.
- Commit: `a6d3aad`

### 2026.02.17.11 (2026-02-16)

- Simplified UI registration to a single Utilities page.
- Commit: `74e03a2`

### 2026.02.17.10 (2026-02-16)

- Added direct package download fallback in installer.
- Commit: `70b1723`

### 2026.02.17.9 (2026-02-16)

- Fixed plugin `<FILE>` payload schema to use explicit `URL`/`MD5` nodes.
- Commit: `8cf6e9a`

### 2026.02.17.7 (2026-02-16)

- Forced reinstall release bump during installer debugging.
- Commit: `e26aa81`

### 2026.02.17.6 (2026-02-16)

- Fixed install script paths by removing unresolved XML entities in runtime scripts.
- Commit: `c225e19`

### 2026.02.17.4 (2026-02-16)

- Reworked UI registration to xmenu + child settings page (later simplified in subsequent releases).
- Commit: `10f86ee`

### 2026.02.17.3 (2026-02-16)

- Fixed Unraid page registration and icon compatibility.
- Commit: `048ce3b`

### 2026.02.17.2 (2026-02-16)

- Added custom plugin icon.
- Commit: `d58a9a9`

### 2026.02.17.1 (2026-02-16)

- Fixed settings page tile registration.
- Commit: `d64796d`

### 2026.02.17 (2026-02-16)

- First public release packaging and GitHub publish prep.
- Commit: `969613f`

## Historical Internal Build Labels

These labels appeared in early `dist` artifacts during rapid initial development and are kept here for traceability.

### 2026.02.17-verified (2026-02-16)

- Internal scaffold-era build label.
- Commit: `d4fad38`

### 2026.02.17-datasets-ui (2026-02-16)

- Internal scaffold-era build label.
- Commit: `d4fad38`

### 2026.02.16-webui2 (2026-02-16)

- Internal scaffold-era build label.
- Commit: `d4fad38`

### 2026.02.16-webui (2026-02-16)

- Internal scaffold-era build label.
- Commit: `d4fad38`

### 2026.02.16-ui (2026-02-16)

- Internal scaffold-era build label.
- Commit: `d4fad38`

### 2026.02.16 (2026-02-16)

- Initial Unraid ZFS autosnapshot plugin scaffold.
- Commit: `d4fad38`

## Notes

- Version numbers `2026.02.17.5` and `2026.02.17.8` were skipped and have no corresponding release artifacts in repository history.
