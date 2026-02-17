# ZFS Auto Snapshot Plugin (Unraid)

This repository contains an Unraid plugin scaffold for automated ZFS snapshots, including a WebGUI settings page.

## What gets installed

- `/usr/local/sbin/zfs_autosnapshot`
- `/usr/local/emhttp/plugins/zfs.autosnapshot/...`
- Config file (created on first install):
  - `/boot/config/plugins/zfs.autosnapshot/zfs_autosnapshot.conf`

## Behavior

The snapshot engine runs in 3 phases:

1. Time-based retention cleanup (`PREFIX` snapshots only)
2. Space-based cleanup when pool free space is below configured thresholds
3. New snapshot creation for each configured dataset

## Configure on Unraid

Use the plugin page in Unraid to edit settings and schedule in plain English.
Datasets are auto-discovered and shown as a checklist with per-dataset free-space thresholds.
The plugin defaults to no selected datasets and disabled scheduling until you save your choices.

The settings page writes to:

`/boot/config/plugins/zfs.autosnapshot/zfs_autosnapshot.conf`

You can also edit the config manually if needed.

## Scheduling

The plugin supports human-friendly schedule modes:

- Disabled
- Every N hours
- Daily at HH:MM
- Weekly on a day/time
- Advanced custom cron (optional)

When settings are saved, the plugin generates and applies the cron entry automatically.

## Manual run

```bash
/usr/local/sbin/zfs_autosnapshot
```

## Build a release

From repo root:

```bash
./scripts/build-release.sh <version> <base_url>
```

Example:

```bash
./scripts/build-release.sh 2026.02.16 https://raw.githubusercontent.com/OWNER/REPO/main/dist
```

This creates:

- `dist/zfs-autosnapshot-<version>-noarch-1.txz`
- `dist/zfs.autosnapshot.plg`
- `zfs.autosnapshot.plg` (copied to repo root)

Host both files at `<base_url>`, then install in Unraid using the generated `.plg` URL.
