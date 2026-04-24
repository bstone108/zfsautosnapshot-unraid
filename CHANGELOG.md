# Changelog

This file is written for everyday users in plain English.
It answers one question: "What changed for me?"

## Public Releases

### 2026.04.24.10 (Testing Branch Only)

- Fixed `ZFS Send` preflight dispatch so jobs that already finished snapshot/space preparation and are waiting for a send slot no longer block fresh queued children from preparing.
- Fixed `ZFS Send` transfer-slot accounting so a job stays counted as active through verification, source checkpoint cleanup, and zero-change cleanup queueing instead of freeing a slot immediately after receive finishes.

### 2026.04.24.09 (Testing Branch Only)

- Changed the `ZFS Send` queue kicker so it only schedules work and starts a live queue handler; the handler now keeps launching send/delete workers in near real time until the queue drains instead of waiting for the next one-minute kicker pass.
- Let extra `ZFS Send` workers keep preparing snapshots and estimating destination space ahead of the configured transfer limit, while actual send transfers still obey the parallel send setting and destination-space reservations.
- Simplified `ZFS Send` queue source/destination display so each row shows the dataset name with the full path available on hover.

### 2026.04.24.08 (Testing Branch Only)

- Fixed `ZFS Send` queue streaming so newly fanned-out child jobs appear without manually refreshing the page, with stream heartbeat/reconnect handling and polling fallback still available.
- Changed the `ZFS Send` queue progress column so it only shows an active progress bar during the real send stage, while keeping the column width stable during preparation, waiting, verification, and cleanup.
- Added byte-based `ZFS Send` progress updates when the platform supports `dd status=progress`, and allowed extra send workers to prepare snapshots and calculate space needs without increasing the configured number of actual parallel transfers.
- Fixed autosnapshot runs so configured datasets that were deleted are skipped and reported instead of causing the whole run to fail.

### 2026.04.24.07 (Testing Branch Only)

- Added a `Step` column to the `ZFS Send` queue so active rows show progress through the normal job flow as values like `3/7`.
- Added live queue updates using browser Server-Sent Events, with the existing polling endpoint kept as a fallback if streaming is unavailable.
- Improved active queue progress bars with a subtle moving fill while work is in progress, and changed long source/destination paths to truncate from the beginning so the dataset name at the end stays visible.

### 2026.04.24.06 (Testing Branch Only)

- Cleaned up `ZFS Send` queue status text so rows show short, accurate messages like waiting for space, calculating needed space, sending, verifying, or cleaning up instead of long noisy internal details.
- Changed the `ZFS Send` queue table to keep each queue item on one line with ellipsis and hover text for the full raw message, preventing the queue from constantly expanding and contracting while jobs run.
- Fixed the send-worker launch race so the configured parallel worker limit is reserved before spawning workers, preventing multiple queue kickers from overlaunching sends.

### 2026.04.24.05 (Testing Branch Only)

- Fixed `ZFS Send` source checkpoint pruning so a failed send can no longer cause the last known-good common checkpoint to be deleted before a newer checkpoint is verified on the destination.
- Strengthened retention, low-space cleanup, and delete-worker guards so the latest common scheduled-send checkpoint is protected per dataset member, including partial recursive sends where some children failed.
- Let extra send workers preflight snapshots and estimate required destination space ahead of the normal transfer limit, while actual sends still wait for safe FIFO space reservation and transfer slots.

### 2026.04.24.04 (Testing Branch Only)

- Changed completed destination-pool prep rows in the `ZFS Send` queue so they disappear from the WebUI immediately instead of hanging around while dependent child sends finish.
- Added cleanup for completed pool-prep marker files: they are kept only while queued, running, or retry-wait send jobs still reference that prep run, then removed automatically so old markers cannot interfere with future runs.

### 2026.04.24.03 (Testing Branch Only)

- Changed scheduled `ZFS Send` prep so each destination pool now gets one shared prep stage for managed send targets instead of every due job running its own retention and low-space cleanup pass.
- Added destination-pool space reservations for `ZFS Send` workers so parallel sends cannot accidentally claim the same free space at the same time; workers now wait in safe FIFO order per destination pool before starting the actual send.
- Fixed a send-worker crash that could repeatedly recover the same queued jobs with a `JOB_ACTION: unbound variable` error while trying to fan out child send jobs.
- Added a `Download Log` action to queued, running, and retry-wait send rows so logs are available while a job is looping or recovering, not only after it reaches final failed state.

### 2026.04.24.02 (Testing Branch Only)

- Sped up `ZFS Send` recursive prep by caching destination dataset lists, protected send checkpoint names, and snapshot cleanup bookkeeping during each worker pass.
- Sped up recursive child-job fan-out by avoiding a full send-queue scan for every child job and writing generated child jobs in a fixed key order.
- Added send-worker timing log lines for retention planning, low-space planning, and child-job fan-out so future slow prep stages are easier to pinpoint.

### 2026.04.24.01 (Testing Branch Only)

- Marked `Dataset Migrator` as feature-stable and removed its unfinished preview warning from the plugin UI while leaving the unfinished warnings in place for `Recovery Tools` and `Snapshot Manager`.
- Fixed a logging-permissions bug that could wrongly change `/var/log` itself to `nobody:users` with group-writable permissions while preparing plugin log files.
- Added an upgrade-time repair step so affected systems reset `/var/log` back to the expected `root:root` ownership and `0755` mode during plugin install or upgrade.

### 2026.04.18.02

- Promoted the current testing stack toward general release with clearer guardrails around what is ready now versus what is still preview-only.
- Marked `Dataset Migrator`, `Recovery Tools`, and `Snapshot Manager` more explicitly as unfinished preview tools that may not work correctly yet, while keeping `ZFS Send` presented as the finished feature in this release.
- Kept the newer logging improvements from `2026.04.18.01`, including condensed archived history, sanitized log output, and RAM-backed runtime logs for the more verbose recovery and migration tooling.

### 2026.04.18.01 (Testing Branch Only)

- Reworked plugin logging so the main autosnapshot log, shared `ZFS Send` log, Snapshot Manager log, Recovery scan logs, and Dataset Migrator log now keep a detailed current window plus a condensed archived history instead of just growing forever or being bluntly thrown away.
- Moved the Recovery scan and Dataset Migrator runtime logs out of the plugin config folder and into RAM-backed `/var/log`, which keeps busy diagnostic logging off the Unraid flash device while still letting the UI read the current log cleanly.
- Improved `ZFS Send` delete-daemon logging so failures still log in detail, but large successful delete backlogs now report periodic progress instead of spamming one success line per snapshot.
- Expanded log downloads so the autosnapshot export now includes the archived debug log, and the shared send log download includes the archived send log when there is no preserved per-failed-job log available.
- Added sanitize-by-default shell log output for obvious secret-like fields such as passwords, tokens, secrets, API keys, bearer tokens, and similar key-value credentials, even though the plugin is not expected to log sensitive material during normal operation.

### 2026.04.17.09 (Testing Branch Only)

- Fixed a `ZFS Send` delete-queue restart bug on upgraded systems where the queue kicker could miss a real backlog if the runtime delete state file was still in the older legacy `JOB` format. Upgraded boxes now recognize that legacy file as real pending work, start the delete daemon, and let the new worker import it into the lighter in-memory runtime model automatically.

### 2026.04.17.08 (Testing Branch Only)

- Reworked the runtime `ZFS Send` delete queue so it no longer rewrites the full live queue snapshot during normal operation. The delete daemon now keeps the real queue in memory, writes only a tiny runtime status file for the WebUI, and only serializes the full backlog during controlled shutdown, reboot, or upgrade handoff.
- Added one-time import of the older job-style runtime delete state on startup so an upgraded box can reingest an existing backlog, throw away the old heavy state file, and continue draining deletes under the lighter in-memory model.
- Simplified per-item delete handling again so the worker only sanity-checks that a queued target still looks like a snapshot path before calling `zfs destroy`, instead of doing another exact preflight lookup for every delete.

### 2026.04.17.07 (Testing Branch Only)

- Simplified the `ZFS Send` delete worker so it no longer re-reads full snapshot identity metadata before every queued delete. It now only checks that the target is still an exact snapshot path, runs `zfs destroy`, retries a couple of times on transient errors, and then logs and drops that queue item if the delete still fails.
- This should remove a big chunk of the per-item pre-delete overhead on slow pools while still keeping the worker from ever turning a queued snapshot delete into a whole-dataset destroy.

### 2026.04.17.06 (Testing Branch Only)

- Changed the `ZFS Send` delete daemon to process the runtime cleanup queue in plain arrival order instead of rescanning the full backlog looking for the smallest sort key on every pass, which should stop large pending-delete queues from wasting time on queue-order bookkeeping instead of actual snapshot destruction.
- Changed delayed delete retries so blocked snapshots are pushed to the tail of the runtime queue, and added explicit “Deleting snapshot …” log lines before each destroy step so it is finally obvious in the log whether the daemon is actively deleting a snapshot or still stuck in queue management.

### 2026.04.17.05 (Testing Branch Only)

- Fixed a `ZFS Send` delete-queue slowdown where the runtime delete daemon could spend most of its time rewriting the large live queue state file after every processed snapshot, making it look like the queue kicker was not starting work even though a delete worker was already running.
- Changed the runtime delete daemon to batch those live state-file flushes on an interval instead of forcing a full rewrite after every single delete transition, so large pending-delete backlogs can drain normally again.

### 2026.04.17.04 (Testing Branch Only)

- Changed the new runtime `ZFS Send` delete queue so planned shutdowns, reboots, and upgrades now flush the in-memory delete backlog into persistent plugin storage under `/boot/config/plugins/zfs.autosnapshot/runtime_queue`, and the next start reingests that saved backlog and clears the persisted file automatically.
- Updated queue visibility and duplicate checks so the WebUI and queue logic can still see a persisted delete backlog before the runtime daemon has reloaded it, which keeps pending-delete counts and delete protection consistent across those controlled restarts.

### 2026.04.17.03 (Testing Branch Only)

- Fixed queue startup and runtime behavior so `ZFS Send` and delete workers now stay paused while Unraid reports the array as stopped, stopping, starting, or otherwise not actionable, instead of trying early ZFS operations that just fail and recover on retry during boot or shutdown transitions.
- Clarified the new runtime cleanup queue model by keeping due work enqueueing intact while the array is paused, but preventing the queue kicker from launching workers until the array is actually ready to process snapshot sends and deletions.

### 2026.04.17.02 (Testing Branch Only)

- Fixed a `ZFS Send` delete-daemon crash where the new runtime cleanup worker could die immediately with `job_id: unbound variable` before it started processing queued snapshot deletions, leaving large pending-delete counts stuck even though the send jobs themselves had finished normally.

### 2026.04.17.01 (Testing Branch Only)

- Replaced the old one-file-per-delete `ZFS Send` cleanup queue with a runtime delete daemon that keeps active delete work in memory, rebuilds from one lightweight runtime state snapshot when needed, and ingests new cleanup work through a single temp inbox instead of creating thousands of separate queue files.
- Changed send-side retention, zero-change cleanup, low-space cleanup, and Snapshot Manager delete requests to feed that new delete daemon backend, which should stop huge cleanup passes from collapsing under tens of thousands of tiny queue files while still preserving the same delete protections and duplicate suppression.
- Updated the WebUI queue helpers so pending-delete counts and Snapshot Manager “already queued” hiding now read the new runtime delete-daemon state and its intake buffer, instead of depending on old per-delete job files to exist.

### 2026.04.16.20 (Testing Branch Only)

- Moved the hot `ZFS Send` queue out of `/boot` and into temp runtime storage so queue churn, retries, and bulk cleanup planning no longer hammer the Unraid flash device with thousands of tiny writes.
- Changed scheduled send recovery so the durable state on `/boot` now stays minimal: it remembers the last fully completed schedule window, while interrupted child-send fan-outs are rebuilt after reboot by inspecting current-window send snapshots on the destination and only queueing the child datasets that are still missing.
- Added upgrade cleanup that purges the old on-boot send queue files so stale pre-migration queue entries cannot survive this storage move and confuse the new runtime-only queue.

### 2026.04.16.19 (Testing Branch Only)

- Fixed a `ZFS Send` scheduler bug where the queue kicker could crash with an `unbound variable` error while building a scheduled send job id, which could stall scheduled enqueueing even though the active send worker kept running.

### 2026.04.16.18 (Testing Branch Only)

- Fixed a `ZFS Send` queue write race where worker startup could delete another process's in-flight `.tmp` job file, which could corrupt child queue items, strip their action fields, and cause repeated blank-action retries.
- Fixed recursive `ZFS Send` source checkpoint cleanup so each child dataset now deletes its older source-side send checkpoints only after that exact child checkpoint has been verified on the destination, instead of advancing the whole source tree and breaking lagging children like `foundryvtt`.
- Added automatic recovery for the broken-chain backup case: if a scheduled child send finds no common checkpoint but the destination dataset still has snapshots, the worker now preserves the log, purges that destination dataset for a clean reseed, and fails the current attempt so the normal retry path can rebuild the backup from scratch.
- Hardened scheduled child-job handling so corrupted or legacy queue rows that are missing `JOB_ACTION` are inferred as child send items instead of being misread as a new prepare phase, which should stop cases like the repeated `element-web` blank-action failure loop.

### 2026.04.16.17 (Testing Branch Only)

- Reworked `ZFS Send` cleanup planning so destination retention and low-space cleanup now batch snapshot metadata and active delete-job checks in memory instead of repeatedly rescanning ZFS and the queue for every candidate snapshot. This should make very large send-managed snapshot sets much less painful to process.
- Reworked autosnapshot cleanup to cache per-dataset snapshot metadata during the run and reuse it across time-based and low-space cleanup decisions, while still invalidating the affected dataset cache after a real delete so follow-up reclaim decisions stay correct.

### 2026.04.16.16 (Testing Branch Only)

- Added a `Download Log` action to failed `ZFS Send` queue items and changed failed-job logging so the shared send log is copied into persistent plugin storage when a job lands in final failed state, surviving later runs and reboots until you clear that queue item.
- Changed repeated failures for the same `ZFS Send` queue item to append new preserved log captures into the same archived failure log instead of overwriting the earlier evidence, so you can see the whole sequence across retries in one download.

### 2026.04.16.15 (Testing Branch Only)

- Fixed source-side `ZFS Send` checkpoint cleanup again so if there is only one configured send schedule using that source dataset, older send checkpoints from earlier schedule incarnations are now treated as part of the same send chain and cleaned up too, instead of leaving the second-most-recent source checkpoint behind forever.

### 2026.04.16.14 (Testing Branch Only)

- Fixed source-side `ZFS Send` checkpoint cleanup again so it can now catch older legacy-format send checkpoints on the source tree when there is only one send schedule using that source dataset, instead of leaving the original setup-era checkpoint behind forever.

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
