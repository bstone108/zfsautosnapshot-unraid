#!/bin/bash
set -euo pipefail

PLUGIN_NAME="zfs.autosnapshot"
PLUGIN_DIR="/usr/local/emhttp/plugins/${PLUGIN_NAME}"
BOOT_PLUGIN_DIR="/boot/config/plugins/${PLUGIN_NAME}"
DEFAULT_CFG="${PLUGIN_DIR}/config/zfs_autosnapshot.conf.example"
TARGET_CFG="${BOOT_PLUGIN_DIR}/zfs_autosnapshot.conf"
DEFAULT_SEND_CFG="${PLUGIN_DIR}/config/zfs_send.conf.example"
TARGET_SEND_CFG="${BOOT_PLUGIN_DIR}/zfs_send.conf"
MAIN_TARGET_CFG="${BOOT_PLUGIN_DIR}/zfs_autosnapshot.conf"
REPAIR_PERMS_SCRIPT="${PLUGIN_DIR}/scripts/repair-permissions.sh"
RUNTIME_DIR="/var/run/zfs-autosnapshot"
LOCK_FILE="${RUNTIME_DIR}/zfs_autosnapshot.lock"
LOCK_DIR="${RUNTIME_DIR}/zfs_autosnapshot.lockdir"
CHILD_PID_FILE="${RUNTIME_DIR}/zfs_autosnapshot.child.pid"
STOP_FILE="${RUNTIME_DIR}/zfs_autosnapshot.stop"
RUN_MATCH='/usr/local/sbin/zfs_autosnapshot'
SNAPSHOT_PREFIX='autosnapshot-'
SEND_RUNTIME_DIR="/var/run/zfs-autosnapshot-send"
SEND_LOCK_FILE="${SEND_RUNTIME_DIR}/zfs_autosnapshot_send.lock"
SEND_LOCK_DIR="${SEND_RUNTIME_DIR}/zfs_autosnapshot_send.lockdir"
SEND_CHILD_PID_FILE="${SEND_RUNTIME_DIR}/zfs_autosnapshot_send.child.pid"
SEND_STOP_FILE="${SEND_RUNTIME_DIR}/zfs_autosnapshot_send.stop"
SEND_RUN_MATCH='/usr/local/sbin/zfs_autosnapshot_send'
ALLOW_ORPHAN_DESTROY_MATCHES=1
OPS_RUNTIME_DIR="/var/run/zfs-autosnapshot-ops"
OPS_STOP_FILE="${OPS_RUNTIME_DIR}/queue.stop"
OPS_LOCK_FILE="${OPS_RUNTIME_DIR}/queue.lock"
OPS_LOCK_DIR="${OPS_RUNTIME_DIR}/queue.lockdir"
OPS_CHILD_PID_FILE="${OPS_RUNTIME_DIR}/queue.child.pid"
OPS_KICKER_RUN_MATCH='/usr/local/sbin/zfs_autosnapshot_queue_kicker'
OPS_SEND_WORKER_RUN_MATCH='/usr/local/sbin/zfs_autosnapshot_send_worker'
OPS_DELETE_WORKER_RUN_MATCH='/usr/local/sbin/zfs_autosnapshot_delete_worker'
OPS_JOB_LOCKS_DIR="${OPS_RUNTIME_DIR}/job-locks"
RECOVERY_RUNTIME_DIR="/var/run/zfs-autosnapshot-recovery"
RECOVERY_STOP_FILE="${RECOVERY_RUNTIME_DIR}/recovery.stop"
RECOVERY_LOCK_FILE="${RECOVERY_RUNTIME_DIR}/recovery.lock"
RECOVERY_LOCK_DIR="${RECOVERY_RUNTIME_DIR}/recovery.lockdir"
RECOVERY_CHILD_PID_FILE="${RECOVERY_RUNTIME_DIR}/recovery.child.pid"
RECOVERY_SCAN_RUN_MATCH='/usr/local/sbin/zfs_autosnapshot_recovery_scan'
MIGRATOR_RUNTIME_DIR="/var/run/zfs-autosnapshot-migrator"
MIGRATOR_LOCK_FILE="${MIGRATOR_RUNTIME_DIR}/migrator.lock"
MIGRATOR_LOCK_DIR="${MIGRATOR_RUNTIME_DIR}/locks"
MIGRATOR_CHILD_PID_FILE="${MIGRATOR_RUNTIME_DIR}/migrator.child.pid"
MIGRATOR_STOP_FILE="${MIGRATOR_RUNTIME_DIR}/migrator.stop"
MIGRATOR_RUN_MATCH='/usr/local/sbin/zfs_autosnapshot_migrate_datasets'
SNAPSHOT_MANAGER_RUNTIME_DIR="/var/run/zfs-autosnapshot-manager"
SNAPSHOT_MANAGER_LOCK_FILE="${SNAPSHOT_MANAGER_RUNTIME_DIR}/snapshot_manager.lock"
SNAPSHOT_MANAGER_LOCK_DIR="${SNAPSHOT_MANAGER_RUNTIME_DIR}/locks"
SNAPSHOT_MANAGER_CHILD_PID_FILE="${SNAPSHOT_MANAGER_RUNTIME_DIR}/snapshot_manager.child.pid"
SNAPSHOT_MANAGER_STOP_FILE="${SNAPSHOT_MANAGER_RUNTIME_DIR}/snapshot_manager.stop"
SNAPSHOT_MANAGER_RUN_MATCH='/usr/local/sbin/zfs_autosnapshot_snapshot_manager_worker'

remember_pid() {
  local var_name="$1"
  local pid="$2"
  local current="${!var_name:-$'\n'}"

  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  if [[ "$current" == *$'\n'"$pid"$'\n'* ]]; then
    return 1
  fi

  printf -v "$var_name" '%s%s\n' "$current" "$pid"
  return 0
}

list_running_pids() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -f "$RUN_MATCH" || true
  else
    ps -eo pid=,command= | awk -v needle="$RUN_MATCH" '
      index($0, needle) { print $1 }
    ' || true
  fi
}

load_snapshot_prefix() {
  local raw

  [[ -r "$TARGET_CFG" ]] || return 0
  raw="$(awk -F= '/^PREFIX=/{v=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); gsub(/^"/,"",v); gsub(/"$/,"",v); print v; exit}' "$TARGET_CFG" 2>/dev/null || true)"
  if [[ -n "$raw" ]]; then
    SNAPSHOT_PREFIX="$raw"
  fi
}

read_lock_pids() {
  if [[ -r "$LOCK_FILE" ]]; then
    awk 'NR == 1 && $1 ~ /^[0-9]+$/ { print $1; exit }' "$LOCK_FILE" 2>/dev/null || true
  fi

  if [[ -r "${LOCK_DIR}/pid" ]]; then
    awk 'NR == 1 && $1 ~ /^[0-9]+$/ { print $1; exit }' "${LOCK_DIR}/pid" 2>/dev/null || true
  fi

  if [[ -r "$CHILD_PID_FILE" ]]; then
    awk 'NR == 1 && $1 ~ /^[0-9]+$/ { print $1; exit }' "$CHILD_PID_FILE" 2>/dev/null || true
  fi
}

list_child_pids() {
  local parent_pid="$1"

  if command -v pgrep >/dev/null 2>&1; then
    pgrep -P "$parent_pid" || true
  else
    ps -eo pid=,ppid= | awk -v ppid="$parent_pid" '$2 == ppid { print $1 }' || true
  fi
}

collect_pid_tree() {
  local root_pid="$1"
  local child

  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    collect_pid_tree "$child"
  done < <(list_child_pids "$root_pid")

  printf '%s\n' "$root_pid"
}

list_orphaned_destroy_pids() {
  ps -eo pid=,args= | awk -v prefix="$SNAPSHOT_PREFIX" '
    index($0, "zfs destroy") && index($0, "@" prefix) { print $1 }
  ' || true
}

request_graceful_stop() {
  mkdir -p "$RUNTIME_DIR" 2>/dev/null || true
  : > "$STOP_FILE" 2>/dev/null || true
  chmod 0600 "$STOP_FILE" 2>/dev/null || true
  echo "Requested running zfs_autosnapshot job to stop."
  sleep 2
}

stop_pid_tree() {
  local root_pid="$1"
  local waited=0
  local pid
  local -a pid_tree=()

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    pid_tree+=("$pid")
  done < <(collect_pid_tree "$root_pid")

  (( ${#pid_tree[@]} > 0 )) || return 0

  echo "Stopping zfs_autosnapshot process tree rooted at ${root_pid}: ${pid_tree[*]}"
  kill "${pid_tree[@]}" >/dev/null 2>&1 || true

  while (( waited < 10 )); do
    local remaining=0
    for pid in "${pid_tree[@]}"; do
      if kill -0 "$pid" >/dev/null 2>&1; then
        remaining=1
        break
      fi
    done
    (( remaining == 0 )) && break
    sleep 1
    waited=$((waited + 1))
  done

  for pid in "${pid_tree[@]}"; do
    if kill -0 "$pid" >/dev/null 2>&1; then
      echo "Force stopping stuck process: $pid"
      kill -9 "$pid" >/dev/null 2>&1 || true
    fi
  done
}

stop_running_jobs() {
  local pid
  local seen_pids=$'\n'
  load_snapshot_prefix
  request_graceful_stop

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    remember_pid seen_pids "$pid" >/dev/null 2>&1 || true
  done < <(read_lock_pids)

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    remember_pid seen_pids "$pid" >/dev/null 2>&1 || true
  done < <(list_running_pids)

  if (( ALLOW_ORPHAN_DESTROY_MATCHES )); then
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      remember_pid seen_pids "$pid" >/dev/null 2>&1 || true
    done < <(list_orphaned_destroy_pids)
  fi

  if [[ -z "$(printf '%s' "$seen_pids" | sed '/^[[:space:]]*$/d')" ]]; then
    echo "No running zfs_autosnapshot job detected."
  else
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      stop_pid_tree "$pid"
    done <<<"$(printf '%s' "$seen_pids" | sed '/^[[:space:]]*$/d')"
  fi

  rm -f "$LOCK_FILE" >/dev/null 2>&1 || true
  rm -f "$CHILD_PID_FILE" >/dev/null 2>&1 || true
  rm -f "$STOP_FILE" >/dev/null 2>&1 || true
  rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
}

refresh_web_runtime() {
  local refreshed=0

  if [[ -x /etc/rc.d/rc.php-fpm ]]; then
    /etc/rc.d/rc.php-fpm restart >/dev/null 2>&1 || /etc/rc.d/rc.php-fpm reload >/dev/null 2>&1 || true
    refreshed=1
  fi

  if [[ -x /etc/rc.d/rc.nginx ]]; then
    /etc/rc.d/rc.nginx reload >/dev/null 2>&1 || /etc/rc.d/rc.nginx restart >/dev/null 2>&1 || true
    refreshed=1
  fi

  if (( refreshed )); then
    echo "WebGUI runtime refreshed."
  else
    echo "WebGUI runtime refresh skipped (rc.php-fpm/rc.nginx not found)." >&2
  fi
}

if [[ -x "$REPAIR_PERMS_SCRIPT" ]]; then
  "$REPAIR_PERMS_SCRIPT"
else
  mkdir -p "$BOOT_PLUGIN_DIR"

  if [[ ! -f "$TARGET_CFG" ]]; then
    cp -f "$DEFAULT_CFG" "$TARGET_CFG"
    chmod 0644 "$TARGET_CFG"
    echo "Installed default config: $TARGET_CFG"
  else
    echo "Keeping existing config: $TARGET_CFG"
  fi

  if [[ ! -f "$TARGET_SEND_CFG" ]]; then
    cp -f "$DEFAULT_SEND_CFG" "$TARGET_SEND_CFG"
    chmod 0644 "$TARGET_SEND_CFG"
    echo "Installed default config: $TARGET_SEND_CFG"
  else
    echo "Keeping existing config: $TARGET_SEND_CFG"
  fi
fi

# Remove any AppleDouble metadata files that can break Unraid page parsing.
find "$PLUGIN_DIR" -type f \( -name '._*' -o -name '.DS_Store' \) -delete 2>/dev/null || true

# Always stop any in-flight job before applying runtime refresh / cron sync so an
# old buggy process cannot survive an upgrade.
stop_running_jobs

RUNTIME_DIR="$SEND_RUNTIME_DIR"
LOCK_FILE="$SEND_LOCK_FILE"
LOCK_DIR="$SEND_LOCK_DIR"
CHILD_PID_FILE="$SEND_CHILD_PID_FILE"
STOP_FILE="$SEND_STOP_FILE"
RUN_MATCH="$SEND_RUN_MATCH"
SNAPSHOT_PREFIX='zfs-send-'
TARGET_CFG="$TARGET_SEND_CFG"
ALLOW_ORPHAN_DESTROY_MATCHES=1
stop_running_jobs

RUNTIME_DIR="$SNAPSHOT_MANAGER_RUNTIME_DIR"
LOCK_FILE="$SNAPSHOT_MANAGER_LOCK_FILE"
LOCK_DIR="$SNAPSHOT_MANAGER_LOCK_DIR"
CHILD_PID_FILE="$SNAPSHOT_MANAGER_CHILD_PID_FILE"
STOP_FILE="$SNAPSHOT_MANAGER_STOP_FILE"
RUN_MATCH="$SNAPSHOT_MANAGER_RUN_MATCH"
SNAPSHOT_PREFIX='manual-'
TARGET_CFG="$MAIN_TARGET_CFG"
ALLOW_ORPHAN_DESTROY_MATCHES=0
stop_running_jobs

RUNTIME_DIR="$OPS_RUNTIME_DIR"
LOCK_FILE="$OPS_LOCK_FILE"
LOCK_DIR="$OPS_LOCK_DIR"
CHILD_PID_FILE="$OPS_CHILD_PID_FILE"
STOP_FILE="$OPS_STOP_FILE"
SNAPSHOT_PREFIX='zfs-send-'
TARGET_CFG="$TARGET_SEND_CFG"
ALLOW_ORPHAN_DESTROY_MATCHES=0
for RUN_MATCH in "$OPS_KICKER_RUN_MATCH" "$OPS_SEND_WORKER_RUN_MATCH" "$OPS_DELETE_WORKER_RUN_MATCH"; do
  stop_running_jobs
done
rm -rf "$OPS_JOB_LOCKS_DIR" >/dev/null 2>&1 || true

RUNTIME_DIR="$RECOVERY_RUNTIME_DIR"
LOCK_FILE="$RECOVERY_LOCK_FILE"
LOCK_DIR="$RECOVERY_LOCK_DIR"
CHILD_PID_FILE="$RECOVERY_CHILD_PID_FILE"
STOP_FILE="$RECOVERY_STOP_FILE"
SNAPSHOT_PREFIX='manual-recovery-'
TARGET_CFG="$MAIN_TARGET_CFG"
ALLOW_ORPHAN_DESTROY_MATCHES=0
RUN_MATCH="$RECOVERY_SCAN_RUN_MATCH"
stop_running_jobs

RUNTIME_DIR="$MIGRATOR_RUNTIME_DIR"
LOCK_FILE="$MIGRATOR_LOCK_FILE"
LOCK_DIR="$MIGRATOR_LOCK_DIR"
CHILD_PID_FILE="$MIGRATOR_CHILD_PID_FILE"
STOP_FILE="$MIGRATOR_STOP_FILE"
SNAPSHOT_PREFIX='manual-migration-'
TARGET_CFG="$MAIN_TARGET_CFG"
ALLOW_ORPHAN_DESTROY_MATCHES=0
RUN_MATCH="$MIGRATOR_RUN_MATCH"
stop_running_jobs

sync_exit=0
if [[ -x "${PLUGIN_DIR}/scripts/sync-cron.sh" ]]; then
  "${PLUGIN_DIR}/scripts/sync-cron.sh" || sync_exit=$?
fi

# Force cron runtime refresh on every install/upgrade so users do not need
# to press Save just to activate a pre-existing schedule.
if command -v update_cron >/dev/null 2>&1; then
  update_cron || true
fi

if [[ -x /etc/rc.d/rc.crond ]]; then
  /etc/rc.d/rc.crond restart >/dev/null 2>&1 || true
fi

# Refresh php-fpm/nginx so updated plugin PHP is served immediately on systems
# that keep stale PHP workers or opcache across plugin upgrades.
refresh_web_runtime

if (( sync_exit != 0 )); then
  echo "WARNING: sync-cron.sh failed during install/upgrade (exit ${sync_exit})." >&2
fi

exit 0
