#!/bin/bash
set -euo pipefail

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

rm -f "$CRON_FILE"
command -v update_cron >/dev/null 2>&1 && update_cron
stop_running_jobs

echo "Removed cron file: $CRON_FILE"
exit 0
