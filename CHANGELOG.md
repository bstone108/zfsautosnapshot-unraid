# Changelog

This file is written for everyday users in plain English.
It answers one question: "What changed for me?"

## Public Releases

### 2026.04.16.13 (Testing Branch Only)

- Fixed post-send checkpoint cleanup so `ZFS Send` no longer deletes the previous send checkpoint from the destination after a successful replication. Destination-side send checkpoints now stay available there until the normal send retention policy or low-space cleanup decides they can go.
- Fixed source-side checkpoint cleanup so after a new send snapshot has been verified on the destination, the source tree now removes every older checkpoint in that send chain instead of only trying to remove the single immediately previous one and leaving older leftovers behind forever.

### 2026.04.16.12 (Testing Branch Only)

- Changed recursive `ZFS Send` fan-out so the actual child send items now queue only the transfer work, and each child send queues its own zero-change cleanup at the end instead of creating a separate cleanup queue row that just clogs the send queue.
- Fixed scheduled `ZFS Send` timing so completed schedule windows are now remembered outside the short-lived queue rows, and automatic jobs only queue once per real local schedule window instead of being re-added every time the kicker wakes up after the old success rows auto-expire.
- Aligned scheduled `ZFS Send` windows to local wall-clock boundaries, so `6h`, `12h`, and `1d` jobs now line up with the expected local hour and midnight boundaries instead of drifting off raw UTC math.

### 2026.04.16.11 (Testing Branch Only)

- Fixed a `ZFS Send` worker bug that could overwrite the real send failure with the generic `snapshot_created` error message and make bad queue items look like they were looping in the wrong phase.
- Added a `Cancel` control to active `ZFS Send` queue items so stuck queued, waiting, or running send jobs can be stopped and left behind as a canceled queue row until you confirm-clear them.

### 2026.04.16.10 (Testing Branch Only)

- Fixed legacy completed or skipped queue items so old jobs created before the auto-expire change are now purged out of the send queue instead of lingering in the GUI forever when they are no longer runnable.

### 2026.04.16.09 (Testing Branch Only)

- Fixed several `ZFS Send` queue bugs that could stop scheduled replication from enqueuing at the right time or could prune the wrong job history, and tightened the worker pipeline handling so queued send work now runs with safer validation and lock cleanup.
- Hardened the new feature pages and workers with shared dataset-name validation, safer shell quoting, tighter CSRF/file-permission handling, atomic cron/log writes, and better guardrails around snapshot actions, recovery scans, and irreversible rollback paths.

### 2026.04.16.08 (Testing Branch Only)

- Reworked scheduled `ZFS Send` prep so it now runs as its own pool-scoped stage, queues retention and low-space snapshot deletions first, waits for that pool's delete queue to drain, and only then fans the actual send work back out into parallel transfer jobs.
- Changed scheduled `ZFS Send` low-space planning so it now estimates reclaim from the snapshots it queues for deletion and can pull cleanup candidates from all `ZFS Send`-managed destination datasets on the same pool, instead of only the dataset tree belonging to the one schedule item that happened to start prep.

### 2026.04.16.07 (Testing Branch Only)

- Reworked recursive `ZFS Send` queue handling so after the initial scheduled-send prep finishes, child datasets now fan out into their own top-down queue items for the actual transfer work and their own follow-up zero-change cleanup steps instead of appearing as one giant queue row.
- Changed successful queued send and cleanup items to disappear automatically about `5` seconds after completion, while unrecoverable failed send items now stay visible with both `Retry` and `Confirm Clear` controls so you can decide when to remove them from the queue.

### 2026.04.16.06 (Testing Branch Only)

- Removed `ZFS Send` schedule options shorter than `6` hours so the scheduler now only offers `6h`, `12h`, `1d`, and `7d`, which better matches how long real replication runs can take.
- Added compatibility handling so older saved `ZFS Send` jobs that were set to `15m`, `30m`, or `1h` are automatically upgraded to `6h` instead of being dropped outright.

### 2026.04.16.05 (Testing Branch Only)

- Hardened the `Dataset Migrator` folder-to-container mapping so it now canonicalizes Docker mount source paths and keeps migration batching strictly confined to the selected dataset root, preventing containers with other host paths from pulling unrelated locations into the migration plan.

### 2026.04.16.04 (Testing Branch Only)

- Reworked the `Dataset Migrator` container handling so it no longer drops every running container at once. It now stops only the containers tied to the current migration batch, migrates all related top-level folders those containers share inside the selected dataset, and then starts those containers back up before moving on.
- Added dependency-aware batch ordering to the `Dataset Migrator` so shared service groups are handled in one pass when possible, reducing unnecessary stop/start churn while still keeping dependent containers down only for the folder groups they actually need.

### 2026.04.16.03 (Testing Branch Only)

- Reworked the `Special Features` and `Repair Tools` sections so each tool now shows as a button on the left with its description beside it, making the tool pages easier to scan and leaving more room for additional entries later.

### 2026.04.16.02 (Testing Branch Only)

- Fixed the `Dataset Migrator` start path so it no longer reruns the full folder-size preview before launching the worker, and so it now waits for the worker to report real startup status instead of claiming success before anything has actually begun.
- Reduced unnecessary `Dataset Migrator` refresh work by skipping the expensive preview rescan while the currently selected dataset is already the one being migrated in the background.

### 2026.04.16.01 (Testing Branch Only)

- Fixed the main settings page load path after the recent `ZFS Send` work by restoring the correct initialization order for dataset parsing and send reservation calculations, and by switching the page to the shared `ZFS Send` defaults so the main plugin page can boot cleanly again.

### 2026.04.15.9 (Testing Branch Only)

- Added `ZFS Send` retention settings so the send tool can queue destination snapshot deletions using the same keep-all, then daily, then weekly style policy before a scheduled send and again as a zero-change cleanup pass afterward, while always preserving the newest successful send checkpoint needed for the next incremental replication.
- Added a live pending-delete count next to the `ZFS Send` queue header so you can see when retention and other background snapshot deletions have been queued for later processing.
- Changed regular autosnapshot cleanup coordination so if any `ZFS Send` job is active, the autosnapshot run now skips all cleanup phases for that pass and only creates new snapshots, avoiding cross-dataset cleanup decisions while send work is still in progress.

### 2026.04.15.8 (Testing Branch Only)

- Changed scheduled `ZFS Send` destination cleanup so its free-space target can now delete the oldest eligible destination snapshots of any type inside the configured send targets, while still protecting the newest successful send checkpoint and any checkpoint basenames that queued or running sends still need.
- Added runner coordination between the two shell engines so `ZFS Send` now waits for an in-progress autosnapshot run to finish before starting, and the regular autosnapshot cleanup phases now skip datasets that are actively being sent while still allowing the normal snapshot-creation phase to continue.

### 2026.04.15.7 (Testing Branch Only)

- Added a new `Dataset Migrator` under `Special Features` that can convert top-level folders inside a selected dataset into child datasets with live folder-by-folder progress, free-space wait messaging, paranoid verification, rollback if a folder copy fails, and automatic stop/restart handling for Docker containers that were running before the migration started.

### 2026.04.15.6 (Testing Branch Only)

- Fixed the main autosnapshot dataset picker so `ZFS Send` reservations now lock only the actual destination datasets in use, plus child datasets under a recursive send target, instead of falsely locking the whole destination pool or unrelated siblings.

### 2026.04.15.5 (Testing Branch Only)

- Widened the main settings container and let the embedded `Snapshot Manager` frame use the full width of its card so the right side is less likely to get clipped on wide dataset/action layouts.

### 2026.04.15.4 (Testing Branch Only)

- Fixed the packaged file modes for the new queue-processing binaries so the `ZFS Send` queue kicker and workers install as executable files, and added an install-time permission repair step to restore execute bits on upgraded systems.

### 2026.04.15.3 (Testing Branch Only)

- Fixed the `ZFS Send` scheduler save validation so the empty “Add Job” row no longer gets treated as a real new job just because its frequency, children, and threshold controls have default values.

### 2026.04.15.2 (Testing Branch Only)

- Injected Unraid's CSRF token into the standalone `ZFS Send`, `Snapshot Manager`, and `Recovery Tools` pages so their existing button and AJAX code can send valid CSRF-protected requests instead of failing before PHP runs.

### 2026.04.15.1 (Testing Branch Only)

- Reissued the latest testing build under a new date-based version because some Unraid updater paths appear to sort `2026.04.14.10` as if it were older than `2026.04.14.9`, even though the manifest itself was correct.
- Carries forward the `ZFS Send` dedicated save-handler fix from `2026.04.14.10` without additional code changes.

### 2026.04.14.10 (Testing Branch Only)

- Reworked the `ZFS Send` save flow so `save-send-settings.php` now performs the save directly instead of including the full `send-settings.php` page file, which should eliminate the strange bare `1` response seen on some Unraid systems.

### 2026.04.14.9 (Testing Branch Only)

- Changed the `ZFS Send` save button to post its AJAX request directly back to `send-settings.php`, which bypasses the flaky dedicated save route that was still returning a bare `1` on some systems instead of the marked JSON response the page expects.

### 2026.04.14.8 (Testing Branch Only)

- Fixed a JavaScript regression on the `ZFS Send` page where the queue/status loader was calling a missing `requestJson()` helper, which caused the page script to throw during startup instead of running cleanly.

### 2026.04.14.7 (Testing Branch Only)

- Replaced the `ZFS Send` save endpoint with a real dedicated save handler instead of the old thin include wrapper, which should stop the send settings button from falling back into a full HTML page response and throwing `Invalid save response`.

### 2026.04.14.6 (Testing Branch Only)

- Fixed the embedded `Snapshot Manager` drawer so it stays hidden until you actually click `Manage Snapshots`, and the close button now reliably hides the drawer again even on theme-customized systems.
- Fixed the `Recovery Tools` dataset selector so the automatic refresh no longer wipes out the dataset you just picked before you can start a scan.

### 2026.04.14.5 (Testing Branch Only)

- Moved `Snapshot Manager` back directly into the `Snapshot Manager` tab so it opens in place instead of sending you off to a separate page, while still lazy-loading the heavy manager UI only when you actually switch to that tab.
- Hardened the `ZFS Send` settings save flow so it uses the same broader CSRF detection and wrapped-response parsing style as the main settings page, which makes custom theme interference less likely to show up as an invalid save response.

### 2026.04.14.4 (Testing Branch Only)

- Reworked scheduled `ZFS Send` into a persistent queue with retry handling, minute-based queue kicking, configurable parallel send workers, child-dataset replication support, and a shared job/status view on the send page.
- Moved `Snapshot Manager` onto its own dedicated page so the main settings stay light, added dataset-level summary rows with last snapshot time and active send progress, and kept snapshot lists lazy-loaded until you explicitly manage a dataset.
- Routed manual snapshot deletes through the same central queue as send jobs, hid already queued deletions from the live snapshot list, and matched queued deletions by stable snapshot identity instead of display order.
- Added the first real `Recovery Tools` page with scrub/corruption visibility plus a GUI-driven manual readability scan for cases where scrub detects damage but cannot map it back to a specific file.

### 2026.04.14.3 (Testing Branch Only)

- Added a new `Snapshot Manager` section with a dataset summary view, snapshot counts, pending-operation status, and a slide-over snapshot drawer for manual ZFS snapshot work.
- Added queued manual snapshot actions so bulk delete, hold, and release work one dataset at a time without blocking other datasets, while rollback and one-off send actions start immediately when the selected dataset is idle.
- Added protection for ZFS send checkpoints inside Snapshot Manager so the dedicated replication snapshot chain is not accidentally broken by manual delete or rollback actions.

### 2026.04.14.2 (Testing Branch Only)

- Added the first real `Special Features` tool: a dedicated `ZFS Send` page with its own config, manual run button, and scheduled replication jobs.
- ZFS send jobs now use their own send-only snapshot chain, keep only the newest successful send snapshot per job, and can clean older send checkpoints off the destination side when free space gets tight.
- Destination pools used by ZFS send are now reserved on the main page so regular autosnapshot management cannot be enabled there by mistake.

### 2026.04.14.1 (Testing Branch Only)

- Added a section switcher above the Datasets area so the settings page now has dedicated tabs for `Main Page`, `Special Features`, and `Repair Tools`.
- Left the `Special Features` and `Repair Tools` tabs as clear placeholders for future planned tools while keeping the full existing settings UI under `Main Page`.

### 2026.04.11.4 (Testing Branch Only)

- Adjusted the inline save-error layout so the fixed-width error slot now sits to the left of both action buttons instead of only to the left of Save.

### 2026.04.11.3 (Testing Branch Only)

- Changed the save confirmation again so the Save button itself now switches to `Saved` for a few seconds after a successful save.
- Save errors now appear in a fixed inline slot just to the left of the Save button instead of at the top of the page, so failures stay visible without shifting the button around.

### 2026.04.11.2 (Testing Branch Only)

- Moved the successful save confirmation out of the large page banner and into a small inline status beside the Save button.
- The inline success checkmark clears itself after a few seconds, while real save errors still stay visible at the top of the page.

### 2026.04.11.1 (Testing Branch Only)

- Fixed the dedicated save endpoint so its marked response is no longer mislabeled as plain JSON, which avoids noisy browser JSON-parse complaints in DevTools while keeping the wrapped-response protection in place.

### 2026.04.10.1 (Testing Branch Only)

- Fixed install and upgrade behavior so the plugin now repairs the ownership and permissions of its boot-side config directory and config file before the WebGUI tries to save settings.
- Added a release-package verification step that fails the build if any file from `source/` is missing from the generated `.txz`.
- Added GitHub Actions release builds for the `testing` and `main` branches so published plugin artifacts no longer depend on a local manual packaging step.

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
