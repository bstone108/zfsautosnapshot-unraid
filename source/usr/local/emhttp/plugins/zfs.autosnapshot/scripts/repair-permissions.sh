#!/bin/bash
set -euo pipefail

PLUGIN_NAME="${PLUGIN_NAME:-zfs.autosnapshot}"
PLUGIN_DIR="${PLUGIN_DIR:-/usr/local/emhttp/plugins/${PLUGIN_NAME}}"
BOOT_PLUGINS_ROOT="${BOOT_PLUGINS_ROOT:-/boot/config/plugins}"
BOOT_PLUGIN_DIR="${BOOT_PLUGIN_DIR:-${BOOT_PLUGINS_ROOT}/${PLUGIN_NAME}}"
DEFAULT_CFG="${DEFAULT_CFG:-${PLUGIN_DIR}/config/zfs_autosnapshot.conf.example}"
TARGET_CFG="${TARGET_CFG:-${BOOT_PLUGIN_DIR}/zfs_autosnapshot.conf}"
WEBGUI_USER="${WEBGUI_USER:-nobody}"
WEBGUI_GROUP="${WEBGUI_GROUP:-users}"

have_user() {
  id -u "$1" >/dev/null 2>&1
}

have_group() {
  if command -v getent >/dev/null 2>&1; then
    getent group "$1" >/dev/null 2>&1
    return $?
  fi

  grep -q "^${1}:" /etc/group 2>/dev/null
}

apply_owner() {
  local path="$1"

  if have_user "$WEBGUI_USER"; then
    chown "$WEBGUI_USER" "$path" >/dev/null 2>&1 || true
  fi

  if have_group "$WEBGUI_GROUP"; then
    chgrp "$WEBGUI_GROUP" "$path" >/dev/null 2>&1 || true
  fi
}

ensure_dir() {
  local dir_path="$1"

  mkdir -p "$dir_path"
  chmod 0775 "$dir_path" >/dev/null 2>&1 || true
  apply_owner "$dir_path"
}

ensure_file() {
  local file_path="$1"

  [[ -e "$file_path" ]] || return 0

  chmod 0644 "$file_path" >/dev/null 2>&1 || true
  apply_owner "$file_path"
}

ensure_dir "$BOOT_PLUGIN_DIR"

if [[ ! -f "$TARGET_CFG" && -f "$DEFAULT_CFG" ]]; then
  cp -f "$DEFAULT_CFG" "$TARGET_CFG"
  echo "Installed default config: $TARGET_CFG"
fi

ensure_file "$TARGET_CFG"

echo "Normalized plugin config ownership and permissions under $BOOT_PLUGIN_DIR"
