#!/bin/bash
set -euo pipefail

CRON_FILE="/etc/cron.d/zfs_autosnapshot"

rm -f "$CRON_FILE"
command -v update_cron >/dev/null 2>&1 && update_cron

echo "Removed cron file: $CRON_FILE"
exit 0
