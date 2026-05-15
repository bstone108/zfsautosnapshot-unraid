# Testing-only ZFS send debug markers

This file is a deliberate reminder that the current `testing` branch contains temporary debug markers for field analysis of ZFS send behavior.

## Strip before main/release promotion

Before promoting these changes to `main` or cutting a release, remove:

- `ZFSAS_SEND_DEBUG_MARKERS` default enablement from `source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/ops-queue-lib.sh`.
- `zfsas_send_debug_marker()` helper from `source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/ops-queue-lib.sh`, unless it is intentionally converted into a supported release diagnostic feature.
- All `TESTING_DEBUG_MARKER` comments and `zfsas_send_debug_marker ...` calls.
- This reminder file.

Useful check:

```bash
grep -R "TESTING_DEBUG_MARKER\|zfsas_send_debug_marker\|ZFSAS_SEND_DEBUG_MARKERS" .
```

Expected result before main/release promotion: no matches.

## Current intent

The markers are meant to make `/var/log/zfs_autosnapshot_send.log` useful for behavioral analysis across testing machines. They trace:

- send worker lifecycle and job state transitions;
- scheduled checkpoint creation;
- child/finalizer queue fanout;
- member preflight state;
- latest-common/base-snapshot selection;
- destination space estimation/reservation;
- send transfer slot acquisition;
- full/incremental pipeline start, success, and failure with component exit codes;
- reseed decisions;
- source checkpoint cleanup decisions;
- finalizer wait/skip/complete decisions.

These are intentionally verbose and should not be treated as permanent release logging without a separate review.
