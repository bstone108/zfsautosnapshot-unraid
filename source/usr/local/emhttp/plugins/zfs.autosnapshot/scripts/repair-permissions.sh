#!/bin/bash
set -euo pipefail

PLUGIN_NAME="${PLUGIN_NAME:-zfs.autosnapshot}"
PLUGIN_DIR="${PLUGIN_DIR:-/usr/local/emhttp/plugins/${PLUGIN_NAME}}"
BOOT_PLUGINS_ROOT="${BOOT_PLUGINS_ROOT:-/boot/config/plugins}"
BOOT_PLUGIN_DIR="${BOOT_PLUGIN_DIR:-${BOOT_PLUGINS_ROOT}/${PLUGIN_NAME}}"
DEFAULT_CFG="${DEFAULT_CFG:-${PLUGIN_DIR}/config/zfs_autosnapshot.conf.example}"
TARGET_CFG="${TARGET_CFG:-${BOOT_PLUGIN_DIR}/zfs_autosnapshot.conf}"
DEFAULT_SEND_CFG="${DEFAULT_SEND_CFG:-${PLUGIN_DIR}/config/zfs_send.conf.example}"
TARGET_SEND_CFG="${TARGET_SEND_CFG:-${BOOT_PLUGIN_DIR}/zfs_send.conf}"
SNAPSHOT_MANAGER_ROOT="${SNAPSHOT_MANAGER_ROOT:-${BOOT_PLUGIN_DIR}/snapshot_manager}"
SNAPSHOT_MANAGER_QUEUE_DIR="${SNAPSHOT_MANAGER_QUEUE_DIR:-${SNAPSHOT_MANAGER_ROOT}/queues}"
SNAPSHOT_MANAGER_STATUS_DIR="${SNAPSHOT_MANAGER_STATUS_DIR:-${SNAPSHOT_MANAGER_ROOT}/status}"
OPS_QUEUE_ROOT="${OPS_QUEUE_ROOT:-${BOOT_PLUGIN_DIR}/ops_queue}"
OPS_QUEUE_JOBS_DIR="${OPS_QUEUE_JOBS_DIR:-${OPS_QUEUE_ROOT}/jobs}"
OPS_QUEUE_STATUS_DIR="${OPS_QUEUE_STATUS_DIR:-${OPS_QUEUE_ROOT}/status}"
RECOVERY_ROOT="${RECOVERY_ROOT:-${BOOT_PLUGIN_DIR}/recovery_tools}"
RECOVERY_SCANS_DIR="${RECOVERY_SCANS_DIR:-${RECOVERY_ROOT}/scans}"
MIGRATOR_ROOT="${MIGRATOR_ROOT:-${BOOT_PLUGIN_DIR}/dataset_migrator}"
MIGRATOR_LOGS_DIR="${MIGRATOR_LOGS_DIR:-${MIGRATOR_ROOT}/logs}"
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

ensure_executable() {
  local file_path="$1"

  [[ -e "$file_path" ]] || return 0

  chmod 0755 "$file_path" >/dev/null 2>&1 || true
}

ensure_dir "$BOOT_PLUGIN_DIR"
ensure_dir "$SNAPSHOT_MANAGER_ROOT"
ensure_dir "$SNAPSHOT_MANAGER_QUEUE_DIR"
ensure_dir "$SNAPSHOT_MANAGER_STATUS_DIR"
ensure_dir "$OPS_QUEUE_ROOT"
ensure_dir "$OPS_QUEUE_JOBS_DIR"
ensure_dir "$OPS_QUEUE_STATUS_DIR"
ensure_dir "$RECOVERY_ROOT"
ensure_dir "$RECOVERY_SCANS_DIR"
ensure_dir "$MIGRATOR_ROOT"
ensure_dir "$MIGRATOR_LOGS_DIR"

if [[ ! -f "$TARGET_CFG" && -f "$DEFAULT_CFG" ]]; then
  cp -f "$DEFAULT_CFG" "$TARGET_CFG"
  echo "Installed default config: $TARGET_CFG"
fi

ensure_file "$TARGET_CFG"

if [[ ! -f "$TARGET_SEND_CFG" && -f "$DEFAULT_SEND_CFG" ]]; then
  cp -f "$DEFAULT_SEND_CFG" "$TARGET_SEND_CFG"
  echo "Installed default config: $TARGET_SEND_CFG"
fi

ensure_file "$TARGET_SEND_CFG"

ensure_executable "/usr/local/sbin/zfs_autosnapshot"
ensure_executable "/usr/local/sbin/zfs_autosnapshot_send"
ensure_executable "/usr/local/sbin/zfs_autosnapshot_queue_kicker"
ensure_executable "/usr/local/sbin/zfs_autosnapshot_send_worker"
ensure_executable "/usr/local/sbin/zfs_autosnapshot_delete_worker"
ensure_executable "/usr/local/sbin/zfs_autosnapshot_snapshot_manager_worker"
ensure_executable "/usr/local/sbin/zfs_autosnapshot_recovery_scan"
ensure_executable "/usr/local/sbin/zfs_autosnapshot_migrate_datasets"

echo "Normalized plugin config ownership and permissions under $BOOT_PLUGIN_DIR"
