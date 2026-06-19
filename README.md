# ZFS Auto Snapshot for Unraid

ZFS Auto Snapshot is an Unraid plugin for managing ZFS snapshots from the WebGUI. You choose the datasets, set the retention rules, and decide whether it runs on a schedule or only when you press Run Now.

The plugin also includes ZFS Send replication, a Dataset Migrator, Snapshot Manager preview tools, and a diagnostics download for support.

## What it does

- Creates snapshots for the ZFS datasets you select.
- Cleans up old plugin-created snapshots using keep-all, daily, and weekly retention windows.
- Watches pool free space and can prune older eligible snapshots before a run when space gets low.
- Lets you preview a run with Dry Run mode before allowing snapshot changes.
- Shows run output and debug logs in the WebGUI.
- Replicates datasets with ZFS Send using separate send checkpoint snapshots.
- Provides a redacted diagnostics zip for GitHub issues.

The plugin only manages snapshots that match its configured snapshot prefix. By default that prefix is `autosnapshot-`.

## Install

Use this plugin URL in Unraid:

```text
https://raw.githubusercontent.com/bstone108/zfsautosnapshot-unraid/main/dist/zfs.autosnapshot.plg
```

Minimum Unraid version: `6.12.0`, because that is the first Unraid release series with native ZFS pool support.

After install, open:

```text
Settings -> ZFS Auto Snapshot
```

## First setup

The plugin starts safe: no datasets are selected and the schedule is disabled until you save your own settings.

Basic setup:

1. Select the datasets you want the plugin to manage.
2. Set a free-space target for each dataset's pool, such as `100G` or `2T`.
3. Check the snapshot prefix. The default is usually fine.
4. Choose your retention windows.
5. Choose a schedule, or leave it disabled and use Run Now.
6. Save settings.

If you want to see what would happen first, turn on Dry Run mode and start a manual run. Dry Run logs the planned actions without creating or deleting snapshots.

## Retention and free-space cleanup

Retention has three normal windows:

- Keep every snapshot for the newest period.
- After that, keep one snapshot per day.
- After that, keep one snapshot per week.

Anything older than the weekly window is eligible for cleanup, as long as it was created with the configured snapshot prefix.

The default example config uses:

- keep all snapshots for 14 days
- keep daily snapshots until 30 days
- keep weekly snapshots until 183 days

You can change those values in the WebGUI.

Free-space cleanup is separate from normal age-based retention. Each selected dataset can have a pool free-space target. If a pool is below that target before a run, the plugin looks for eligible old snapshots that can free space on that same pool.

That does not always mean it deletes from only the dataset that showed the warning. If several selected datasets share the same storage pool, or share quota space in a way where deleting a snapshot from one can free space for another, the plugin may prune the older eligible snapshot from the other dataset first. The goal is to free space safely while keeping the newest useful snapshots.

Unselected datasets are not part of automatic cleanup.

## Scheduling

You do not have to write cron by hand unless you want to.

The WebGUI supports:

- disabled / manual only
- every N minutes
- every N hours
- daily at a chosen time
- weekly on a chosen day and time
- custom cron for advanced use

When you save settings, the plugin writes the cron entry for you.

## Running manually

Use the Run Now button in the WebGUI, or run this from a shell:

```bash
/usr/local/sbin/zfs_autosnapshot
```

## ZFS Send

ZFS Send is for replicating selected datasets to destination datasets.

Each send job has:

- a source dataset
- a destination dataset
- a frequency
- an option to include child datasets
- a destination free-space target

ZFS Send uses its own send checkpoint snapshots instead of the normal autosnapshot prefix. That keeps replication checkpoints separate from regular autosnapshot cleanup.

The send page also has a queue view. Scheduled sends and one-off sends go through the same queue, so you can see what is waiting, running, failed, or ready to retry. Active jobs show step and progress updates when the browser supports it.

Destination cleanup uses the same keep-all, daily, and weekly style retention policy. The newest confirmed send checkpoint is protected so the next incremental send still has a base snapshot.

## Dataset Migrator

Dataset Migrator is for reorganizing a dataset that has several top-level folders and turning those folders into real child datasets.

A common use case is an `appdata` dataset for Docker containers. The migrator can turn each application's configuration folder into its own child dataset. Then each app can have its own snapshots, so you can roll back one damaged or deleted app folder without reverting the entire appdata dataset and losing changes from every other app.

The migrator is careful on purpose:

1. You choose the parent dataset.
2. It scans the top-level folders and shows the migration plan.
3. It skips unsafe names, existing child datasets, and anything that does not look safe to move.
4. Before copying, it records running Docker containers.
5. It stops those containers and temporarily disables their Docker restart policy.
6. It copies each folder into a new child dataset.
7. It verifies the copy with file manifests and checksums.
8. It restores Docker restart policies and starts the containers again.

Because it verifies the copy, it can be slow. That is expected.

Stop any watchdogs or outside tools that might restart containers before you use it. If something relaunches containers during the migration, the tool may abort to avoid an unsafe copy. If free space runs low, the migration can pause and wait for you to free enough space before continuing.

## Snapshot Manager

Snapshot Manager is still a preview feature. It shows dataset-level snapshot summaries and can load a dataset's snapshots when you choose to manage it. It has manual actions such as take snapshot, delete selected snapshots, hold, and release.

Recovery/Repair Tools have been removed from the plugin. They were unfinished and should not be used from this release.

Treat Snapshot Manager as a diagnostic or preview tool for now. Verify results manually before relying on it.

## Logs and diagnostics

The main settings page includes run output and debug logs.

The Help tab has a diagnostics download. The diagnostics zip is meant for GitHub issues and includes redacted plugin config, plugin logs, queue state, and read-only ZFS/zpool/system summaries.

When reporting a bug, include:

- what happened
- which system was affected
- how to reproduce it, if you know
- plugin version
- Unraid version
- diagnostics zip

GitHub issues:

```text
https://github.com/bstone108/zfsautosnapshot-unraid/issues
```

Support thread:

```text
https://forums.unraid.net/topic/197348-plugin-zfs-auto-snapshot/
```

## Files on Unraid

Main config:

```text
/boot/config/plugins/zfs.autosnapshot/zfs_autosnapshot.conf
```

Main command:

```text
/usr/local/sbin/zfs_autosnapshot
```

Plugin WebGUI files:

```text
/usr/local/emhttp/plugins/zfs.autosnapshot/
```

You can edit the config file by hand if needed, but the WebGUI is the intended path.

## Development notes

Release artifacts are built by GitHub Actions. The source template is:

```text
zfs.autosnapshot.plg.in
```

The generated plugin manifest and package are written under `dist/` during the build.

For a normal release:

1. Update `VERSION`.
2. Update `CHANGELOG.md`.
3. Update `zfs.autosnapshot.plg.in`.
4. Push the branch.
5. Let GitHub Actions build and commit the generated artifacts.

To reproduce a package locally:

```bash
./scripts/build-release.sh <version> <base_url>
```

## License

MIT License.
