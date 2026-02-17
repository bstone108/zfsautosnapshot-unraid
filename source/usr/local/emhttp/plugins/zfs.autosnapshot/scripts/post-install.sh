#!/bin/bash
set -euo pipefail

PLUGIN_NAME="zfs.autosnapshot"
PLUGIN_DIR="/usr/local/emhttp/plugins/${PLUGIN_NAME}"
BOOT_PLUGIN_DIR="/boot/config/plugins/${PLUGIN_NAME}"
DEFAULT_CFG="${PLUGIN_DIR}/config/zfs_autosnapshot.conf.example"
TARGET_CFG="${BOOT_PLUGIN_DIR}/zfs_autosnapshot.conf"
CRON_FILE="/etc/cron.d/zfs_autosnapshot"

mkdir -p "$BOOT_PLUGIN_DIR"

if [[ ! -f "$TARGET_CFG" ]]; then
  cp -f "$DEFAULT_CFG" "$TARGET_CFG"
  chmod 0644 "$TARGET_CFG"
  echo "Installed default config: $TARGET_CFG"
else
  echo "Keeping existing config: $TARGET_CFG"
fi

# Remove any AppleDouble metadata files that can break Unraid page parsing.
find "$PLUGIN_DIR" -type f \( -name '._*' -o -name '.DS_Store' \) -delete 2>/dev/null || true

sync_exit=0
if [[ -x "${PLUGIN_DIR}/scripts/sync-cron.sh" ]]; then
  "${PLUGIN_DIR}/scripts/sync-cron.sh" || sync_exit=$?
fi

# Safety guard: if schedule mode is disabled, ensure cron file is removed.
schedule_mode="$(awk -F= '/^SCHEDULE_MODE=/{v=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); gsub(/^"/,"",v); gsub(/"$/,"",v); print tolower(v); exit}' "$TARGET_CFG" 2>/dev/null || true)"
if [[ -z "$schedule_mode" ]]; then
  schedule_mode="disabled"
fi

if [[ "$schedule_mode" == "disabled" ]]; then
  rm -f "$CRON_FILE"
  echo "Schedule mode is disabled; ensured cron entry is removed."
fi

# Force cron runtime refresh on every install/upgrade so users do not need
# to press Save just to activate a pre-existing schedule.
if command -v update_cron >/dev/null 2>&1; then
  update_cron || true
fi

if [[ -x /etc/rc.d/rc.crond ]]; then
  /etc/rc.d/rc.crond restart >/dev/null 2>&1 || true
fi

if (( sync_exit != 0 )); then
  echo "WARNING: sync-cron.sh failed during install/upgrade (exit ${sync_exit})." >&2
fi

exit 0
