#!/bin/bash
set -euo pipefail

PLUGIN_NAME="zfs.autosnapshot"
PLUGIN_DIR="/usr/local/emhttp/plugins/${PLUGIN_NAME}"
BOOT_PLUGIN_DIR="/boot/config/plugins/${PLUGIN_NAME}"
DEFAULT_CFG="${PLUGIN_DIR}/config/zfs_autosnapshot.conf.example"
TARGET_CFG="${BOOT_PLUGIN_DIR}/zfs_autosnapshot.conf"
CRON_FILE="/etc/cron.d/zfs_autosnapshot"
RUNTIME_DIR="/var/run/zfs-autosnapshot"
LOCK_FILE="${RUNTIME_DIR}/zfs_autosnapshot.lock"
LOCK_DIR="${RUNTIME_DIR}/zfs_autosnapshot.lockdir"
RUN_MATCH='/usr/local/sbin/zfs_autosnapshot'

list_running_pids() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -f "$RUN_MATCH" || true
  else
    ps -eo pid=,command= | awk -v needle="$RUN_MATCH" '
      index($0, needle) { print $1 }
    ' || true
  fi
}

stop_running_jobs() {
  local pid remaining waited=0
  local -a pids=()

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    pids+=("$pid")
  done < <(list_running_pids)

  if (( ${#pids[@]} == 0 )); then
    echo "No running zfs_autosnapshot job detected."
  else
    echo "Stopping running zfs_autosnapshot job(s): ${pids[*]}"
    kill "${pids[@]}" >/dev/null 2>&1 || true

    while (( waited < 10 )); do
      remaining=0
      for pid in "${pids[@]}"; do
        if kill -0 "$pid" >/dev/null 2>&1; then
          remaining=1
          break
        fi
      done
      (( remaining == 0 )) && break
      sleep 1
      waited=$((waited + 1))
    done

    for pid in "${pids[@]}"; do
      if kill -0 "$pid" >/dev/null 2>&1; then
        echo "Force stopping stuck zfs_autosnapshot process: $pid"
        kill -9 "$pid" >/dev/null 2>&1 || true
      fi
    done
  fi

  rm -f "$LOCK_FILE" >/dev/null 2>&1 || true
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

# Always stop any in-flight job before applying runtime refresh / cron sync so an
# old buggy process cannot survive an upgrade.
stop_running_jobs

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

# Refresh php-fpm/nginx so updated plugin PHP is served immediately on systems
# that keep stale PHP workers or opcache across plugin upgrades.
refresh_web_runtime

if (( sync_exit != 0 )); then
  echo "WARNING: sync-cron.sh failed during install/upgrade (exit ${sync_exit})." >&2
fi

exit 0
