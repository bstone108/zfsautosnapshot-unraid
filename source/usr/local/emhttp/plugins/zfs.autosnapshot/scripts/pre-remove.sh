#!/bin/bash
set -euo pipefail

CRON_FILE="/etc/cron.d/zfs_autosnapshot"
RUNTIME_DIR="/var/run/zfs-autosnapshot"
LOCK_FILE="${RUNTIME_DIR}/zfs_autosnapshot.lock"
LOCK_DIR="${RUNTIME_DIR}/zfs_autosnapshot.lockdir"
RUN_MATCH='/usr/local/sbin/zfs_autosnapshot'

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

read_lock_pids() {
  if [[ -r "$LOCK_FILE" ]]; then
    awk 'NR == 1 && $1 ~ /^[0-9]+$/ { print $1; exit }' "$LOCK_FILE" 2>/dev/null || true
  fi

  if [[ -r "${LOCK_DIR}/pid" ]]; then
    awk 'NR == 1 && $1 ~ /^[0-9]+$/ { print $1; exit }' "${LOCK_DIR}/pid" 2>/dev/null || true
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

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    remember_pid seen_pids "$pid" >/dev/null 2>&1 || true
  done < <(read_lock_pids)

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    remember_pid seen_pids "$pid" >/dev/null 2>&1 || true
  done < <(list_running_pids)

  if [[ -z "$(printf '%s' "$seen_pids" | sed '/^[[:space:]]*$/d')" ]]; then
    echo "No running zfs_autosnapshot job detected."
  else
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      stop_pid_tree "$pid"
    done <<<"$(printf '%s' "$seen_pids" | sed '/^[[:space:]]*$/d')"
  fi

  rm -f "$LOCK_FILE" >/dev/null 2>&1 || true
  rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
}

rm -f "$CRON_FILE"
command -v update_cron >/dev/null 2>&1 && update_cron
stop_running_jobs

echo "Removed cron file: $CRON_FILE"
exit 0
