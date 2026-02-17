#!/bin/bash
set -euo pipefail

PLUGIN_NAME="zfs.autosnapshot"
PLUGIN_DIR="/usr/local/emhttp/plugins/${PLUGIN_NAME}"
BOOT_PLUGIN_DIR="/boot/config/plugins/${PLUGIN_NAME}"
DEFAULT_CFG="${PLUGIN_DIR}/config/zfs_autosnapshot.conf.example"
TARGET_CFG="${BOOT_PLUGIN_DIR}/zfs_autosnapshot.conf"

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

"${PLUGIN_DIR}/scripts/sync-cron.sh" || true

exit 0
