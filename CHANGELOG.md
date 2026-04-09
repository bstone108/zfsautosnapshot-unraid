# Changelog

This file is written for everyday users in plain English.
It answers one question: "What changed for me?"

## Public Releases

### 2026.04.09.1 (Testing Branch Only)

- Changed the main Save button to a dedicated button-driven save path so custom Unraid themes are less likely to hijack or swallow the form submit event before the plugin can act.
- Kept a protected form-submit fallback for keyboard and no-JavaScript cases, including a noscript submit button.
- The save page now listens on both the button click path and the form submit path, with the button path set up to run early enough to avoid common theme submit races.

### 2026.04.08.2 (Testing Branch Only)

- Fixed a regression in the previous testing build where the hardened wrapped-response parser was too strict and could break log polling even though settings saves were working.
- Log refreshes once again accept normal plugin JSON payloads from the log endpoint while still rejecting obvious wrapped HTML noise.

### 2026.04.08.1 (Testing Branch Only)

- Hardened settings saves so the page now posts directly to the dedicated save endpoint for both AJAX and native form fallbacks instead of relying on Unraid plugin-page POST behavior.
- Broadened CSRF token discovery and tightened wrapped-response parsing so alternate themes or WebGUI wrapper noise are less likely to break Save.
- Increased save-request timeout tolerance on slower systems and added safer redirect handling for native form saves.
- Refactored duplicate save-response helpers into shared code so the JSON and redirect paths stay in sync.

### 2026.04.03.9 (Testing Branch Only)

- Fixed updates again so they can stop a running cleanup job more reliably, including an in-flight snapshot delete and orphaned older `zfs destroy` processes left behind by previous builds.
- Running jobs now receive an explicit stop request before the updater escalates to process termination, which makes upgrades more dependable when cleanup is active.

### 2026.04.03.8 (Testing Branch Only)

- Reduced unnecessary post-delete waiting during low-space cleanup when ZFS `freeing` already shows the pool reclaim is in progress.
- Shortened the fallback recheck wait window for cases where free-space accounting is still ambiguous after delete.

### 2026.04.03.7 (Testing Branch Only)

- Fixed low-space cleanup so the same deleted snapshot is not retried again through an overlapping ancestor/child dataset path.
- This specifically fixes runs that deleted a snapshot once, then immediately tried to delete that exact same snapshot again and failed.

### 2026.04.03.6 (Testing Branch Only)

- Fixed plugin updates again so they now stop the full snapshot-job process tree, including child delete operations, instead of only trying to stop the parent script.
- This is specifically aimed at upgrades where a stuck cleanup run survived because the child `zfs destroy` process kept running after the main script exited.

### 2026.04.03.5 (Testing Branch Only)

- Fixed plugin updates so any running snapshot job is stopped during remove and install steps instead of being left behind after an upgrade.
- Clears stale runtime lock state during update so a crashed or force-stopped run does not block the next scheduled job.

### 2026.04.03.4 (Testing Branch Only)

- Fixed low-space cleanup so snapshots with `used=0` are no longer treated as permanently undeletable when they are part of an older snapshot chain that can still unlock reclaim.
- The plugin now chooses the oldest eligible snapshot chain leader on each helpful dataset instead of getting stuck re-evaluating the same no-immediate-reclaim entries over and over.
- Reduced repeated low-space skip noise so long cleanup runs stay easier to follow.

### 2026.04.03.3 (Testing Branch Only)

- Fixed low-space cleanup so it now chooses snapshots from datasets that can actually improve the dataset that is running low on space.
- If the pool itself is the bottleneck, cleanup can still pull from any configured dataset on that pool.
- If a quota-limited subtree is the bottleneck, cleanup now stays inside that subtree and leaves unrelated datasets alone.

### 2026.04.03.2 (Testing Branch Only)

- Fixed low-space cleanup so one small delete on a shared pool does not stop cleanup just because active writes temporarily hide the reclaimed space.
- The plugin now keeps working across datasets on the same pool until it either reaches the free-space target or runs out of reclaimable auto snapshots.

### 2026.04.03.1 (Testing Branch Only)

- Fixed the Pool free-space target column getting cut off on the right side of the settings page.
- Reduced the target input width so the dataset table fits cleanly across the page.

### 2026.04.01.1 (Testing Branch Only)

- Improved low-space cleanup so the plugin waits briefly for ZFS free-space accounting to catch up after deleting a snapshot.
- This reduces false "delete would not free space" outcomes on systems where reclaim shows up a few seconds late.

### 2026.03.29.2 (Testing Branch Only)

- Fixed the new save compatibility probe after a JavaScript variable was missed in the prior testing release.
- This restores the probe warning logic without breaking the settings page on systems that were otherwise saving normally.

### 2026.03.29.1 (Testing Branch Only)

- Hardened settings saves again so the plugin can recover more gracefully if another plugin or theme adds stray output around save responses.
- Added a save-endpoint compatibility check that can warn when this server appears to be altering plugin responses before you click Save.
- Improved the internal save parser so small amounts of wrapper noise are less likely to break normal save behavior.

### 2026.03.28.1 (Testing Branch Only)

- Forced the dedicated save endpoint into JSON mode so alternate-theme and unusual browser setups no longer depend on request headers to decide between JSON and HTML responses.
- This is aimed at systems where Save reached the right endpoint but still came back as HTML, which made the page report an invalid save response.
- Kept the theme readability and save-feedback improvements from the previous testing builds.

### 2026.03.27.3 (Testing Branch Only)

- Fixed alternate-theme save failures by moving in-page settings saves to a dedicated save endpoint that is less likely to be polluted by WebGUI or theme wrapper output.
- Added stronger save-response handling so the page can report a clearer message when the server returns wrapped HTML instead of clean JSON.
- Kept the theme readability improvements from the prior testing build.

### 2026.03.27.2 (Testing Branch Only)

- Fixed the settings page so saving no longer drops some systems onto a blank-looking page.
- Improved theme compatibility so alternate Unraid themes render the settings UI more reliably instead of mixing unreadable light and dark colors.
- Kept the faster in-page save behavior while restoring normal button recovery and clearer save feedback.

### 2026.03.06.1 (2026-03-06)

- Reduced low-space cleanup log noise so newest-autosnapshot protection is reported once during the initial dataset pass instead of being repeated throughout pool cleanup scans.
- Cleanup behavior is unchanged: the newest autosnapshot still stays protected from automatic deletion.

### 2026.03.02.4 (Testing Branch Only)

- Added safer automatic cleanup so the plugin now protects held or leased snapshots, always keeps the newest autosnapshot for each dataset, and skips deletes that cannot actually reclaim space.
- Added zero-change snapshot housekeeping to remove older duplicate no-change snapshots while keeping the newest autosnapshot in place.
- Improved low-space behavior so the plugin stops instead of churning through deletions when reclaim is blocked.
- Improved the Installed Plugins page with a working custom icon, support link, cleaner description text, and a packaged README for display.
- Removed machine name, username, UID, and timezone details from the debug log while keeping version and pool diagnostics.

### 2026.03.02.3 (Testing Branch Only)

- Fixed Installed Plugins page metadata so the plugin now ships a plain-English description directly in the manifest.
- Added an explicit support-forum link in the plugin manifest for the Installed Plugins page.
- Switched the Installed Plugins page icon reference to the plugin's local web path instead of the remote raw GitHub image URL.

### 2026.03.02.2 (Testing Branch Only)

- New testing release packages now install with proper `root:root` ownership instead of carrying macOS build-machine ownership metadata.
- Moved runtime lock handling out of world-writable `/tmp` and into a protected root-owned runtime directory.
- Hard locked the debug/summary log locations so the plugin no longer trusts custom lock/log path overrides from config edits.
- Tightened log-file safety checks and permissions while keeping the verbose debug information available in the WebUI and downloads.

### 2026.02.21.7 (Testing Branch Only)

- Raised minimum supported Unraid version to `6.12.0` to match native ZFS availability.
- Updated release metadata/docs accordingly.

### 2026.02.21.5 (Testing Branch Only)

- Updated plugin support metadata to use the official Unraid forum support thread.
- This improves Community Applications support-link compliance for the testing branch.

### 2026.02.21.3 (Testing Branch Only)

- Added Community Applications publishing metadata improvements to the testing branch.
- Fixed plugin icon publishing path so plugin catalogs can load the custom icon reliably.
- Testing release artifacts now include a standalone icon file in `dist/`.
- Added explicit support URL metadata in the plugin manifest.

### 2026.02.21.1 (Testing Branch Only)

- Fixed a run-stopping bug where internal ZFS delete failures could end the run without clear guidance.
- Snapshot delete failures now stop cleanly with plain-English "what happened" and "what to do next" in the Latest Run Summary.
- Added richer debug run details (plugin version, Unraid version, ZFS versions, kernel, host/user info, and pool health overview).
- Changed log download behavior: one click now exports both logs together (Debug Log + Latest Run Summary) in a single text file.

### 2026.02.20.3 (Testing Branch Only)

- Added a snapshot-delete watchdog: if a single delete runs longer than 2 minutes, the run exits so the next scheduled run can retry.
- Intended to prevent a single hung deletion from blocking future scheduled runs.

### 2026.02.20.2 (Testing Branch Only)

- First testing-branch experiment: live log streaming transport (with automatic fallback to refresh mode if streaming fails).
- No merge to main from this build without explicit approval.

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
