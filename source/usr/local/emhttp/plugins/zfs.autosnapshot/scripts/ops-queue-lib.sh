#!/bin/bash

ZFSAS_LOG_HELPER="/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/log-maintenance-lib.sh"
if [[ -r "$ZFSAS_LOG_HELPER" ]]; then
  # shellcheck source=/dev/null
  source "$ZFSAS_LOG_HELPER"
else
  zfsas_log_sanitize_text() { printf '%s' "$1"; }
  zfsas_log_prepare_for_append() { return 0; }
fi

PLUGIN_NAME="zfs.autosnapshot"
CONFIG_DIR="/boot/config/plugins/${PLUGIN_NAME}"
SEND_CONFIG_FILE="${CONFIG_DIR}/zfs_send.conf"
OPS_ROOT="/tmp/zfs-autosnapshot-ops"
OPS_JOBS_DIR="${OPS_ROOT}/jobs"
OPS_STATUS_DIR="${OPS_ROOT}/status"
DELETE_QUEUE_STATE_FILE="${OPS_STATUS_DIR}/delete-queue.state"
DELETE_QUEUE_INBOX_FILE="${OPS_ROOT}/delete-queue.inbox"
DELETE_QUEUE_INBOX_LOCK_FILE="${OPS_ROOT}/delete-queue.inbox.lock"
PERSISTED_QUEUE_DIR="${CONFIG_DIR}/runtime_queue"
PERSISTED_DELETE_QUEUE_FILE="${PERSISTED_QUEUE_DIR}/delete-queue.persist"
FAILED_SEND_LOGS_DIR="${CONFIG_DIR}/failed_send_logs"
SEND_SCHEDULE_STATE_FILE="${CONFIG_DIR}/send_schedule_state.state"
RUNTIME_DIR="/var/run/zfs-autosnapshot-ops"
SEND_WORKER_RUNTIME_DIR="${RUNTIME_DIR}/send-workers"
DELETE_WORKER_RUNTIME_DIR="${RUNTIME_DIR}/delete-worker"
DELETE_QUEUE_PID_FILE="${DELETE_WORKER_RUNTIME_DIR}/daemon.pid"
DELETE_QUEUE_LOCK_DIR="${DELETE_WORKER_RUNTIME_DIR}/daemon.lockdir"
PREP_LOCKS_DIR="${RUNTIME_DIR}/prep-locks"
JOB_LOCKS_DIR="${RUNTIME_DIR}/job-locks"
ACTIVE_SEND_DATASETS_DIR="${RUNTIME_DIR}/active-send-datasets"
AUTOSNAPSHOT_RUNTIME_DIR="/var/run/zfs-autosnapshot"
AUTOSNAPSHOT_ACTIVE_FILE="${AUTOSNAPSHOT_RUNTIME_DIR}/zfs_autosnapshot.active"
LOG_FILE="/var/log/zfs_autosnapshot_send.log"
LOG_ARCHIVE_FILE="/var/log/zfs_autosnapshot_send.archive.log"
SEND_LOG_MAX_BYTES="${SEND_LOG_MAX_BYTES:-2097152}"
SEND_LOG_ARCHIVE_MAX_BYTES="${SEND_LOG_ARCHIVE_MAX_BYTES:-4194304}"

DEFAULT_SEND_SNAPSHOT_PREFIX="zfs-send-"
DEFAULT_SEND_MAX_PARALLEL="1"
DEFAULT_SEND_KEEP_ALL_FOR_DAYS="14"
DEFAULT_SEND_KEEP_DAILY_UNTIL_DAYS="30"
DEFAULT_SEND_KEEP_WEEKLY_UNTIL_DAYS="183"
DEFAULT_RETRY_DELAYS=(60 300 900)
POST_DELETE_RECHECK_WAIT_SECONDS="${POST_DELETE_RECHECK_WAIT_SECONDS:-3}"
POST_DELETE_RECHECK_INTERVAL_SECONDS="${POST_DELETE_RECHECK_INTERVAL_SECONDS:-1}"
JOB_SUCCESS_TTL_SECONDS="${JOB_SUCCESS_TTL_SECONDS:-5}"
DELETE_QUEUE_IDLE_TIMEOUT_SECONDS="${DELETE_QUEUE_IDLE_TIMEOUT_SECONDS:-30}"

SEND_SNAPSHOT_PREFIX="$DEFAULT_SEND_SNAPSHOT_PREFIX"
SEND_MAX_PARALLEL="$DEFAULT_SEND_MAX_PARALLEL"
SEND_KEEP_ALL_FOR_DAYS="$DEFAULT_SEND_KEEP_ALL_FOR_DAYS"
SEND_KEEP_DAILY_UNTIL_DAYS="$DEFAULT_SEND_KEEP_DAILY_UNTIL_DAYS"
SEND_KEEP_WEEKLY_UNTIL_DAYS="$DEFAULT_SEND_KEEP_WEEKLY_UNTIL_DAYS"
SEND_JOBS=""

SCHEDULE_JOB_IDS=()
declare -A SCHEDULE_SOURCE_ROOT=()
declare -A SCHEDULE_DEST_ROOT=()
declare -A SCHEDULE_FREQUENCY=()
declare -A SCHEDULE_THRESHOLD_RAW=()
declare -A SCHEDULE_THRESHOLD_BYTES=()
declare -A SCHEDULE_INCLUDE_CHILDREN=()
declare -A SCHEDULE_PREFIX=()
declare -A SCHEDULE_LAST_COMPLETED_WINDOW=()
QUEUE_DELETE_LAST_ADDED=0
QUEUE_DELETE_LAST_ESTIMATED_RECLAIM=0
DELETE_QUEUE_INDEX_LOADED=0

declare -A SEND_DATASET_SNAPSHOT_LINES_ASC=()
declare -A SEND_DATASET_SNAPSHOT_LINES_DESC=()
declare -A SEND_SNAPSHOT_CREATION_MAP=()
declare -A SEND_SNAPSHOT_WRITTEN_MAP=()
declare -A SEND_SNAPSHOT_USERREFS_MAP=()
declare -A SEND_SNAPSHOT_HAS_CLONES_MAP=()
declare -A SEND_SNAPSHOT_GUID_MAP=()
declare -A SEND_SNAPSHOT_CREATETXG_MAP=()
declare -A SEND_CHECKPOINT_RECLAIM_CACHE=()
declare -A SEND_PROTECTED_BASENAME_CACHE=()
declare -A SEND_DESTINATION_DATASETS_BY_SCHEDULE=()
declare -A SEND_DESTINATION_DATASETS_BY_POOL=()
declare -A DELETE_QUEUE_BY_SNAPSHOT=()
declare -A DELETE_QUEUE_BY_CHECKPOINT=()
declare -A DELETE_QUEUE_COUNTS_BY_POOL=()
declare -A DELETE_QUEUE_COUNTS_BY_DATASET=()
declare -A SEND_EPOCH_DAY_KEY_CACHE=()
declare -A SEND_EPOCH_WEEK_KEY_CACHE=()
SEND_PROTECTED_BASENAME_CACHE_LOADED=0

log() {
  printf '%s %s\n' "$(date +'%Y-%m-%d %H:%M:%S %Z')" "$(zfsas_log_sanitize_text "$*")"
}

find_mdcmd() {
  if command -v mdcmd >/dev/null 2>&1; then
    command -v mdcmd
    return 0
  fi
  [[ -x /root/mdcmd ]] || return 1
  printf '/root/mdcmd\n'
}

extract_status_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key { print $2; exit }'
}

get_unraid_array_status() {
  local mdcmd_bin
  if mdcmd_bin="$(find_mdcmd 2>/dev/null)"; then
    "$mdcmd_bin" status
    return 0
  fi
  if [[ -r /proc/mdcmd ]]; then
    cat /proc/mdcmd
    return 0
  fi
  if [[ -r /var/local/emhttp/var.ini ]]; then
    cat /var/local/emhttp/var.ini
    return 0
  fi
  return 1
}

normalize_unraid_state_value() {
  local value="${1:-}"
  value="$(trim "$value")"
  value="${value,,}"
  printf '%s' "$value"
}

unraid_actionable_state_value() {
  local status_text key="$1" value=""
  status_text="$(get_unraid_array_status 2>/dev/null || true)"
  [[ -n "$status_text" ]] || {
    printf ''
    return 1
  }
  value="$(printf '%s\n' "$status_text" | extract_status_value "$key" | head -n 1)"
  normalize_unraid_state_value "$value"
}

unraid_array_actionable() {
  local md_state fs_state sb_state started

  md_state="$(unraid_actionable_state_value "mdState" || true)"
  fs_state="$(unraid_actionable_state_value "fsState" || true)"
  sb_state="$(unraid_actionable_state_value "sbState" || true)"
  started="$(unraid_actionable_state_value "started" || true)"

  case "$md_state" in
    started|started_mounted|mounted)
      return 0
      ;;
    stopped|stopping|starting|shutdown|shutting_down)
      return 1
      ;;
  esac

  case "$fs_state" in
    started|mounted)
      return 0
      ;;
    stopped|stopping|starting|shutdown|shutting_down)
      return 1
      ;;
  esac

  case "$sb_state" in
    started|mounted)
      return 0
      ;;
    stopped|stopping|starting|shutdown|shutting_down)
      return 1
      ;;
  esac

  case "$started" in
    1|yes|true)
      return 0
      ;;
    0|no|false)
      return 1
      ;;
  esac

  return 1
}

unraid_array_action_message() {
  local md_state fs_state sb_state

  md_state="$(unraid_actionable_state_value "mdState" || true)"
  fs_state="$(unraid_actionable_state_value "fsState" || true)"
  sb_state="$(unraid_actionable_state_value "sbState" || true)"

  if [[ -n "$md_state" ]]; then
    printf 'Waiting for Unraid array to become actionable (mdState=%s)' "$md_state"
    return 0
  fi

  if [[ -n "$fs_state" ]]; then
    printf 'Waiting for Unraid array filesystem state to become actionable (fsState=%s)' "$fs_state"
    return 0
  fi

  if [[ -n "$sb_state" ]]; then
    printf 'Waiting for Unraid system state to become actionable (sbState=%s)' "$sb_state"
    return 0
  fi

  printf 'Waiting for Unraid to report an actionable array state'
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

ops_apply_owner() {
  local path="$1"
  chown nobody "$path" >/dev/null 2>&1 || true
  chgrp users "$path" >/dev/null 2>&1 || true
}

ops_ensure_dir() {
  local path="$1"
  mkdir -p "$path" >/dev/null 2>&1 || true
  chmod 0775 "$path" >/dev/null 2>&1 || true
  ops_apply_owner "$path"
  [[ -d "$path" ]]
}

ensure_runtime_layout() {
  ops_ensure_dir "$OPS_ROOT" || return 1
  ops_ensure_dir "$OPS_JOBS_DIR" || return 1
  ops_ensure_dir "$OPS_STATUS_DIR" || return 1
  ops_ensure_dir "$PERSISTED_QUEUE_DIR" || return 1
  ops_ensure_dir "$FAILED_SEND_LOGS_DIR" || return 1
  mkdir -p "$RUNTIME_DIR" "$SEND_WORKER_RUNTIME_DIR" "$DELETE_WORKER_RUNTIME_DIR" "$PREP_LOCKS_DIR" "$JOB_LOCKS_DIR" "$ACTIVE_SEND_DATASETS_DIR" "$(dirname "$LOG_FILE")" >/dev/null 2>&1 || true
  # Only reap clearly stale temp files. Removing every *.tmp.* file at worker startup can
  # delete another process's in-flight job write and corrupt queue items.
  find "$OPS_JOBS_DIR" -maxdepth 1 -type f -name '*.tmp.*' -mmin +60 -exec rm -f {} \; >/dev/null 2>&1 || true
  return 0
}

delete_queue_reset_index() {
  DELETE_QUEUE_BY_SNAPSHOT=()
  DELETE_QUEUE_BY_CHECKPOINT=()
  DELETE_QUEUE_COUNTS_BY_POOL=()
  DELETE_QUEUE_COUNTS_BY_DATASET=()
  DELETE_QUEUE_INDEX_LOADED=0
}

delete_queue_state_file_exists() {
  [[ -f "$DELETE_QUEUE_STATE_FILE" ]]
}

delete_queue_persisted_file_exists() {
  [[ -f "$PERSISTED_DELETE_QUEUE_FILE" ]]
}

delete_queue_status_value() {
  local key="$1"
  local value=""

  [[ -f "$DELETE_QUEUE_STATE_FILE" ]] || return 1
  value="$(grep -E "^${key}=" "$DELETE_QUEUE_STATE_FILE" 2>/dev/null | head -n 1 | cut -d= -f2-)"
  [[ -n "$value" ]] || return 1
  printf '%s' "$value"
}

delete_queue_sanitize_field() {
  local value="${1:-}"
  value="${value//$'\t'/ }"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  printf '%s' "$value"
}

delete_queue_emit_state_line() {
  local assoc_name="$1"
  # shellcheck disable=SC2178
  local -n job_ref="$assoc_name"

  printf 'JOB\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(delete_queue_sanitize_field "${job_ref[JOB_ID]:-}")" \
    "$(delete_queue_sanitize_field "${job_ref[STATE]:-queued}")" \
    "$(delete_queue_sanitize_field "${job_ref[RETRY_AT]:-0}")" \
    "$(delete_queue_sanitize_field "${job_ref[REQUESTED_EPOCH]:-0}")" \
    "$(delete_queue_sanitize_field "${job_ref[QUEUE_SORT]:-0}")" \
    "$(delete_queue_sanitize_field "${job_ref[DATASET]:-}")" \
    "$(delete_queue_sanitize_field "${job_ref[SNAPSHOT]:-}")" \
    "$(delete_queue_sanitize_field "${job_ref[SNAPSHOT_NAME]:-}")" \
    "$(delete_queue_sanitize_field "${job_ref[SNAPSHOT_EPOCH]:-0}")" \
    "$(delete_queue_sanitize_field "${job_ref[SNAPSHOT_GUID]:-}")" \
    "$(delete_queue_sanitize_field "${job_ref[SNAPSHOT_CREATETXG]:-}")" \
    "$(delete_queue_sanitize_field "${job_ref[DELETE_POOL]:-}")" \
    "$(delete_queue_sanitize_field "${job_ref[ESTIMATED_RECLAIM_BYTES]:-0}")" \
    "$(delete_queue_sanitize_field "${job_ref[SEND_PROTECTED]:-0}")" \
    "$(delete_queue_sanitize_field "${job_ref[DELETE_SCOPE]:-snapshot}")" \
    "$(delete_queue_sanitize_field "${job_ref[SEND_SCHEDULE_JOB_ID]:-}")" \
    "$(delete_queue_sanitize_field "${job_ref[WORKER_PID]:-}")"
}

delete_queue_parse_state_line() {
  local line="$1"
  local assoc_name="$2"
  local prefix job_id state retry_at requested_epoch queue_sort dataset snapshot snapshot_name snapshot_epoch
  local snapshot_guid snapshot_createtxg delete_pool estimated_reclaim send_protected delete_scope
  local send_schedule_job_id worker_pid
  # shellcheck disable=SC2178
  local -n job_ref="$assoc_name"

  job_ref=()
  IFS=$'\t' read -r prefix job_id state retry_at requested_epoch queue_sort dataset snapshot snapshot_name snapshot_epoch \
    snapshot_guid snapshot_createtxg delete_pool estimated_reclaim send_protected delete_scope \
    send_schedule_job_id worker_pid <<< "$line"
  [[ "$prefix" == "JOB" && -n "$job_id" && -n "$snapshot" ]] || return 1

  job_ref[JOB_ID]="$job_id"
  job_ref[STATE]="${state:-queued}"
  job_ref[RETRY_AT]="${retry_at:-0}"
  job_ref[REQUESTED_EPOCH]="${requested_epoch:-0}"
  job_ref[QUEUE_SORT]="${queue_sort:-0}"
  job_ref[DATASET]="$dataset"
  job_ref[SNAPSHOT]="$snapshot"
  job_ref[SNAPSHOT_NAME]="$snapshot_name"
  job_ref[SNAPSHOT_EPOCH]="${snapshot_epoch:-0}"
  job_ref[SNAPSHOT_GUID]="$snapshot_guid"
  job_ref[SNAPSHOT_CREATETXG]="$snapshot_createtxg"
  job_ref[DELETE_POOL]="$delete_pool"
  job_ref[ESTIMATED_RECLAIM_BYTES]="${estimated_reclaim:-0}"
  job_ref[SEND_PROTECTED]="${send_protected:-0}"
  job_ref[DELETE_SCOPE]="${delete_scope:-snapshot}"
  job_ref[SEND_SCHEDULE_JOB_ID]="$send_schedule_job_id"
  job_ref[WORKER_PID]="$worker_pid"
  return 0
}

delete_queue_emit_enqueue_line() {
  local assoc_name="$1"
  # shellcheck disable=SC2178
  local -n job_ref="$assoc_name"

  printf 'ENQUEUE\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(delete_queue_sanitize_field "${job_ref[JOB_ID]:-}")" \
    "$(delete_queue_sanitize_field "${job_ref[REQUESTED_EPOCH]:-0}")" \
    "$(delete_queue_sanitize_field "${job_ref[QUEUE_SORT]:-0}")" \
    "$(delete_queue_sanitize_field "${job_ref[DATASET]:-}")" \
    "$(delete_queue_sanitize_field "${job_ref[SNAPSHOT]:-}")" \
    "$(delete_queue_sanitize_field "${job_ref[SNAPSHOT_NAME]:-}")" \
    "$(delete_queue_sanitize_field "${job_ref[SNAPSHOT_EPOCH]:-0}")" \
    "$(delete_queue_sanitize_field "${job_ref[SNAPSHOT_GUID]:-}")" \
    "$(delete_queue_sanitize_field "${job_ref[SNAPSHOT_CREATETXG]:-}")" \
    "$(delete_queue_sanitize_field "${job_ref[DELETE_POOL]:-}")" \
    "$(delete_queue_sanitize_field "${job_ref[ESTIMATED_RECLAIM_BYTES]:-0}")" \
    "$(delete_queue_sanitize_field "${job_ref[SEND_PROTECTED]:-0}")" \
    "$(delete_queue_sanitize_field "${job_ref[DELETE_SCOPE]:-snapshot}")" \
    "$(delete_queue_sanitize_field "${job_ref[SEND_SCHEDULE_JOB_ID]:-}")"
}

delete_queue_parse_enqueue_line() {
  local line="$1"
  local assoc_name="$2"
  local prefix job_id requested_epoch queue_sort dataset snapshot snapshot_name snapshot_epoch snapshot_guid
  local snapshot_createtxg delete_pool estimated_reclaim send_protected delete_scope send_schedule_job_id
  # shellcheck disable=SC2178
  local -n job_ref="$assoc_name"

  job_ref=()
  IFS=$'\t' read -r prefix job_id requested_epoch queue_sort dataset snapshot snapshot_name snapshot_epoch snapshot_guid \
    snapshot_createtxg delete_pool estimated_reclaim send_protected delete_scope send_schedule_job_id <<< "$line"
  [[ "$prefix" == "ENQUEUE" && -n "$job_id" && -n "$snapshot" ]] || return 1

  job_ref[JOB_ID]="$job_id"
  job_ref[STATE]="queued"
  job_ref[RETRY_AT]="0"
  job_ref[REQUESTED_EPOCH]="${requested_epoch:-0}"
  job_ref[QUEUE_SORT]="${queue_sort:-0}"
  job_ref[DATASET]="$dataset"
  job_ref[SNAPSHOT]="$snapshot"
  job_ref[SNAPSHOT_NAME]="$snapshot_name"
  job_ref[SNAPSHOT_EPOCH]="${snapshot_epoch:-0}"
  job_ref[SNAPSHOT_GUID]="$snapshot_guid"
  job_ref[SNAPSHOT_CREATETXG]="$snapshot_createtxg"
  job_ref[DELETE_POOL]="$delete_pool"
  job_ref[ESTIMATED_RECLAIM_BYTES]="${estimated_reclaim:-0}"
  job_ref[SEND_PROTECTED]="${send_protected:-0}"
  job_ref[DELETE_SCOPE]="${delete_scope:-snapshot}"
  job_ref[SEND_SCHEDULE_JOB_ID]="$send_schedule_job_id"
  job_ref[WORKER_PID]=""
  return 0
}

delete_queue_append_inbox_line() {
  local line="$1"
  local fd=9

  : > "$DELETE_QUEUE_INBOX_LOCK_FILE" 2>/dev/null || true
  exec {fd}>>"$DELETE_QUEUE_INBOX_LOCK_FILE" || return 1
  flock "$fd" || {
    eval "exec ${fd}>&-"
    return 1
  }
  printf '%s\n' "$line" >> "$DELETE_QUEUE_INBOX_FILE" || {
    flock -u "$fd" || true
    eval "exec ${fd}>&-"
    return 1
  }
  flock -u "$fd" || true
  eval "exec ${fd}>&-"
  chmod 0660 "$DELETE_QUEUE_INBOX_FILE" >/dev/null 2>&1 || true
  ops_apply_owner "$DELETE_QUEUE_INBOX_FILE"
  return 0
}

delete_queue_daemon_running() {
  local pid=""

  [[ -f "$DELETE_QUEUE_PID_FILE" ]] || return 1
  pid="$(sed -n '1p' "$DELETE_QUEUE_PID_FILE" 2>/dev/null || true)"
  if process_alive "$pid"; then
    return 0
  fi

  rm -f "$DELETE_QUEUE_PID_FILE" >/dev/null 2>&1 || true
  rm -rf "$DELETE_QUEUE_LOCK_DIR" >/dev/null 2>&1 || true
  return 1
}

start_delete_queue_daemon() {
  local waited=0

  delete_queue_daemon_running && return 0

  mkdir -p "$DELETE_WORKER_RUNTIME_DIR" >/dev/null 2>&1 || true
  nohup /usr/local/sbin/zfs_autosnapshot_delete_worker >> "$LOG_FILE" 2>&1 < /dev/null &

  while (( waited < 50 )); do
    delete_queue_daemon_running && return 0
    sleep 0.1
    waited=$((waited + 1))
  done

  return 1
}

delete_queue_has_backlog() {
  local pending_count="0"
  local running_count="0"

  pending_count="$(delete_queue_status_value "PENDING_COUNT" 2>/dev/null || printf '0')"
  running_count="$(delete_queue_status_value "RUNNING_COUNT" 2>/dev/null || printf '0')"
  if [[ "$pending_count" =~ ^[0-9]+$ && "$running_count" =~ ^[0-9]+$ ]] && (( pending_count > 0 || running_count > 0 )); then
    return 0
  fi
  if delete_queue_state_file_exists && grep -q $'^JOB\t' "$DELETE_QUEUE_STATE_FILE" 2>/dev/null; then
    return 0
  fi
  if delete_queue_persisted_file_exists && grep -q $'^JOB\t' "$PERSISTED_DELETE_QUEUE_FILE" 2>/dev/null; then
    return 0
  fi
  [[ -s "$DELETE_QUEUE_INBOX_FILE" ]]
}

submit_delete_queue_job() {
  local assoc_name="$1"
  local line
  # shellcheck disable=SC2178
  local -n job_ref="$assoc_name"

  line="$(delete_queue_emit_enqueue_line "$assoc_name")"
  delete_queue_append_inbox_line "$line" || return 1
  start_delete_queue_daemon >/dev/null 2>&1 || true
  return 0
}

sanitize_job_id_for_path() {
  local job_id="$1"
  local sanitized
  sanitized="$(printf '%s' "$job_id" | tr -c 'A-Za-z0-9._-' '_')"
  [[ -n "$sanitized" ]] || sanitized="unknown-job"
  printf '%s' "$sanitized"
}

failed_send_log_path() {
  local job_id="$1"
  printf '%s/%s.log' "$FAILED_SEND_LOGS_DIR" "$(sanitize_job_id_for_path "$job_id")"
}

delete_preserved_failed_send_log() {
  local job_id="$1"
  local path
  path="$(failed_send_log_path "$job_id")"
  [[ -e "$path" ]] || return 0
  [[ -f "$path" && ! -L "$path" ]] || return 1
  rm -f "$path"
}

preserve_failed_send_log_for_job() {
  local assoc_name="$1"
  # shellcheck disable=SC2178
  local -n job_ref="$assoc_name"
  local job_type job_id path tmp now_utc phase mode action source destination

  job_type="${job_ref[JOB_TYPE]:-}"
  [[ "$job_type" == "send" ]] || return 0

  job_id="${job_ref[JOB_ID]:-}"
  [[ -n "$job_id" ]] || return 0

  ops_ensure_dir "$FAILED_SEND_LOGS_DIR" || return 1
  path="$(failed_send_log_path "$job_id")"
  tmp="${path}.tmp.$$"
  now_utc="$(date -u +'%Y-%m-%d %H:%M:%S UTC')"
  phase="${job_ref[PHASE]:-failed}"
  mode="${job_ref[JOB_MODE]:-}"
  action="${job_ref[JOB_ACTION]:-}"
  source="${job_ref[SOURCE_ROOT]:-${job_ref[DATASET]:-}}"
  destination="${job_ref[DESTINATION_ROOT]:-}"

  {
    if [[ -f "$path" ]]; then
      cat "$path"
      printf '\n'
    else
      printf 'ZFS Send Failure Log Archive\n'
      printf 'Job ID: %s\n' "$job_id"
      printf 'This file keeps every preserved shared-send-log snapshot captured when this queue item entered final failed state.\n\n'
    fi
    printf '===== Failure Capture %s =====\n' "$now_utc"
    printf 'State: %s\n' "${job_ref[STATE]:-failed}"
    printf 'Phase: %s\n' "$phase"
    [[ -n "$mode" ]] && printf 'Mode: %s\n' "$mode"
    [[ -n "$action" ]] && printf 'Action: %s\n' "$action"
    [[ -n "$source" ]] && printf 'Source: %s\n' "$source"
    [[ -n "$destination" ]] && printf 'Destination: %s\n' "$destination"
    [[ -n "${job_ref[LAST_ERROR]:-}" ]] && printf 'Last Error: %s\n' "${job_ref[LAST_ERROR]}"
    [[ -n "${job_ref[LAST_MESSAGE]:-}" ]] && printf 'Last Message: %s\n' "${job_ref[LAST_MESSAGE]}"
    printf 'Shared Log Source: %s\n\n' "$LOG_FILE"
    if [[ -f "$LOG_FILE" && ! -L "$LOG_FILE" && -r "$LOG_FILE" ]]; then
      cat "$LOG_FILE"
      printf '\n'
    else
      printf 'Shared send log was unavailable or unreadable at preservation time.\n\n'
    fi
  } > "$tmp"

  mv -f "$tmp" "$path"
  chmod 0640 "$path" >/dev/null 2>&1 || true
  ops_apply_owner "$path"
}

parse_config_value() {
  local raw="$1"
  local value

  value="$(trim "$raw")"
  [[ -n "$value" ]] || {
    printf ''
    return 0
  }

  if [[ "$value" == \"*\" && "$value" == *\" && ${#value} -ge 2 ]]; then
    value="${value:1:${#value}-2}"
    value="${value//\\\\/\\}"
    value="${value//\\\"/\"}"
    printf '%s' "$value"
    return 0
  fi

  if [[ "$value" == \'*\' && "$value" == *\' && ${#value} -ge 2 ]]; then
    value="${value:1:${#value}-2}"
    printf '%s' "$value"
    return 0
  fi

  value="${value%%#*}"
  value="$(trim "$value")"
  printf '%s' "$value"
}

load_send_config() {
  local line key raw value

  SEND_SNAPSHOT_PREFIX="$DEFAULT_SEND_SNAPSHOT_PREFIX"
  SEND_MAX_PARALLEL="$DEFAULT_SEND_MAX_PARALLEL"
  SEND_KEEP_ALL_FOR_DAYS="$DEFAULT_SEND_KEEP_ALL_FOR_DAYS"
  SEND_KEEP_DAILY_UNTIL_DAYS="$DEFAULT_SEND_KEEP_DAILY_UNTIL_DAYS"
  SEND_KEEP_WEEKLY_UNTIL_DAYS="$DEFAULT_SEND_KEEP_WEEKLY_UNTIL_DAYS"
  SEND_JOBS=""

  [[ -f "$SEND_CONFIG_FILE" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue

    if [[ "$line" =~ ^[[:space:]]*([A-Z0-9_]+)[[:space:]]*=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      raw="${BASH_REMATCH[2]}"
      value="$(parse_config_value "$raw")"
      case "$key" in
        SEND_SNAPSHOT_PREFIX|SEND_MAX_PARALLEL|SEND_KEEP_ALL_FOR_DAYS|SEND_KEEP_DAILY_UNTIL_DAYS|SEND_KEEP_WEEKLY_UNTIL_DAYS|SEND_JOBS)
          printf -v "$key" '%s' "$value"
          ;;
      esac
    fi
  done < "$SEND_CONFIG_FILE"
}

require_numeric_in_range() {
  local value="$2"
  local min="$3"
  local max="$4"

  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  (( value >= min && value <= max ))
}

threshold_to_bytes() {
  local raw="$1"
  local number unit multiplier=1

  raw="$(echo "$raw" | tr '[:lower:]' '[:upper:]' | tr -d ' ')"
  [[ "$raw" =~ ^([0-9]+)([KMGT])B?$ ]] || return 1
  number="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[2]}"

  case "$unit" in
    K) multiplier=$((1024)) ;;
    M) multiplier=$((1024 * 1024)) ;;
    G) multiplier=$((1024 * 1024 * 1024)) ;;
    T) multiplier=$((1024 * 1024 * 1024 * 1024)) ;;
    *) return 1 ;;
  esac

  echo $(( number * multiplier ))
}

normalize_send_frequency() {
  case "$1" in
    15m|30m|1h) echo "6h" ;;
    6h|12h|1d|7d) echo "$1" ;;
    *) echo "" ;;
  esac
}

frequency_seconds() {
  case "$1" in
    6h) echo 21600 ;;
    12h) echo 43200 ;;
    1d) echo 86400 ;;
    7d) echo 604800 ;;
    *) echo 0 ;;
  esac
}

date_at_epoch() {
  local epoch="$1"
  local format="$2"
  [[ "$format" == +* ]] && format="${format#+}"
  date +"$format" -d "@$epoch" 2>/dev/null || date -r "$epoch" +"$format"
}

timezone_offset_seconds() {
  local epoch="$1"
  local raw sign hours minutes
  raw="$(date_at_epoch "$epoch" +%z)"
  [[ "$raw" =~ ^([+-])([0-9]{2})([0-9]{2})$ ]] || {
    echo 0
    return 0
  }
  sign="${BASH_REMATCH[1]}"
  hours="${BASH_REMATCH[2]}"
  minutes="${BASH_REMATCH[3]}"
  if [[ "$sign" == "-" ]]; then
    echo $(( -1 * ((10#$hours * 3600) + (10#$minutes * 60)) ))
  else
    echo $(( (10#$hours * 3600) + (10#$minutes * 60) ))
  fi
}

frequency_window_key() {
  local frequency="$1"
  local now_epoch="$2"
  local seconds offset local_epoch

  case "$frequency" in
    6h|12h|1d|7d) ;;
    *)
      echo "$now_epoch"
      return 0
      ;;
  esac

  seconds="$(frequency_seconds "$frequency")"
  (( seconds > 0 )) || {
    echo "$now_epoch"
    return 0
  }

  offset="$(timezone_offset_seconds "$now_epoch")"
  local_epoch=$(( now_epoch + offset ))
  echo $(( (local_epoch - (local_epoch % seconds)) - offset ))
}

jobs_are_same_pool_overlap() {
  local source="$1"
  local dest="$2"

  [[ "${source%%/*}" == "${dest%%/*}" ]] || return 1
  [[ "$source" == "$dest" || "$source" == "$dest/"* || "$dest" == "$source/"* ]]
}

is_valid_dataset_name() {
  [[ "$1" =~ ^[A-Za-z0-9._/:+\-]+$ ]]
}

is_valid_snapshot_basename() {
  [[ "$1" =~ ^[A-Za-z0-9._:+\-]+$ ]]
}

is_valid_snapshot_name() {
  local snapshot="$1"
  [[ "$snapshot" == *@* ]] || return 1
  is_valid_dataset_name "${snapshot%@*}" || return 1
  is_valid_snapshot_basename "${snapshot#*@}"
}

parse_send_jobs_config() {
  local raw_jobs pair job_id source dest freq thresh children threshold_bytes
  local -A seen=()

  SCHEDULE_JOB_IDS=()
  SCHEDULE_SOURCE_ROOT=()
  SCHEDULE_DEST_ROOT=()
  SCHEDULE_FREQUENCY=()
  SCHEDULE_THRESHOLD_RAW=()
  SCHEDULE_THRESHOLD_BYTES=()
  SCHEDULE_INCLUDE_CHILDREN=()
  SCHEDULE_PREFIX=()

  IFS=';' read -r -a raw_jobs <<<"$SEND_JOBS"
  for pair in "${raw_jobs[@]}"; do
    pair="$(trim "$pair")"
    [[ -n "$pair" ]] || continue

    IFS='|' read -r job_id source dest freq thresh children <<<"$pair"
    job_id="$(trim "$job_id")"
    source="$(trim "$source")"
    dest="$(trim "$dest")"
    freq="$(normalize_send_frequency "$(trim "$freq")")"
    thresh="$(trim "$thresh")"
    children="$(trim "${children:-0}")"
    [[ -n "$children" ]] || children="0"

    [[ "$job_id" =~ ^[a-f0-9]{12}$ ]] || continue
    [[ -n "$source" && -n "$dest" && -n "$freq" && -n "$thresh" ]] || continue
    [[ "$source" =~ ^[A-Za-z0-9._/:+-]+$ ]] || continue
    [[ "$dest" =~ ^[A-Za-z0-9._/:+-]+$ ]] || continue
    [[ "$dest" == */* ]] || continue
    [[ "$source" != "$dest" ]] || continue
    [[ -z "${seen[$job_id]:-}" ]] || continue
    [[ -n "$freq" ]] || continue
    threshold_bytes="$(threshold_to_bytes "$thresh" 2>/dev/null || true)"
    [[ "$threshold_bytes" =~ ^[0-9]+$ ]] || continue
    [[ "$children" == "1" ]] || children="0"
    jobs_are_same_pool_overlap "$source" "$dest" && continue

    seen[$job_id]=1
    SCHEDULE_JOB_IDS+=("$job_id")
    SCHEDULE_SOURCE_ROOT["$job_id"]="$source"
    SCHEDULE_DEST_ROOT["$job_id"]="$dest"
    SCHEDULE_FREQUENCY["$job_id"]="$freq"
    SCHEDULE_THRESHOLD_RAW["$job_id"]="$thresh"
    SCHEDULE_THRESHOLD_BYTES["$job_id"]="$threshold_bytes"
    SCHEDULE_INCLUDE_CHILDREN["$job_id"]="$children"
    SCHEDULE_PREFIX["$job_id"]="${SEND_SNAPSHOT_PREFIX}${job_id}-"
  done
}

kv_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

job_load() {
  local path="$1"
  local assoc_name="$2"
  local line key raw value
  local -n job_ref="$assoc_name"

  job_ref=()
  [[ -f "$path" ]] || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if [[ "$line" =~ ^[[:space:]]*([A-Z0-9_]+)[[:space:]]*=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      raw="${BASH_REMATCH[2]}"
      value="$(parse_config_value "$raw")"
      job_ref["$key"]="$value"
    fi
  done < "$path"

  job_ref["__PATH"]="$path"
  job_ref["__BASENAME"]="$(basename "$path")"
  return 0
}

job_write() {
  local path="$1"
  local assoc_name="$2"
  local tmp
  # shellcheck disable=SC2178
  local -n job_ref="$assoc_name"
  local key

  tmp="$(mktemp "${path}.tmp.XXXXXX")" || return 1

  while IFS= read -r key; do
    [[ "$key" == __* ]] && continue
    printf '%s="%s"\n' "$key" "$(kv_escape "${job_ref[$key]}")" >> "$tmp"
  done < <(printf '%s\n' "${!job_ref[@]}" | sort)

  mv "$tmp" "$path" || {
    rm -f "$tmp" >/dev/null 2>&1 || true
    return 1
  }
  chmod 0640 "$path" >/dev/null 2>&1 || true
  ops_apply_owner "$path"
  return 0
}

job_write_ordered() {
  local path="$1"
  local assoc_name="$2"
  shift 2
  local tmp key extra_keys=""
  # shellcheck disable=SC2178
  local -n job_ref="$assoc_name"
  local -A emitted=()

  tmp="$(mktemp "${path}.tmp.XXXXXX")" || return 1

  for key in "$@"; do
    [[ "$key" == __* ]] && continue
    [[ -n "${job_ref[$key]+set}" ]] || continue
    printf '%s="%s"\n' "$key" "$(kv_escape "${job_ref[$key]}")" >> "$tmp"
    emitted["$key"]=1
  done

  for key in "${!job_ref[@]}"; do
    [[ "$key" == __* ]] && continue
    [[ -z "${emitted[$key]:-}" ]] || continue
    extra_keys+="${key}"$'\n'
  done

  if [[ -n "$extra_keys" ]]; then
    while IFS= read -r key; do
      [[ -n "$key" ]] || continue
      printf '%s="%s"\n' "$key" "$(kv_escape "${job_ref[$key]}")" >> "$tmp"
    done < <(printf '%s' "$extra_keys" | sort)
  fi

  mv "$tmp" "$path" || {
    rm -f "$tmp" >/dev/null 2>&1 || true
    return 1
  }
  chmod 0640 "$path" >/dev/null 2>&1 || true
  ops_apply_owner "$path"
  return 0
}

job_set() {
  local assoc_name="$1"
  local key="$2"
  local value="$3"
  # shellcheck disable=SC2178
  local -n job_ref="$assoc_name"
  job_ref["$key"]="$value"
}

job_get() {
  local assoc_name="$1"
  local key="$2"
  local default_value="${3:-}"
  # shellcheck disable=SC2178
  local -n job_ref="$assoc_name"
  if [[ -n "${job_ref[$key]+x}" ]]; then
    printf '%s' "${job_ref[$key]}"
  else
    printf '%s' "$default_value"
  fi
}

list_job_files() {
  find "$OPS_JOBS_DIR" -maxdepth 1 -type f -name '*.job' 2>/dev/null | sort
}

job_state_is_active() {
  case "$1" in
    queued|running|retry_wait) return 0 ;;
    *) return 1 ;;
  esac
}

job_state_is_success() {
  case "$1" in
    complete|skipped) return 0 ;;
    *) return 1 ;;
  esac
}

job_completes_schedule_window() {
  local assoc_name="$1"
  # shellcheck disable=SC2178
  local -n job_ref="$assoc_name"
  local explicit action

  explicit="${job_ref[COMPLETES_SCHEDULE_WINDOW]:-}"
  if [[ -n "$explicit" ]]; then
    [[ "$explicit" == "1" ]]
    return
  fi

  action="${job_ref[JOB_ACTION]:-}"
  case "$action" in
    ""|single_send|finalize) return 0 ;;
    *) return 1 ;;
  esac
}

load_schedule_state() {
  local line job_id window_key

  SCHEDULE_LAST_COMPLETED_WINDOW=()
  [[ -f "$SEND_SCHEDULE_STATE_FILE" ]] || return 0

  while IFS='|' read -r job_id window_key || [[ -n "$job_id" ]]; do
    job_id="$(trim "$job_id")"
    window_key="$(trim "$window_key")"
    [[ -n "$job_id" ]] || continue
    [[ "$window_key" =~ ^[0-9]+$ ]] || continue
    SCHEDULE_LAST_COMPLETED_WINDOW["$job_id"]="$window_key"
  done < "$SEND_SCHEDULE_STATE_FILE"
}

write_schedule_state() {
  local tmp job_id
  ops_ensure_dir "$CONFIG_DIR" || return 1
  tmp="$(mktemp "${SEND_SCHEDULE_STATE_FILE}.tmp.XXXXXX")" || return 1

  while IFS= read -r job_id; do
    printf '%s|%s\n' "$job_id" "${SCHEDULE_LAST_COMPLETED_WINDOW[$job_id]}" >> "$tmp"
  done < <(printf '%s\n' "${!SCHEDULE_LAST_COMPLETED_WINDOW[@]}" | sort)

  mv "$tmp" "$SEND_SCHEDULE_STATE_FILE" || {
    rm -f "$tmp" >/dev/null 2>&1 || true
    return 1
  }
  chmod 0640 "$SEND_SCHEDULE_STATE_FILE" >/dev/null 2>&1 || true
  ops_apply_owner "$SEND_SCHEDULE_STATE_FILE"
}

last_completed_schedule_window_key() {
  local schedule_job_id="$1"
  printf '%s' "${SCHEDULE_LAST_COMPLETED_WINDOW[$schedule_job_id]:-0}"
}

record_completed_schedule_window() {
  local schedule_job_id="$1"
  local window_key="$2"

  [[ -n "$schedule_job_id" ]] || return 1
  [[ "$window_key" =~ ^[0-9]+$ ]] || return 1

  load_schedule_state
  SCHEDULE_LAST_COMPLETED_WINDOW["$schedule_job_id"]="$window_key"
  write_schedule_state
}

latest_current_window_send_basename_for_dataset() {
  local schedule_job_id="$1"
  local dataset="$2"
  local window_key="$3"
  local result_basename_var="$4"
  local result_epoch_var="${5:-}"
  local snap_name snap_epoch snap_base
  local prefix

  printf -v "$result_basename_var" ''
  [[ -n "$result_epoch_var" ]] && printf -v "$result_epoch_var" '0'
  [[ -n "$dataset" && "$window_key" =~ ^[0-9]+$ ]] || return 1
  dataset_exists "$dataset" || return 1

  prefix="$(job_prefix_for_schedule "$schedule_job_id")"
  load_send_dataset_snapshot_cache "$dataset"
  while IFS=$'\t' read -r snap_name snap_epoch; do
    [[ -n "$snap_name" && -n "$snap_epoch" ]] || continue
    (( snap_epoch >= window_key )) || continue
    snap_base="${snap_name##*@}"
    send_basename_matches_schedule "$snap_base" "$schedule_job_id" || continue
    printf -v "$result_basename_var" '%s' "$snap_base"
    if [[ -n "$result_epoch_var" ]]; then
      printf -v "$result_epoch_var" '%s' "$snap_epoch"
    fi
    return 0
  done <<< "${SEND_DATASET_SNAPSHOT_LINES_DESC[$dataset]}"

  return 1
}

dataset_has_snapshot_basename() {
  local dataset="$1"
  local basename="$2"

  [[ -n "$dataset" && -n "$basename" ]] || return 1
  dataset_exists "$dataset" || return 1
  load_send_dataset_snapshot_cache "$dataset"
  [[ -n "${SEND_SNAPSHOT_CREATION_MAP["${dataset}@${basename}"]:-}" ]]
}

source_snapshot_exists_for_basename() {
  local dataset="$1"
  local basename="$2"
  snapshot_exists "${dataset}@${basename}"
}

find_previous_schedule_checkpoint_basename() {
  local source_dataset="$1"
  local current_basename="$2"
  local schedule_job_id="$3"
  local result_var="$4"
  local snap_name snap_epoch snap_base
  local seen_current=0

  printf -v "$result_var" ''
  [[ -n "$source_dataset" && -n "$current_basename" && -n "$schedule_job_id" ]] || return 1
  dataset_exists "$source_dataset" || return 1

  load_send_dataset_snapshot_cache "$source_dataset"
  while IFS=$'\t' read -r snap_name snap_epoch; do
    [[ -n "$snap_name" && -n "$snap_epoch" ]] || continue
    snap_base="${snap_name##*@}"
    send_basename_matches_schedule "$snap_base" "$schedule_job_id" || continue
    if [[ "$snap_base" == "$current_basename" ]]; then
      seen_current=1
      continue
    fi
    (( seen_current == 1 )) || continue
    printf -v "$result_var" '%s' "$snap_base"
    return 0
  done <<< "${SEND_DATASET_SNAPSHOT_LINES_DESC[$source_dataset]}"

  return 1
}

schedule_can_resume_current_window() {
  local schedule_job_id="$1"
  local window_key="$2"
  local result_basename_var="$3"
  local result_previous_var="${4:-}"
  local dest_root source_root include_children current_basename previous_basename=""
  local source_dataset destination_dataset relative

  printf -v "$result_basename_var" ''
  [[ -n "$result_previous_var" ]] && printf -v "$result_previous_var" ''
  [[ "$window_key" =~ ^[0-9]+$ ]] || return 1

  dest_root="${SCHEDULE_DEST_ROOT[$schedule_job_id]:-}"
  source_root="${SCHEDULE_SOURCE_ROOT[$schedule_job_id]:-}"
  include_children="${SCHEDULE_INCLUDE_CHILDREN[$schedule_job_id]:-0}"
  [[ -n "$dest_root" && -n "$source_root" ]] || return 1

  latest_current_window_send_basename_for_dataset "$schedule_job_id" "$dest_root" "$window_key" current_basename || return 1
  source_snapshot_exists_for_basename "$source_root" "$current_basename" || return 1
  while IFS= read -r source_dataset; do
    [[ -n "$source_dataset" ]] || continue
    if [[ "$source_dataset" == "$source_root" ]]; then
      destination_dataset="$dest_root"
    else
      relative="${source_dataset#"${source_root}"/}"
      destination_dataset="${dest_root}/${relative}"
    fi

    if dataset_has_snapshot_basename "$destination_dataset" "$current_basename"; then
      continue
    fi

    source_snapshot_exists_for_basename "$source_dataset" "$current_basename" || return 1
  done < <(list_tree_datasets "$source_root" "$include_children")
  find_previous_schedule_checkpoint_basename "$source_root" "$current_basename" "$schedule_job_id" previous_basename || true

  printf -v "$result_basename_var" '%s' "$current_basename"
  if [[ -n "$result_previous_var" ]]; then
    printf -v "$result_previous_var" '%s' "$previous_basename"
  fi
  return 0
}

enqueue_resume_prepare_job() {
  local schedule_job_id="$1"
  local window_key="$2"
  local requested_epoch="$3"
  local requested_at="$4"
  local source_snapshot_basename="$5"
  local previous_basename="${6:-}"
  local job_file
  local -A job=()

  job[JOB_ID]="send-${schedule_job_id}-${window_key}-resume"
  job[JOB_TYPE]="send"
  job[JOB_MODE]="scheduled"
  job[JOB_ACTION]="prepare"
  job[STATE]="queued"
  job[PHASE]="queued"
  job[REQUESTED_EPOCH]="$requested_epoch"
  job[REQUESTED_AT]="$requested_at"
  job[QUEUE_SORT]="$requested_epoch"
  job[WINDOW_KEY]="$window_key"
  job[SCHEDULE_JOB_ID]="$schedule_job_id"
  job[SOURCE_ROOT]="${SCHEDULE_SOURCE_ROOT[$schedule_job_id]}"
  job[DESTINATION_ROOT]="${SCHEDULE_DEST_ROOT[$schedule_job_id]}"
  job[INCLUDE_CHILDREN]="${SCHEDULE_INCLUDE_CHILDREN[$schedule_job_id]}"
  job[FREQUENCY]="${SCHEDULE_FREQUENCY[$schedule_job_id]}"
  job[THRESHOLD]="${SCHEDULE_THRESHOLD_RAW[$schedule_job_id]}"
  job[THRESHOLD_BYTES]="${SCHEDULE_THRESHOLD_BYTES[$schedule_job_id]}"
  job[SNAPSHOT_PREFIX_BASE]="$SEND_SNAPSHOT_PREFIX"
  job[SNAPSHOT_PREFIX]="$(job_prefix_for_schedule "$schedule_job_id")"
  job[SOURCE_SNAPSHOT_NAME]="$source_snapshot_basename"
  job[SOURCE_SNAPSHOT]="${SCHEDULE_SOURCE_ROOT[$schedule_job_id]}@${source_snapshot_basename}"
  job[PREVIOUS_SNAPSHOT_NAME]="$previous_basename"
  job[ATTEMPT_COUNT]="0"
  job[RETRY_AT]="0"
  job[LAST_ERROR]=""
  job[LAST_MESSAGE]="Queued to resume an interrupted scheduled send window."
  job[WORKER_PID]=""
  job[PROGRESS_PERCENT]="5"
  job[MEMBER_COUNT]="0"
  job[COMPLETES_SCHEDULE_WINDOW]="1"
  job[RESUME_ONLY]="1"

  job_file="${OPS_JOBS_DIR}/$(printf '%010d-%s.job' "$requested_epoch" "${job[JOB_ID]}")"
  job_write "$job_file" job
}

set_job_success_purge_after() {
  local assoc_name="$1"
  local ttl="${2:-$JOB_SUCCESS_TTL_SECONDS}"
  # shellcheck disable=SC2178
  local -n job_ref="$assoc_name"
  local now_epoch

  now_epoch="$(date +%s)"
  job_ref[PURGE_AFTER_EPOCH]="$(( now_epoch + ttl ))"
}

job_is_retry_ready() {
  local state="$1"
  local retry_at="$2"
  local now_epoch="$3"

  if [[ "$state" == "queued" ]]; then
    return 0
  fi

  if [[ "$state" == "retry_wait" ]]; then
    [[ "$retry_at" =~ ^[0-9]+$ ]] || retry_at=0
    (( retry_at <= now_epoch ))
    return
  fi

  return 1
}

job_lock_dir_for_id() {
  local job_id="$1"
  printf '%s/job-%s.lockdir' "$JOB_LOCKS_DIR" "$job_id"
}

acquire_job_claim() {
  local job_id="$1"
  local lock_dir
  lock_dir="$(job_lock_dir_for_id "$job_id")"
  mkdir "$lock_dir" 2>/dev/null
}

release_job_claim() {
  local job_id="$1"
  rm -rf "$(job_lock_dir_for_id "$job_id")" >/dev/null 2>&1 || true
}

process_alive() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1
}

send_worker_lock_count() {
  find "$SEND_WORKER_RUNTIME_DIR" -maxdepth 1 -mindepth 1 -type d -name 'worker-*.lockdir' 2>/dev/null | wc -l | tr -d ' '
}

send_worker_slot_available() {
  local count
  count="$(send_worker_lock_count)"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  (( count < SEND_MAX_PARALLEL ))
}

delete_worker_running() {
  delete_queue_daemon_running
}

shared_send_log_safe_to_compact() {
  local count

  count="$(send_worker_lock_count)"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  (( count == 0 )) || return 1
  ! delete_worker_running
}

compact_shared_send_log_if_safe() {
  shared_send_log_safe_to_compact || return 0
  zfsas_log_prepare_for_append "$LOG_FILE" "$LOG_ARCHIVE_FILE" "$SEND_LOG_MAX_BYTES" 800 20 "$SEND_LOG_ARCHIVE_MAX_BYTES"
}

prep_lock_dir_for_pool() {
  local pool="$1"
  printf '%s/pool-%s.lockdir' "$PREP_LOCKS_DIR" "$(printf '%s' "$pool" | tr -c 'A-Za-z0-9._-' '_')"
}

acquire_pool_prep_lock() {
  local pool="$1"
  local lock_dir pid_file pid

  lock_dir="$(prep_lock_dir_for_pool "$pool")"
  pid_file="${lock_dir}/pid"

  if mkdir "$lock_dir" 2>/dev/null; then
    printf '%s\n' "$$" > "$pid_file" 2>/dev/null || true
    return 0
  fi

  pid="$(sed -n '1p' "$pid_file" 2>/dev/null || true)"
  if ! process_alive "$pid"; then
    rm -rf "$lock_dir" >/dev/null 2>&1 || true
    if mkdir "$lock_dir" 2>/dev/null; then
      printf '%s\n' "$$" > "$pid_file" 2>/dev/null || true
      return 0
    fi
  fi

  return 1
}

release_pool_prep_lock() {
  local pool="$1"
  rm -rf "$(prep_lock_dir_for_pool "$pool")" >/dev/null 2>&1 || true
}

autosnapshot_run_active() {
  local pid=""

  [[ -f "$AUTOSNAPSHOT_ACTIVE_FILE" ]] || return 1
  pid="$(sed -n 's/^PID=//p' "$AUTOSNAPSHOT_ACTIVE_FILE" 2>/dev/null | head -n 1)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" >/dev/null 2>&1; then
    return 0
  fi

  rm -f "$AUTOSNAPSHOT_ACTIVE_FILE" >/dev/null 2>&1 || true
  return 1
}

snapshot_userrefs_count() {
  local snapshot="$1"
  local value

  value="$(zfs get -H -p -o value userrefs "$snapshot" 2>/dev/null || true)"
  [[ "$value" =~ ^[0-9]+$ ]] || value=0
  printf '%s' "$value"
}

snapshot_has_clones() {
  local snapshot="$1"
  local clones

  clones="$(zfs get -H -o value clones "$snapshot" 2>/dev/null || true)"
  clones="$(trim "$clones")"
  [[ -n "$clones" && "$clones" != "-" ]]
}

snapshot_written_bytes() {
  local snapshot="$1"
  local value

  value="$(zfs get -H -p -o value written "$snapshot" 2>/dev/null || true)"
  [[ "$value" =~ ^[0-9]+$ ]] || value=0
  printf '%s' "$value"
}

clear_send_cleanup_caches() {
  SEND_DATASET_SNAPSHOT_LINES_ASC=()
  SEND_DATASET_SNAPSHOT_LINES_DESC=()
  SEND_SNAPSHOT_CREATION_MAP=()
  SEND_SNAPSHOT_WRITTEN_MAP=()
  SEND_SNAPSHOT_USERREFS_MAP=()
  SEND_SNAPSHOT_HAS_CLONES_MAP=()
  SEND_SNAPSHOT_GUID_MAP=()
  SEND_SNAPSHOT_CREATETXG_MAP=()
  SEND_CHECKPOINT_RECLAIM_CACHE=()
  SEND_DESTINATION_DATASETS_BY_SCHEDULE=()
  SEND_DESTINATION_DATASETS_BY_POOL=()
  SEND_EPOCH_DAY_KEY_CACHE=()
  SEND_EPOCH_WEEK_KEY_CACHE=()
  reset_send_protected_basename_cache
  delete_queue_reset_index
}

load_send_dataset_snapshot_cache() {
  local dataset="$1"
  local metadata snap property value asc_lines="" desc_lines="" listed_snap
  local -A creation_map=()

  if [[ -n "${SEND_DATASET_SNAPSHOT_LINES_ASC[$dataset]+set}" ]]; then
    return 0
  fi

  metadata="$(zfs get -H -p -d 1 -o name,property,value -t snapshot creation,written,userrefs,clones,guid,createtxg "$dataset" 2>/dev/null || true)"

  while IFS=$'\t' read -r snap property value; do
    [[ -n "$snap" && -n "$property" ]] || continue
    [[ "$snap" == *"@"* ]] || continue
    [[ "${snap%@*}" == "$dataset" ]] || continue

    case "$property" in
      creation)
        creation_map["$snap"]="$value"
        SEND_SNAPSHOT_CREATION_MAP["$snap"]="$value"
        ;;
      written)
        SEND_SNAPSHOT_WRITTEN_MAP["$snap"]="$value"
        ;;
      userrefs)
        SEND_SNAPSHOT_USERREFS_MAP["$snap"]="$value"
        ;;
      clones)
        value="$(trim "$value")"
        if [[ -n "$value" && "$value" != "-" ]]; then
          SEND_SNAPSHOT_HAS_CLONES_MAP["$snap"]="1"
        else
          SEND_SNAPSHOT_HAS_CLONES_MAP["$snap"]="0"
        fi
        ;;
      guid)
        SEND_SNAPSHOT_GUID_MAP["$snap"]="$value"
        ;;
      createtxg)
        SEND_SNAPSHOT_CREATETXG_MAP["$snap"]="$value"
        ;;
    esac
  done <<< "$metadata"

  if (( ${#creation_map[@]} > 0 )); then
    while IFS= read -r listed_snap; do
      [[ -n "$listed_snap" ]] || continue
      asc_lines+="${listed_snap}"$'\t'"${creation_map[$listed_snap]}"$'\n'
    done < <(printf '%s\n' "${!creation_map[@]}")
    asc_lines="$(printf '%s' "$asc_lines" | LC_ALL=C sort -t $'\t' -k2,2n || true)"
    desc_lines="$(printf '%s' "$asc_lines" | awk '{ lines[NR] = $0 } END { for (i = NR; i > 0; i--) print lines[i] }' || true)"
  fi

  SEND_DATASET_SNAPSHOT_LINES_ASC["$dataset"]="$asc_lines"
  SEND_DATASET_SNAPSHOT_LINES_DESC["$dataset"]="$desc_lines"
}

send_snapshot_written_bytes_cached() {
  local snapshot="$1"
  local dataset value
  dataset="${snapshot%@*}"
  load_send_dataset_snapshot_cache "$dataset"
  value="${SEND_SNAPSHOT_WRITTEN_MAP[$snapshot]:-}"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s' "$value"
    return 0
  fi
  snapshot_written_bytes "$snapshot"
}

send_snapshot_userrefs_count_cached() {
  local snapshot="$1"
  local dataset value
  dataset="${snapshot%@*}"
  load_send_dataset_snapshot_cache "$dataset"
  value="${SEND_SNAPSHOT_USERREFS_MAP[$snapshot]:-}"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s' "$value"
    return 0
  fi
  snapshot_userrefs_count "$snapshot"
}

send_snapshot_has_clones_cached() {
  local snapshot="$1"
  local dataset value
  dataset="${snapshot%@*}"
  load_send_dataset_snapshot_cache "$dataset"
  value="${SEND_SNAPSHOT_HAS_CLONES_MAP[$snapshot]:-}"
  if [[ "$value" == "1" ]]; then
    return 0
  fi
  if [[ "$value" == "0" ]]; then
    return 1
  fi
  snapshot_has_clones "$snapshot"
}

zfs_get_snapshot_props_cached() {
  local snapshot="$1"
  local result_name="$2"
  local dataset creation guid createtxg
  local -n result_ref="$result_name"

  dataset="${snapshot%@*}"
  load_send_dataset_snapshot_cache "$dataset"

  creation="${SEND_SNAPSHOT_CREATION_MAP[$snapshot]:-}"
  guid="${SEND_SNAPSHOT_GUID_MAP[$snapshot]:-}"
  createtxg="${SEND_SNAPSHOT_CREATETXG_MAP[$snapshot]:-}"

  if [[ -n "$guid" ]]; then
    result_ref=()
    [[ -n "$creation" ]] && result_ref[creation]="$creation"
    [[ -n "$guid" ]] && result_ref[guid]="$guid"
    [[ -n "$createtxg" ]] && result_ref[createtxg]="$createtxg"
    return 0
  fi

  zfs_get_snapshot_props "$snapshot" "$result_name"
}

send_day_key_for_epoch() {
  local epoch="$1"
  local key="${SEND_EPOCH_DAY_KEY_CACHE[$epoch]:-}"
  if [[ -n "$key" ]]; then
    printf '%s' "$key"
    return 0
  fi
  key="$(date -d @"$epoch" +%Y-%m-%d)"
  SEND_EPOCH_DAY_KEY_CACHE["$epoch"]="$key"
  printf '%s' "$key"
}

send_week_key_for_epoch() {
  local epoch="$1"
  local key="${SEND_EPOCH_WEEK_KEY_CACHE[$epoch]:-}"
  if [[ -n "$key" ]]; then
    printf '%s' "$key"
    return 0
  fi
  key="$(date -d @"$epoch" +%Y-%W)"
  SEND_EPOCH_WEEK_KEY_CACHE["$epoch"]="$key"
  printf '%s' "$key"
}

send_retention_keep_all_seconds() {
  printf '%s' $(( SEND_KEEP_ALL_FOR_DAYS * 86400 ))
}

send_retention_keep_daily_until_seconds() {
  printf '%s' $(( SEND_KEEP_DAILY_UNTIL_DAYS * 86400 ))
}

send_retention_keep_weekly_until_seconds() {
  printf '%s' $(( SEND_KEEP_WEEKLY_UNTIL_DAYS * 86400 ))
}

get_pool_freeing() {
  local value
  value="$(zpool get -H -o value freeing "$1" 2>/dev/null || true)"
  [[ "$value" =~ ^[0-9]+$ ]] || value=0
  printf '%s' "$value"
}

get_pool_effective_avail() {
  local pool="$1"
  local avail freeing

  avail="$(zfs list -H -p -o avail "$pool" 2>/dev/null || true)"
  [[ "$avail" =~ ^[0-9]+$ ]] || {
    echo ""
    return 1
  }

  freeing="$(get_pool_freeing "$pool")"
  echo $(( avail + freeing ))
}

emit_dataset_capacity_constraints() {
  local dataset="$1"
  local pool="${dataset%%/*}"
  local pool_effective current quota_headroom refquota_headroom

  pool_effective="$(get_pool_effective_avail "$pool")"
  [[ "$pool_effective" =~ ^[0-9]+$ ]] && printf 'pool:%s\t%s\n' "$pool" "$pool_effective"

  current="$dataset"
  while :; do
    quota_headroom="$(get_dataset_quota_headroom "$current" || true)"
    [[ "$quota_headroom" =~ ^[0-9]+$ ]] && printf 'quota:%s\t%s\n' "$current" "$quota_headroom"

    [[ "$current" == "$pool" ]] && break
    current="${current%/*}"
  done

  refquota_headroom="$(get_dataset_refquota_headroom "$dataset" || true)"
  [[ "$refquota_headroom" =~ ^[0-9]+$ ]] && printf 'refquota:%s\t%s\n' "$dataset" "$refquota_headroom"
}

get_dataset_quota_headroom() {
  local dataset="$1"
  local quota_limit quota_used

  quota_limit="$(zfs get -H -p -o value quota "$dataset" 2>/dev/null || true)"
  quota_used="$(zfs get -H -p -o value usedbydataset "$dataset" 2>/dev/null || true)"
  [[ "$quota_limit" =~ ^[1-9][0-9]*$ && "$quota_used" =~ ^[0-9]+$ ]] || return 1

  if (( quota_limit <= quota_used )); then
    echo 0
  else
    echo $(( quota_limit - quota_used ))
  fi
}

get_dataset_refquota_headroom() {
  local dataset="$1"
  local refquota_limit refquota_used

  refquota_limit="$(zfs get -H -p -o value refquota "$dataset" 2>/dev/null || true)"
  refquota_used="$(zfs get -H -p -o value referenced "$dataset" 2>/dev/null || true)"
  [[ "$refquota_limit" =~ ^[1-9][0-9]*$ && "$refquota_used" =~ ^[0-9]+$ ]] || return 1

  if (( refquota_limit <= refquota_used )); then
    echo 0
  else
    echo $(( refquota_limit - refquota_used ))
  fi
}

get_dataset_active_constraints() {
  local dataset="$1"
  local delta_map_name="$2"
  local effective_var_name="$3"
  local active_constraints_var_name="$4"
  local token base adjusted best_value=""
  local -n delta_ref="$delta_map_name"
  local -n active_constraints_ref="$active_constraints_var_name"

  active_constraints_ref=()

  while IFS=$'\t' read -r token base; do
    [[ -n "$token" && "$base" =~ ^[0-9]+$ ]] || continue
    adjusted=$(( base + ${delta_ref[$token]:-0} ))
    (( adjusted >= 0 )) || adjusted=0

    if [[ -z "$best_value" ]] || (( adjusted < best_value )); then
      best_value="$adjusted"
      active_constraints_ref=("$token")
    elif (( adjusted == best_value )); then
      active_constraints_ref+=("$token")
    fi
  done < <(emit_dataset_capacity_constraints "$dataset")

  [[ -n "$best_value" ]] || {
    printf -v "$effective_var_name" ''
    return 1
  }

  printf -v "$effective_var_name" '%s' "$best_value"
  return 0
}

nearest_existing_dataset_ancestor() {
  local dataset="$1"
  local current="$dataset"

  while [[ -n "$current" ]]; do
    if zfs list -H -o name "$current" >/dev/null 2>&1; then
      echo "$current"
      return 0
    fi

    [[ "$current" == */* ]] || break
    current="${current%/*}"
  done

  echo ""
  return 1
}

constraints_are_pool_only() {
  local constraints_name="$1"
  local -n constraints_ref="$constraints_name"
  local constraint

  (( ${#constraints_ref[@]} > 0 )) || return 1
  for constraint in "${constraints_ref[@]}"; do
    [[ "$constraint" == pool:* ]] || return 1
  done
  return 0
}

should_wait_for_post_delete_recheck() {
  local dataset="$1"
  local constraints_name="$2"
  local after_effective="$3"
  local before_effective="$4"
  local pool freeing

  (( POST_DELETE_RECHECK_WAIT_SECONDS > 0 )) || return 1
  constraints_are_pool_only "$constraints_name" || return 0

  pool="${dataset%%/*}"
  freeing="$(get_pool_freeing "$pool")"
  if [[ "$freeing" =~ ^[0-9]+$ ]]; then
    (( freeing > 0 )) && return 1
    (( after_effective != before_effective )) && return 1
  fi
  return 0
}

dataset_is_within_scope() {
  local dataset="$1"
  local scope="$2"
  [[ "$dataset" == "$scope" || "$dataset" == "$scope/"* ]]
}

candidate_affects_constraint() {
  local dataset="$1"
  local constraint="$2"
  local scope

  case "$constraint" in
    pool:*) [[ "${dataset%%/*}" == "${constraint#pool:}" ]] ;;
    quota:*) scope="${constraint#quota:}"; dataset_is_within_scope "$dataset" "$scope" ;;
    refquota:*) return 1 ;;
    *) return 1 ;;
  esac
}

candidate_affects_any_constraint() {
  local dataset="$1"
  local constraints_name="$2"
  local -n constraints_ref="$constraints_name"
  local constraint

  for constraint in "${constraints_ref[@]}"; do
    if candidate_affects_constraint "$dataset" "$constraint"; then
      return 0
    fi
  done
  return 1
}

format_constraint_list() {
  local constraints_name="$1"
  local -n constraints_ref="$constraints_name"
  local joined=""
  local constraint

  for constraint in "${constraints_ref[@]}"; do
    [[ -n "$joined" ]] && joined+=", "
    joined+="$constraint"
  done
  printf '%s' "$joined"
}

run_pipeline_with_status() {
  local description="$1"
  local base_snapshot="$2"
  local snapshot="$3"
  local destination="$4"
  local pipeline_rc=0
  local send_rc=0
  local receive_rc=0

  is_valid_snapshot_name "$snapshot" || {
    log "Refusing pipeline for invalid snapshot name: $snapshot"
    return 1
  }
  is_valid_dataset_name "$destination" || {
    log "Refusing pipeline for invalid destination dataset: $destination"
    return 1
  }
  if [[ -n "$base_snapshot" ]]; then
    is_valid_snapshot_name "$base_snapshot" || {
      log "Refusing pipeline for invalid base snapshot: $base_snapshot"
      return 1
    }
  fi

  log "$description"
  if [[ -n "$base_snapshot" ]]; then
    zfs send -I "$base_snapshot" "$snapshot" | zfs receive -uF "$destination"
    pipeline_rc=$?
    send_rc=${PIPESTATUS[0]:-0}
    receive_rc=${PIPESTATUS[1]:-0}
    if (( pipeline_rc != 0 )); then
      log "Send pipeline failed: mode=incremental base=${base_snapshot} snapshot=${snapshot} destination=${destination} send_exit=${send_rc} receive_exit=${receive_rc}"
      return 1
    fi
  else
    zfs send "$snapshot" | zfs receive -uF "$destination"
    pipeline_rc=$?
    send_rc=${PIPESTATUS[0]:-0}
    receive_rc=${PIPESTATUS[1]:-0}
    if (( pipeline_rc != 0 )); then
      log "Send pipeline failed: mode=full snapshot=${snapshot} destination=${destination} send_exit=${send_rc} receive_exit=${receive_rc}"
      return 1
    fi
  fi

  return 0
}

snapshot_exists() {
  zfs list -H -o name -t snapshot "$1" >/dev/null 2>&1
}

dataset_exists() {
  zfs list -H -o name "$1" >/dev/null 2>&1
}

dataset_type() {
  local value
  value="$(zfs list -H -o type "$1" 2>/dev/null || true)"
  value="$(trim "$value")"
  printf '%s' "$value"
}

dataset_has_any_snapshots() {
  local dataset="$1"
  local snapshot_name

  while IFS= read -r snapshot_name; do
    [[ "$snapshot_name" == "${dataset}@"* ]] || continue
    return 0
  done < <(zfs list -H -t snapshot -o name -r "$dataset" 2>/dev/null || true)

  return 1
}

zfs_get_snapshot_props() {
  local snapshot="$1"
  local result_name="$2"
  # shellcheck disable=SC2178  # nameref target is an associative array in callers
  local -n result_ref="$result_name"
  local line property value

  result_ref=()
  while IFS=$'\t' read -r _ property value _; do
    [[ -n "$property" ]] || continue
    result_ref["$property"]="$value"
  done < <(zfs get -H -p -o name,property,value,source creation,guid,createtxg "$snapshot" 2>/dev/null || true)

  [[ -n "${result_ref[guid]:-}" ]]
}

job_prefix_for_schedule() {
  local schedule_job_id="$1"
  printf '%s' "${SCHEDULE_PREFIX[$schedule_job_id]:-${SEND_SNAPSHOT_PREFIX}${schedule_job_id}-}"
}

send_basename_matches_schedule() {
  local basename="$1"
  local schedule_job_id="$2"
  local prefix
  prefix="$(job_prefix_for_schedule "$schedule_job_id")"
  [[ "$basename" == "$prefix"* ]]
}

parse_send_checkpoint_schedule_id() {
  local basename="$1"
  local remainder
  [[ "$basename" == ${SEND_SNAPSHOT_PREFIX}* ]] || return 1
  remainder="${basename#"${SEND_SNAPSHOT_PREFIX}"}"
  [[ "$remainder" =~ ^([a-f0-9]{12})- ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}

schedule_destination_pool() {
  local schedule_job_id="$1"
  local dest_root="${SCHEDULE_DEST_ROOT[$schedule_job_id]:-}"
  [[ -n "$dest_root" ]] || return 1
  printf '%s' "${dest_root%%/*}"
}

list_tree_datasets() {
  local root_dataset="$1"
  local include_children="$2"
  if [[ "$include_children" == "1" ]]; then
    zfs list -H -o name -t filesystem,volume -r "$root_dataset" 2>/dev/null || true
  else
    printf '%s\n' "$root_dataset"
  fi
}

build_members_for_job() {
  local assoc_name="$1"
  local basename="$2"
  # shellcheck disable=SC2178
  local -n job_ref="$assoc_name"
  local source_root dest_root include_children source_dataset relative dest_dataset index=0 key

  source_root="$(job_get "$assoc_name" SOURCE_ROOT)"
  dest_root="$(job_get "$assoc_name" DESTINATION_ROOT)"
  include_children="$(job_get "$assoc_name" INCLUDE_CHILDREN 0)"

  for key in "${!job_ref[@]}"; do
    [[ "$key" == MEMBER_* ]] && unset 'job_ref[$key]'
  done

  while IFS= read -r source_dataset; do
    [[ -n "$source_dataset" ]] || continue
    if [[ "$source_dataset" == "$source_root" ]]; then
      dest_dataset="$dest_root"
    else
      relative="${source_dataset#"${source_root}"/}"
      dest_dataset="${dest_root}/${relative}"
    fi

    job_ref["MEMBER_${index}_SOURCE"]="$source_dataset"
    job_ref["MEMBER_${index}_DESTINATION"]="$dest_dataset"
    job_ref["MEMBER_${index}_SNAPSHOT"]="${source_dataset}@${basename}"
    index=$((index + 1))
  done < <(list_tree_datasets "$source_root" "$include_children")

  job_ref["MEMBER_COUNT"]="$index"
}

ensure_destination_parent_exists() {
  local dest="$1"
  local parent="${dest%/*}"
  local pool="${dest%%/*}"

  dataset_exists "$pool" || return 1
  if [[ "$parent" != "$pool" ]] && ! dataset_exists "$parent"; then
    zfs create -p "$parent"
  fi
}

ensure_destination_path_exists() {
  local dest="$1"
  if dataset_exists "$dest"; then
    return 0
  fi
  ensure_destination_parent_exists "$dest" || return 1
  dataset_exists "$dest" || zfs create -p "$dest"
}

find_latest_common_basename_for_member() {
  local source_dataset="$1"
  local dest_dataset="$2"
  local prefix="$3"
  local result_name_var="$4"
  local source_inventory dest_inventory snap_name snap_epoch snap_base
  local -A dest_basenames=()

  printf -v "$result_name_var" ''
  dataset_exists "$dest_dataset" || return 0

  source_inventory="$(zfs list -H -p -t snapshot -o name,creation -d 1 "$source_dataset" 2>/dev/null | grep -F "@${prefix}" | sort -t $'\t' -k2,2n || true)"
  dest_inventory="$(zfs list -H -p -t snapshot -o name,creation -d 1 "$dest_dataset" 2>/dev/null | grep -F "@${prefix}" | sort -t $'\t' -k2,2n || true)"

  while IFS=$'\t' read -r snap_name snap_epoch; do
    [[ -n "$snap_name" && -n "$snap_epoch" ]] || continue
    dest_basenames["${snap_name##*@}"]="$snap_epoch"
  done <<< "$dest_inventory"

  while IFS=$'\t' read -r snap_name snap_epoch; do
    [[ -n "$snap_name" && -n "$snap_epoch" ]] || continue
    snap_base="${snap_name##*@}"
    if [[ -n "${dest_basenames[$snap_base]:-}" ]]; then
      printf -v "$result_name_var" '%s' "$snap_base"
    fi
  done <<< "$source_inventory"
}

find_latest_common_snapshot_for_target() {
  local source_dataset="$1"
  local dest_dataset="$2"
  local target_basename="$3"
  local result_var="$4"
  local snap_name snap_epoch snap_base latest_common=""
  local -A dest_map=()

  printf -v "$result_var" ''
  dataset_exists "$dest_dataset" || return 0

  while IFS=$'\t' read -r snap_name snap_epoch; do
    [[ -n "$snap_name" ]] || continue
    dest_map["${snap_name##*@}"]=1
  done < <(zfs list -H -p -s creation -t snapshot -o name,creation -d 1 "$dest_dataset" 2>/dev/null || true)

  while IFS=$'\t' read -r snap_name snap_epoch; do
    [[ -n "$snap_name" ]] || continue
    snap_base="${snap_name##*@}"
    if [[ -n "${dest_map[$snap_base]:-}" ]]; then
      latest_common="$snap_base"
    fi
    if [[ "$snap_base" == "$target_basename" ]]; then
      break
    fi
  done < <(zfs list -H -p -s creation -t snapshot -o name,creation -d 1 "$source_dataset" 2>/dev/null || true)

  printf -v "$result_var" '%s' "$latest_common"
}

job_list_basenames_for_root() {
  local root_dataset="$1"
  local prefix="$2"
  zfs list -H -p -r -t snapshot -o name,creation "$root_dataset" 2>/dev/null | grep -F "@${prefix}" || true
}

scheduled_job_protected_basenames() {
  local schedule_job_id="$1"
  local result_name="$2"
  local -n result_ref="$result_name"
  local file
  local -A job=()
  local basename

  result_ref=()
  while IFS= read -r file; do
    job_load "$file" job || continue
    [[ "$(job_get job JOB_TYPE)" == "send" ]] || continue
    [[ "$(job_get job JOB_MODE)" == "scheduled" ]] || continue
    [[ "$(job_get job SCHEDULE_JOB_ID)" == "$schedule_job_id" ]] || continue
    job_state_is_active "$(job_get job STATE)" || continue

    basename="$(job_get job SOURCE_SNAPSHOT_NAME)"
    [[ -n "$basename" ]] && result_ref["$basename"]=1
    basename="$(job_get job PREVIOUS_SNAPSHOT_NAME)"
    [[ -n "$basename" ]] && result_ref["$basename"]=1
  done < <(list_job_files)
}

all_scheduled_job_protected_basenames() {
  local result_name="$1"
  # shellcheck disable=SC2178
  local -n result_ref="$result_name"
  local schedule_job_id basename
  local -A protected=()

  result_ref=()

  for schedule_job_id in "${SCHEDULE_JOB_IDS[@]}"; do
    protected=()
    scheduled_job_protected_basenames "$schedule_job_id" protected
    for basename in "${!protected[@]}"; do
      result_ref["$basename"]=1
    done

    basename=""
    latest_checkpoint_basename_for_schedule "$schedule_job_id" basename
    [[ -n "$basename" ]] && result_ref["$basename"]=1
  done
}

reset_send_protected_basename_cache() {
  SEND_PROTECTED_BASENAME_CACHE=()
  SEND_PROTECTED_BASENAME_CACHE_LOADED=0
}

cached_all_scheduled_job_protected_basenames() {
  local result_name="$1"
  # shellcheck disable=SC2178
  local -n result_ref="$result_name"
  local basename

  if (( SEND_PROTECTED_BASENAME_CACHE_LOADED == 0 )); then
    SEND_PROTECTED_BASENAME_CACHE=()
    all_scheduled_job_protected_basenames SEND_PROTECTED_BASENAME_CACHE
    SEND_PROTECTED_BASENAME_CACHE_LOADED=1
  fi

  result_ref=()
  for basename in "${!SEND_PROTECTED_BASENAME_CACHE[@]}"; do
    result_ref["$basename"]=1
  done
}

find_oldest_deletable_checkpoint_for_schedule() {
  local schedule_job_id="$1"
  local constraints_name="$2"
  local result_basename_var="$3"
  local result_epoch_var="$4"
  local -n constraints_ref="$constraints_name"
  local prefix dest_root line snap_name snap_epoch snap_dataset snap_base newest_base="" newest_epoch=0
  local oldest_base="" oldest_epoch=0 affects=0 constraint member_dataset
  local -A base_epoch=()
  local -A base_datasets=()
  local -A protected=()

  printf -v "$result_basename_var" ''
  printf -v "$result_epoch_var" '0'

  dest_root="${SCHEDULE_DEST_ROOT[$schedule_job_id]:-}"
  prefix="$(job_prefix_for_schedule "$schedule_job_id")"
  [[ -n "$dest_root" ]] || return 1
  dataset_exists "$dest_root" || return 1

  while IFS=$'\t' read -r snap_name snap_epoch; do
    [[ -n "$snap_name" && -n "$snap_epoch" ]] || continue
    snap_dataset="${snap_name%@*}"
    snap_base="${snap_name##*@}"
    if [[ -z "${base_epoch[$snap_base]:-}" ]] || (( snap_epoch < base_epoch[$snap_base] )); then
      base_epoch[$snap_base]="$snap_epoch"
    fi
    base_datasets[$snap_base]="${base_datasets[$snap_base]:-} ${snap_dataset}"
    if (( snap_epoch >= newest_epoch )); then
      newest_epoch="$snap_epoch"
      newest_base="$snap_base"
    fi
  done < <(job_list_basenames_for_root "$dest_root" "$prefix")

  scheduled_job_protected_basenames "$schedule_job_id" protected

  for snap_base in "${!base_epoch[@]}"; do
    [[ "$snap_base" == "$newest_base" ]] && continue
    [[ -z "${protected[$snap_base]:-}" ]] || continue

    affects=0
    for member_dataset in ${base_datasets[$snap_base]:-}; do
      if candidate_affects_any_constraint "$member_dataset" "$constraints_name"; then
        affects=1
        break
      fi
    done
    (( affects == 1 )) || continue

    if [[ -z "$oldest_base" ]] || (( ${base_epoch[$snap_base]} < oldest_epoch )); then
      oldest_base="$snap_base"
      oldest_epoch="${base_epoch[$snap_base]}"
    fi
  done

  printf -v "$result_basename_var" '%s' "$oldest_base"
  printf -v "$result_epoch_var" '%s' "$oldest_epoch"
  [[ -n "$oldest_base" ]]
}

find_oldest_deletable_destination_snapshot_for_schedule() {
  local schedule_job_id="$1"
  local constraints_name="$2"
  local result_snap_var="$3"
  local result_epoch_var="$4"
  local dest_root snap_name snap_epoch snap_dataset snap_base newest_base="" oldest_snap="" oldest_epoch=0
  local userrefs
  local -A protected=()

  printf -v "$result_snap_var" ''
  printf -v "$result_epoch_var" '0'

  dest_root="${SCHEDULE_DEST_ROOT[$schedule_job_id]:-}"
  [[ -n "$dest_root" ]] || return 1
  dataset_exists "$dest_root" || return 1

  cached_all_scheduled_job_protected_basenames protected

  while IFS=$'\t' read -r snap_name snap_epoch; do
    [[ -n "$snap_name" && -n "$snap_epoch" ]] || continue
    snap_dataset="${snap_name%@*}"
    snap_base="${snap_name##*@}"

    candidate_affects_any_constraint "$snap_dataset" "$constraints_name" || continue
    [[ -z "${protected[$snap_base]:-}" ]] || continue

    userrefs="$(snapshot_userrefs_count "$snap_name")"
    (( userrefs == 0 )) || continue
    snapshot_has_clones "$snap_name" && continue

    if [[ -z "$oldest_snap" ]] || (( snap_epoch < oldest_epoch )); then
      oldest_snap="$snap_name"
      oldest_epoch="$snap_epoch"
    fi
  done < <(
    while IFS= read -r snap_dataset; do
      [[ -n "$snap_dataset" ]] || continue
      load_send_dataset_snapshot_cache "$snap_dataset"
      printf '%s' "${SEND_DATASET_SNAPSHOT_LINES_ASC[$snap_dataset]}"
    done < <(list_existing_destination_datasets_for_schedule "$schedule_job_id")
  )

  printf -v "$result_snap_var" '%s' "$oldest_snap"
  printf -v "$result_epoch_var" '%s' "$oldest_epoch"
  [[ -n "$oldest_snap" ]]
}

find_oldest_deletable_destination_snapshot_for_pool() {
  local pool="$1"
  local constraints_name="$2"
  local result_snap_var="$3"
  local result_epoch_var="$4"
  local -n constraints_ref="$constraints_name"
  local dataset snap_name snap_epoch snap_dataset snap_base oldest_snap="" oldest_epoch=0
  local userrefs schedule_job_id
  local -A protected=()
  local -A seen_snapshots=()

  printf -v "$result_snap_var" ''
  printf -v "$result_epoch_var" '0'

  cached_all_scheduled_job_protected_basenames protected

  while IFS= read -r dataset; do
    [[ -n "$dataset" ]] || continue
    load_send_dataset_snapshot_cache "$dataset"
    while IFS=$'\t' read -r snap_name snap_epoch; do
      [[ -n "$snap_name" && -n "$snap_epoch" ]] || continue
      [[ -z "${seen_snapshots[$snap_name]:-}" ]] || continue
      seen_snapshots["$snap_name"]=1

      snap_dataset="${snap_name%@*}"
      snap_base="${snap_name##*@}"

      candidate_affects_any_constraint "$snap_dataset" "$constraints_name" || continue
      [[ -z "${protected[$snap_base]:-}" ]] || continue
      userrefs="$(send_snapshot_userrefs_count_cached "$snap_name")"
      (( userrefs == 0 )) || continue
      send_snapshot_has_clones_cached "$snap_name" && continue

      schedule_job_id="$(parse_send_checkpoint_schedule_id "$snap_base" 2>/dev/null || true)"
      if [[ -n "$schedule_job_id" ]]; then
        snapshot_delete_checkpoint_job_exists "$schedule_job_id" "$snap_base" && continue
      else
        snapshot_delete_job_exists_for_snapshot "$snap_name" && continue
      fi

      if [[ -z "$oldest_snap" ]] || (( snap_epoch < oldest_epoch )); then
        oldest_snap="$snap_name"
        oldest_epoch="$snap_epoch"
      fi
    done <<< "${SEND_DATASET_SNAPSHOT_LINES_ASC[$dataset]}"
  done < <(list_existing_destination_datasets_for_pool "$pool")

  printf -v "$result_snap_var" '%s' "$oldest_snap"
  printf -v "$result_epoch_var" '%s' "$oldest_epoch"
  [[ -n "$oldest_snap" ]]
}

checkpoint_exists_for_member() {
  local dataset="$1"
  local basename="$2"
  snapshot_exists "${dataset}@${basename}"
}

wait_for_post_delete_recheck_if_needed() {
  local capacity_dataset="$1"
  local constraints_name="$2"
  local before_effective="$3"
  local after_effective="$4"
  local waited=0
  local new_effective="$after_effective"

  if (( after_effective > before_effective )); then
    echo "$after_effective"
    return 0
  fi

  if ! should_wait_for_post_delete_recheck "$capacity_dataset" "$constraints_name" "$after_effective" "$before_effective"; then
    echo "$after_effective"
    return 0
  fi

  while (( waited < POST_DELETE_RECHECK_WAIT_SECONDS )); do
    sleep "$POST_DELETE_RECHECK_INTERVAL_SECONDS"
    waited=$((waited + POST_DELETE_RECHECK_INTERVAL_SECONDS))
    new_effective="$(get_dataset_effective_avail "$capacity_dataset" NO_CONSTRAINT_RECLAIM || true)"
    [[ "$new_effective" =~ ^[0-9]+$ ]] || break
    if (( new_effective > before_effective )); then
      echo "$new_effective"
      return 0
    fi
  done

  echo "$new_effective"
  return 0
}

# shellcheck disable=SC2034
declare -A NO_CONSTRAINT_RECLAIM=()

get_dataset_effective_avail() {
  local dataset="$1"
  local delta_name="${2:-NO_CONSTRAINT_RECLAIM}"
  local effective
  # shellcheck disable=SC2034
  local -a constraints=()

  get_dataset_active_constraints "$dataset" "$delta_name" effective constraints || {
    echo ""
    return 1
  }
  echo "$effective"
}

delete_checkpoint_basename_across_tree() {
  local root_dataset="$1"
  local basename="$2"
  local prefix="$3"
  local side_label="$4"
  local snap_name snap_epoch snapshots=()

  while IFS=$'\t' read -r snap_name snap_epoch; do
    [[ -n "$snap_name" ]] || continue
    [[ "${snap_name##*@}" == "$basename" ]] || continue
    snapshots+=("$snap_name")
  done < <(job_list_basenames_for_root "$root_dataset" "$prefix")

  if (( ${#snapshots[@]} == 0 )); then
    return 0
  fi

  for snap_name in "${snapshots[@]}"; do
    log "Deleting ${side_label} send checkpoint: $snap_name"
    zfs destroy "$snap_name"
  done
}

delete_destination_snapshot() {
  local snapshot="$1"
  [[ -n "$snapshot" ]] || return 1
  log "Deleting destination snapshot: $snapshot"
  zfs destroy "$snapshot"
}

ensure_destination_space_for_schedule_job() {
  local schedule_job_id="$1"
  local dest_dataset="${SCHEDULE_DEST_ROOT[$schedule_job_id]}"
  local threshold="${SCHEDULE_THRESHOLD_BYTES[$schedule_job_id]}"
  local capacity_dataset effective after_effective candidate_snapshot
  # shellcheck disable=SC2034
  local active_constraints=()
  local low_constraints_display

  capacity_dataset="$(nearest_existing_dataset_ancestor "$dest_dataset")"
  [[ -n "$capacity_dataset" ]] || return 1

  while :; do
    get_dataset_active_constraints "$capacity_dataset" NO_CONSTRAINT_RECLAIM effective active_constraints || return 1
    (( effective >= threshold )) && return 0

    low_constraints_display="$(format_constraint_list active_constraints)"
    log "Destination ${dest_dataset} is below its free-space target: effective_avail=${effective} min_required=${threshold} active_constraints=${low_constraints_display}"

    candidate_snapshot=""
    local schedule_id best_id="" best_epoch=0 this_snapshot this_epoch
    for schedule_id in "${SCHEDULE_JOB_IDS[@]}"; do
      this_snapshot=""
      this_epoch=0
      if find_oldest_deletable_destination_snapshot_for_schedule "$schedule_id" active_constraints this_snapshot this_epoch; then
        if [[ -z "$best_id" ]] || (( this_epoch < best_epoch )); then
          best_id="$schedule_id"
          best_epoch="$this_epoch"
          candidate_snapshot="$this_snapshot"
        fi
      fi
    done

    [[ -n "$best_id" && -n "$candidate_snapshot" ]] || return 1

    log "Destination ${dest_dataset} low on space -> deleting oldest eligible destination snapshot ${candidate_snapshot} (selected from schedule ${best_id})"
    delete_destination_snapshot "$candidate_snapshot"

    after_effective="$(get_dataset_effective_avail "$capacity_dataset" NO_CONSTRAINT_RECLAIM || true)"
    [[ "$after_effective" =~ ^[0-9]+$ ]] || return 1
    after_effective="$(wait_for_post_delete_recheck_if_needed "$capacity_dataset" active_constraints "$effective" "$after_effective")"
    [[ "$after_effective" =~ ^[0-9]+$ ]] || return 1
  done
}

schedule_job_blocked() {
  local schedule_job_id="$1"
  local file
  local -A job=()
  local state

  while IFS= read -r file; do
    job_load "$file" job || continue
    [[ "$(job_get job JOB_TYPE)" == "send" ]] || continue
    [[ "$(job_get job JOB_MODE)" == "scheduled" ]] || continue
    [[ "$(job_get job SCHEDULE_JOB_ID)" == "$schedule_job_id" ]] || continue
    state="$(job_get job STATE)"
    if [[ "$state" == "queued" || "$state" == "running" || "$state" == "retry_wait" || "$state" == "failed" ]]; then
      return 0
    fi
  done < <(list_job_files)

  return 1
}

schedule_window_exists() {
  local schedule_job_id="$1"
  local window_key="$2"
  local file
  local -A job=()

  while IFS= read -r file; do
    job_load "$file" job || continue
    [[ "$(job_get job JOB_TYPE)" == "send" ]] || continue
    [[ "$(job_get job JOB_MODE)" == "scheduled" ]] || continue
    [[ "$(job_get job SCHEDULE_JOB_ID)" == "$schedule_job_id" ]] || continue
    [[ "$(job_get job WINDOW_KEY)" == "$window_key" ]] && return 0
  done < <(list_job_files)

  return 1
}

enqueue_scheduled_send_jobs_due() {
  local now_epoch="$1"
  local job_id frequency current_window last_completed_window requested_at requested_epoch job_file
  local resume_basename previous_basename
  local -A job=()

  load_schedule_state

  for job_id in "${SCHEDULE_JOB_IDS[@]}"; do
    frequency="${SCHEDULE_FREQUENCY[$job_id]}"
    current_window="$(frequency_window_key "$frequency" "$now_epoch")"
    [[ "$current_window" =~ ^[0-9]+$ ]] || continue

    last_completed_window="$(last_completed_schedule_window_key "$job_id")"
    [[ "$last_completed_window" =~ ^[0-9]+$ ]] || last_completed_window=0
    if (( last_completed_window >= current_window )); then
      continue
    fi

    schedule_job_blocked "$job_id" && continue

    schedule_window_exists "$job_id" "$current_window" && continue

    requested_epoch="$now_epoch"
    requested_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ' -r "$requested_epoch" 2>/dev/null || date -u +'%Y-%m-%dT%H:%M:%SZ')"

    resume_basename=""
    previous_basename=""
    if schedule_can_resume_current_window "$job_id" "$current_window" resume_basename previous_basename; then
      enqueue_resume_prepare_job "$job_id" "$current_window" "$requested_epoch" "$requested_at" "$resume_basename" "$previous_basename" || true
      continue
    fi

    job=()
    job[JOB_ID]="send-${job_id}-${current_window}"
    job[JOB_TYPE]="send"
    job[JOB_MODE]="scheduled"
    job[JOB_ACTION]="prepare"
    job[STATE]="queued"
    job[PHASE]="queued"
    job[REQUESTED_EPOCH]="$requested_epoch"
    job[REQUESTED_AT]="$requested_at"
    job[QUEUE_SORT]="$requested_epoch"
    job[WINDOW_KEY]="$current_window"
    job[SCHEDULE_JOB_ID]="$job_id"
    job[SOURCE_ROOT]="${SCHEDULE_SOURCE_ROOT[$job_id]}"
    job[DESTINATION_ROOT]="${SCHEDULE_DEST_ROOT[$job_id]}"
    job[INCLUDE_CHILDREN]="${SCHEDULE_INCLUDE_CHILDREN[$job_id]}"
    job[FREQUENCY]="$frequency"
    job[THRESHOLD]="${SCHEDULE_THRESHOLD_RAW[$job_id]}"
    job[THRESHOLD_BYTES]="${SCHEDULE_THRESHOLD_BYTES[$job_id]}"
    job[SNAPSHOT_PREFIX_BASE]="$SEND_SNAPSHOT_PREFIX"
    job[SNAPSHOT_PREFIX]="$(job_prefix_for_schedule "$job_id")"
    job[ATTEMPT_COUNT]="0"
    job[RETRY_AT]="0"
    job[LAST_ERROR]=""
    job[LAST_MESSAGE]="Queued by schedule."
    job[WORKER_PID]=""
    job[PROGRESS_PERCENT]="5"
    job[MEMBER_COUNT]="0"
    job[COMPLETES_SCHEDULE_WINDOW]="1"

    job_file="${OPS_JOBS_DIR}/$(printf '%010d-%s.job' "$requested_epoch" "send-${job_id}-${current_window}")"
    job_write "$job_file" job || continue
  done

  return 0
}

prune_old_jobs() {
  local keep_completed=100
  local now_epoch purge_after state file_mtime
  local file
  local -A job=()
  local complete_files=()
  local count=0

  now_epoch="$(date +%s)"

  while IFS= read -r file; do
    job_load "$file" job || continue
    state="$(job_get job STATE)"
    case "$state" in
      complete|skipped)
        purge_after="$(job_get job PURGE_AFTER_EPOCH 0)"
        if [[ "$purge_after" =~ ^[0-9]+$ ]] && (( purge_after > 0 )) && (( purge_after <= now_epoch )); then
          rm -f "$file" >/dev/null 2>&1 || true
          continue
        fi
        if [[ ! "$purge_after" =~ ^[0-9]+$ || "$purge_after" == "0" ]]; then
          file_mtime="$(stat -c %Y "$file" 2>/dev/null || echo 0)"
          if [[ "$file_mtime" =~ ^[0-9]+$ ]] && (( file_mtime > 0 )) && (( now_epoch - file_mtime >= JOB_SUCCESS_TTL_SECONDS )); then
            rm -f "$file" >/dev/null 2>&1 || true
            continue
          fi
        fi
        complete_files+=("$file")
        ;;
    esac
  done < <(list_job_files)

  if (( ${#complete_files[@]} <= keep_completed )); then
    return 0
  fi

  count=$(( ${#complete_files[@]} - keep_completed ))
  for file in "${complete_files[@]:0:count}"; do
    rm -f "$file" >/dev/null 2>&1 || true
  done
}

retry_delay_for_attempt() {
  local attempt="$1"
  if (( attempt <= 1 )); then
    echo "${DEFAULT_RETRY_DELAYS[0]}"
  elif (( attempt == 2 )); then
    echo "${DEFAULT_RETRY_DELAYS[1]}"
  else
    echo "${DEFAULT_RETRY_DELAYS[2]}"
  fi
}

mark_job_failed_or_retry() {
  local assoc_name="$1"
  local message="$2"
  local now_epoch="$3"
  # shellcheck disable=SC2178
  local -n job_ref="$assoc_name"
  local attempts delay

  attempts="${job_ref[ATTEMPT_COUNT]:-0}"
  [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=0
  attempts=$((attempts + 1))
  # shellcheck disable=SC2153
  job_ref[ATTEMPT_COUNT]="$attempts"
  # shellcheck disable=SC2153
  job_ref[LAST_ERROR]="$message"
  # shellcheck disable=SC2153
  job_ref[LAST_MESSAGE]="$message"
  # shellcheck disable=SC2153
  job_ref[WORKER_PID]=""

  if (( attempts < 3 )); then
    delay="$(retry_delay_for_attempt "$attempts")"
    # shellcheck disable=SC2153
    job_ref[STATE]="retry_wait"
    # shellcheck disable=SC2153
    job_ref[PHASE]="retry_wait"
    # shellcheck disable=SC2153
    job_ref[RETRY_AT]="$((now_epoch + delay))"
    # shellcheck disable=SC2153
    job_ref[PROGRESS_PERCENT]="10"
  else
    # shellcheck disable=SC2153
    job_ref[STATE]="failed"
    # shellcheck disable=SC2153
    job_ref[PHASE]="failed"
    # shellcheck disable=SC2153
    job_ref[RETRY_AT]="0"
    # shellcheck disable=SC2153
    job_ref[PROGRESS_PERCENT]="100"
    preserve_failed_send_log_for_job "$assoc_name" || true
  fi
}

claim_next_send_job() {
  local now_epoch="$1"
  local result_path_var="$2"
  local best_path=""
  local best_sort=-1
  local file state retry_at sort_key job_id
  local -A job=()

  printf -v "$result_path_var" ''

  while IFS= read -r file; do
    job_load "$file" job || continue
    [[ "$(job_get job JOB_TYPE)" == "send" ]] || continue
    state="$(job_get job STATE)"
    retry_at="$(job_get job RETRY_AT 0)"
    job_is_retry_ready "$state" "$retry_at" "$now_epoch" || continue
    sort_key="$(job_get job QUEUE_SORT 0)"
    [[ "$sort_key" =~ ^[0-9]+$ ]] || sort_key=0
    if (( best_sort == -1 || sort_key < best_sort )); then
      best_sort="$sort_key"
      best_path="$file"
    fi
  done < <(list_job_files)

  [[ -n "$best_path" ]] || return 1
  printf -v "$result_path_var" '%s' "$best_path"
  return 0
}

claim_next_delete_job() {
  local result_path_var="$1"
  local best_path=""
  local best_sort=-1
  local file state retry_at sort_key
  local -A job=()
  local now_epoch
  now_epoch="$(date +%s)"

  printf -v "$result_path_var" ''

  while IFS= read -r file; do
    job_load "$file" job || continue
    [[ "$(job_get job JOB_TYPE)" == "snapshot_delete" ]] || continue
    state="$(job_get job STATE)"
    retry_at="$(job_get job RETRY_AT 0)"
    job_is_retry_ready "$state" "$retry_at" "$now_epoch" || continue
    sort_key="$(job_get job QUEUE_SORT 0)"
    [[ "$sort_key" =~ ^[0-9]+$ ]] || sort_key=0
    if (( best_sort == -1 || sort_key < best_sort )); then
      best_sort="$sort_key"
      best_path="$file"
    fi
  done < <(list_job_files)

  [[ -n "$best_path" ]] || return 1
  printf -v "$result_path_var" '%s' "$best_path"
  return 0
}

reconcile_stale_jobs() {
  local file state worker_pid phase
  local -A job=()
  local now_epoch
  now_epoch="$(date +%s)"

  while IFS= read -r file; do
    job_load "$file" job || continue
    state="$(job_get job STATE)"
    [[ "$state" == "running" ]] || continue
    worker_pid="$(job_get job WORKER_PID)"
    process_alive "$worker_pid" && continue

    phase="$(job_get job PHASE)"
    case "$phase" in
      snapshot_created|sending|verifying|cleanup)
        job[STATE]="queued"
        job[PHASE]="snapshot_created"
        job[RETRY_AT]="0"
        job[WORKER_PID]=""
        job[LAST_MESSAGE]="Recovered after an interrupted send worker. Re-queueing from the last safe checkpoint."
        ;;
      deleting)
        job[STATE]="queued"
        job[PHASE]="queued"
        job[RETRY_AT]="0"
        job[WORKER_PID]=""
        job[LAST_MESSAGE]="Recovered after an interrupted delete worker. Re-queueing delete operation."
        ;;
      *)
        mark_job_failed_or_retry job "Worker exited unexpectedly while processing this job." "$now_epoch"
        ;;
    esac
    job_write "$file" job || true
  done < <(list_job_files)
}

find_job_by_id() {
  local job_id="$1"
  local result_var="$2"
  local file
  # shellcheck disable=SC2034
  local -A job=()

  printf -v "$result_var" ''
  while IFS= read -r file; do
    job_load "$file" job || continue
    if [[ "$(job_get job JOB_ID)" == "$job_id" ]]; then
      printf -v "$result_var" '%s' "$file"
      return 0
    fi
  done < <(list_job_files)
  return 1
}

snapshot_delete_job_exists_for_snapshot() {
  local snapshot="$1"
  ensure_active_delete_queue_index
  [[ -n "${DELETE_QUEUE_BY_SNAPSHOT[$snapshot]:-}" ]]
}

snapshot_delete_checkpoint_job_exists() {
  local schedule_job_id="$1"
  local basename="$2"
  local key

  ensure_active_delete_queue_index
  key="${schedule_job_id}|${basename}"
  [[ -n "${DELETE_QUEUE_BY_CHECKPOINT[$key]:-}" ]]
}

ensure_active_delete_queue_index() {
  (( DELETE_QUEUE_INDEX_LOADED == 1 )) && return 0
  rebuild_active_delete_queue_index
}

rebuild_active_delete_queue_index() {
  local line state pool dataset path
  local -A job=()

  DELETE_QUEUE_BY_SNAPSHOT=()
  DELETE_QUEUE_BY_CHECKPOINT=()
  DELETE_QUEUE_COUNTS_BY_POOL=()
  DELETE_QUEUE_COUNTS_BY_DATASET=()

  for path in "$PERSISTED_DELETE_QUEUE_FILE" "$DELETE_QUEUE_STATE_FILE"; do
    [[ -f "$path" ]] || continue
    while IFS= read -r line; do
      delete_queue_parse_state_line "$line" job || continue
      state="$(job_get job STATE)"
      job_state_is_active "$state" || continue
      dataset="$(job_get job DATASET)"
      pool="$(job_get job DELETE_POOL)"
      [[ -n "$pool" ]] || pool="${dataset%%/*}"
      DELETE_QUEUE_BY_SNAPSHOT["$(job_get job SNAPSHOT)"]=1
      if [[ "$(job_get job DELETE_SCOPE)" == "checkpoint" ]]; then
        DELETE_QUEUE_BY_CHECKPOINT["$(job_get job SEND_SCHEDULE_JOB_ID)|$(job_get job SNAPSHOT_NAME)"]=1
      fi
      [[ -n "$pool" ]] && DELETE_QUEUE_COUNTS_BY_POOL["$pool"]=$(( ${DELETE_QUEUE_COUNTS_BY_POOL[$pool]:-0} + 1 ))
      [[ -n "$dataset" ]] && DELETE_QUEUE_COUNTS_BY_DATASET["$dataset"]=$(( ${DELETE_QUEUE_COUNTS_BY_DATASET[$dataset]:-0} + 1 ))
    done < "$path"
  done

  if [[ -f "$DELETE_QUEUE_INBOX_FILE" ]]; then
    while IFS= read -r line; do
      delete_queue_parse_enqueue_line "$line" job || continue
      dataset="$(job_get job DATASET)"
      pool="$(job_get job DELETE_POOL)"
      [[ -n "$pool" ]] || pool="${dataset%%/*}"
      DELETE_QUEUE_BY_SNAPSHOT["$(job_get job SNAPSHOT)"]=1
      if [[ "$(job_get job DELETE_SCOPE)" == "checkpoint" ]]; then
        DELETE_QUEUE_BY_CHECKPOINT["$(job_get job SEND_SCHEDULE_JOB_ID)|$(job_get job SNAPSHOT_NAME)"]=1
      fi
      [[ -n "$pool" ]] && DELETE_QUEUE_COUNTS_BY_POOL["$pool"]=$(( ${DELETE_QUEUE_COUNTS_BY_POOL[$pool]:-0} + 1 ))
      [[ -n "$dataset" ]] && DELETE_QUEUE_COUNTS_BY_DATASET["$dataset"]=$(( ${DELETE_QUEUE_COUNTS_BY_DATASET[$dataset]:-0} + 1 ))
    done < "$DELETE_QUEUE_INBOX_FILE"
  fi

  DELETE_QUEUE_INDEX_LOADED=1
}

estimate_destination_checkpoint_reclaim_bytes() {
  local schedule_job_id="$1"
  local basename="$2"
  local cache_key="${schedule_job_id}|${basename}"
  local loaded_key="${schedule_job_id}|__loaded__"
  local dataset snap_name snap_epoch snap_base

  if [[ -z "${SEND_CHECKPOINT_RECLAIM_CACHE[$loaded_key]:-}" ]]; then
    while IFS= read -r dataset; do
      [[ -n "$dataset" ]] || continue
      load_send_dataset_snapshot_cache "$dataset"
      while IFS=$'\t' read -r snap_name snap_epoch; do
        [[ -n "$snap_name" ]] || continue
        snap_base="${snap_name##*@}"
        send_basename_matches_schedule "$snap_base" "$schedule_job_id" || continue
        SEND_CHECKPOINT_RECLAIM_CACHE["${schedule_job_id}|${snap_base}"]=$(( ${SEND_CHECKPOINT_RECLAIM_CACHE["${schedule_job_id}|${snap_base}"]:-0} + $(send_snapshot_written_bytes_cached "$snap_name") ))
      done <<< "${SEND_DATASET_SNAPSHOT_LINES_ASC[$dataset]}"
    done < <(list_existing_destination_datasets_for_schedule "$schedule_job_id")
    SEND_CHECKPOINT_RECLAIM_CACHE["$loaded_key"]=1
  fi

  printf '%s' "${SEND_CHECKPOINT_RECLAIM_CACHE[$cache_key]:-0}"
}

queue_snapshot_delete_job() {
  local dataset="$1"
  local snapshot="$2"
  local queue_sort_epoch="$3"
  local message="$4"
  local send_schedule_job_id="${5:-}"
  local delete_scope="${6:-snapshot}"
  local snapshot_name snapshot_epoch job_id requested_epoch
  local guid="" createtxg=""
  local estimated_reclaim=0 pool=""
  local -A props=()
  local -A job=()

  QUEUE_DELETE_LAST_ADDED=0
  QUEUE_DELETE_LAST_ESTIMATED_RECLAIM=0

  snapshot_name="${snapshot##*@}"
  pool="${dataset%%/*}"
  requested_epoch="$(date +%s)"

  if [[ "$delete_scope" == "checkpoint" && -n "$send_schedule_job_id" ]]; then
    snapshot_delete_checkpoint_job_exists "$send_schedule_job_id" "$snapshot_name" && return 0
  else
    snapshot_delete_job_exists_for_snapshot "$snapshot" && return 0
  fi

  zfs_get_snapshot_props_cached "$snapshot" props || return 1
  snapshot_epoch="${props[creation]:-0}"
  guid="${props[guid]:-}"
  createtxg="${props[createtxg]:-}"
  [[ "$snapshot_epoch" =~ ^[0-9]+$ ]] || snapshot_epoch=0
  [[ "$queue_sort_epoch" =~ ^[0-9]+$ ]] || queue_sort_epoch="$snapshot_epoch"

  if [[ "$delete_scope" == "checkpoint" && -n "$send_schedule_job_id" ]]; then
    estimated_reclaim="$(estimate_destination_checkpoint_reclaim_bytes "$send_schedule_job_id" "$snapshot_name")"
  else
    estimated_reclaim="$(send_snapshot_written_bytes_cached "$snapshot")"
  fi
  [[ "$estimated_reclaim" =~ ^[0-9]+$ ]] || estimated_reclaim=0

  if command -v sha1sum >/dev/null 2>&1; then
    job_id="delete-$(printf '%s' "$snapshot" | sha1sum | awk '{print substr($1,1,16)}')-${requested_epoch}"
  else
    job_id="delete-$(printf '%s' "$snapshot" | shasum | awk '{print substr($1,1,16)}')-${requested_epoch}"
  fi

  job[JOB_ID]="$job_id"
  job[STATE]="queued"
  job[REQUESTED_EPOCH]="$requested_epoch"
  job[QUEUE_SORT]=$(( queue_sort_epoch * 1000 + (RANDOM % 1000) ))
  job[DATASET]="$dataset"
  job[SNAPSHOT]="$snapshot"
  job[SNAPSHOT_NAME]="$snapshot_name"
  job[SNAPSHOT_EPOCH]="$snapshot_epoch"
  job[SNAPSHOT_GUID]="$guid"
  job[SNAPSHOT_CREATETXG]="$createtxg"
  job[DELETE_POOL]="$pool"
  job[ESTIMATED_RECLAIM_BYTES]="$estimated_reclaim"
  job[SEND_PROTECTED]="0"
  job[DELETE_SCOPE]="$delete_scope"
  job[RETRY_AT]="0"

  if [[ "$delete_scope" == "checkpoint" && -n "$send_schedule_job_id" ]]; then
    job[SEND_PROTECTED]="1"
    job[SEND_SCHEDULE_JOB_ID]="$send_schedule_job_id"
  fi

  submit_delete_queue_job job || return 1
  QUEUE_DELETE_LAST_ADDED=1
  QUEUE_DELETE_LAST_ESTIMATED_RECLAIM="$estimated_reclaim"
  DELETE_QUEUE_BY_SNAPSHOT["$snapshot"]=1
  if [[ "$delete_scope" == "checkpoint" && -n "$send_schedule_job_id" ]]; then
    DELETE_QUEUE_BY_CHECKPOINT["${send_schedule_job_id}|${snapshot_name}"]=1
  fi
  DELETE_QUEUE_COUNTS_BY_POOL["$pool"]=$(( ${DELETE_QUEUE_COUNTS_BY_POOL[$pool]:-0} + 1 ))
  DELETE_QUEUE_COUNTS_BY_DATASET["$dataset"]=$(( ${DELETE_QUEUE_COUNTS_BY_DATASET[$dataset]:-0} + 1 ))
  DELETE_QUEUE_INDEX_LOADED=1
}

snapshot_delete_conflicts_with_send_jobs() {
  local snapshot="$1"
  local basename="${snapshot##*@}"
  local schedule_job_id
  schedule_job_id="$(parse_send_checkpoint_schedule_id "$basename" 2>/dev/null || true)"
  [[ -n "$schedule_job_id" ]] || return 1

  local -A protected=()
  scheduled_job_protected_basenames "$schedule_job_id" protected
  [[ -n "${protected[$basename]:-}" ]]
}

latest_checkpoint_basename_for_schedule() {
  local schedule_job_id="$1"
  local result_var="$2"
  local prefix source_root dest_root snap_name snap_epoch snap_base newest_base="" newest_epoch=0

  printf -v "$result_var" ''
  prefix="$(job_prefix_for_schedule "$schedule_job_id")"
  source_root="${SCHEDULE_SOURCE_ROOT[$schedule_job_id]:-}"
  dest_root="${SCHEDULE_DEST_ROOT[$schedule_job_id]:-}"

  if [[ -n "$source_root" ]] && dataset_exists "$source_root"; then
    while IFS=$'\t' read -r snap_name snap_epoch; do
      [[ -n "$snap_name" && -n "$snap_epoch" ]] || continue
      snap_base="${snap_name##*@}"
      if (( snap_epoch >= newest_epoch )); then
        newest_epoch="$snap_epoch"
        newest_base="$snap_base"
      fi
    done < <(job_list_basenames_for_root "$source_root" "$prefix")
  fi

  if [[ -n "$dest_root" ]] && dataset_exists "$dest_root"; then
    while IFS=$'\t' read -r snap_name snap_epoch; do
      [[ -n "$snap_name" && -n "$snap_epoch" ]] || continue
      snap_base="${snap_name##*@}"
      if (( snap_epoch >= newest_epoch )); then
        newest_epoch="$snap_epoch"
        newest_base="$snap_base"
      fi
    done < <(job_list_basenames_for_root "$dest_root" "$prefix")
  fi

  printf -v "$result_var" '%s' "$newest_base"
}

list_existing_destination_datasets_for_schedule() {
  local schedule_job_id="$1"
  local dest_root include_children dataset datasets=""

  if [[ -n "${SEND_DESTINATION_DATASETS_BY_SCHEDULE[$schedule_job_id]+set}" ]]; then
    printf '%s' "${SEND_DESTINATION_DATASETS_BY_SCHEDULE[$schedule_job_id]}"
    return 0
  fi

  dest_root="${SCHEDULE_DEST_ROOT[$schedule_job_id]:-}"
  include_children="${SCHEDULE_INCLUDE_CHILDREN[$schedule_job_id]:-0}"
  if [[ -z "$dest_root" ]] || ! dataset_exists "$dest_root"; then
    SEND_DESTINATION_DATASETS_BY_SCHEDULE["$schedule_job_id"]=""
    return 0
  fi

  if [[ "$include_children" == "1" ]]; then
    while IFS= read -r dataset; do
      [[ -n "$dataset" ]] || continue
      datasets+="${dataset}"$'\n'
    done < <(zfs list -H -o name -t filesystem,volume -r "$dest_root" 2>/dev/null || true)
  else
    datasets="${dest_root}"$'\n'
  fi

  SEND_DESTINATION_DATASETS_BY_SCHEDULE["$schedule_job_id"]="$datasets"
  printf '%s' "$datasets"
}

list_schedule_job_ids_for_destination_pool() {
  local pool="$1"
  local schedule_job_id dest_root

  for schedule_job_id in "${SCHEDULE_JOB_IDS[@]}"; do
    dest_root="${SCHEDULE_DEST_ROOT[$schedule_job_id]:-}"
    [[ -n "$dest_root" ]] || continue
    [[ "${dest_root%%/*}" == "$pool" ]] || continue
    printf '%s\n' "$schedule_job_id"
  done
}

list_existing_destination_datasets_for_pool() {
  local pool="$1"
  local schedule_job_id dataset
  local -A seen=()
  local datasets=""

  if [[ -n "${SEND_DESTINATION_DATASETS_BY_POOL[$pool]+set}" ]]; then
    printf '%s' "${SEND_DESTINATION_DATASETS_BY_POOL[$pool]}"
    return 0
  fi

  while IFS= read -r schedule_job_id; do
    [[ -n "$schedule_job_id" ]] || continue
    while IFS= read -r dataset; do
      [[ -n "$dataset" ]] || continue
      [[ -z "${seen[$dataset]:-}" ]] || continue
      seen["$dataset"]=1
      datasets+="${dataset}"$'\n'
    done < <(list_existing_destination_datasets_for_schedule "$schedule_job_id")
  done < <(list_schedule_job_ids_for_destination_pool "$pool")

  SEND_DESTINATION_DATASETS_BY_POOL["$pool"]="$datasets"
  printf '%s' "$datasets"
}

add_planned_reclaim_for_capacity_dataset() {
  local reclaimed_dataset="$1"
  local reclaim_bytes="$2"
  local capacity_dataset="$3"
  local delta_map_name="$4"
  local token base

  [[ -n "$capacity_dataset" && -n "$delta_map_name" ]] || return 0
  [[ "$reclaim_bytes" =~ ^[0-9]+$ ]] || return 0
  (( reclaim_bytes > 0 )) || return 0

  local -n delta_ref="$delta_map_name"

  while IFS=$'\t' read -r token base; do
    [[ -n "$token" ]] || continue
    candidate_affects_constraint "$reclaimed_dataset" "$token" || continue
    delta_ref["$token"]=$(( ${delta_ref[$token]:-0} + reclaim_bytes ))
  done < <(emit_dataset_capacity_constraints "$capacity_dataset")
}

queue_destination_retention_for_dataset() {
  local dataset="$1"
  local schedule_job_id="$2"
  local newest_send_basename="$3"
  local mode="${4:-retention}"
  local capacity_dataset="${5:-}"
  local delta_map_name="${6:-}"
  local snap_name snap_epoch snap_base snap_age written_bytes userrefs snapshot_schedule_job_id
  local newest_snapshot=""
  local zero_change_anchor=""
  local keep_all_seconds keep_daily_seconds keep_weekly_seconds
  local week_key day_key
  local now_epoch
  local -A protected=()
  local -A kept_day=()
  local -A kept_week=()
  local -A queued_checkpoint_basenames=()

  dataset_exists "$dataset" || return 0
  load_send_dataset_snapshot_cache "$dataset"

  keep_all_seconds="$(send_retention_keep_all_seconds)"
  keep_daily_seconds="$(send_retention_keep_daily_until_seconds)"
  keep_weekly_seconds="$(send_retention_keep_weekly_until_seconds)"
  now_epoch="$(date +%s)"
  cached_all_scheduled_job_protected_basenames protected
  [[ -n "$newest_send_basename" ]] && protected["$newest_send_basename"]=1

  while IFS=$'\t' read -r snap_name snap_epoch; do
    [[ -n "$snap_name" && -n "$snap_epoch" ]] || continue
    snap_base="${snap_name##*@}"

    if [[ -z "$newest_snapshot" ]]; then
      newest_snapshot="$snap_name"
      if [[ "$mode" == "zero_change" ]]; then
        written_bytes="$(send_snapshot_written_bytes_cached "$snap_name")"
        if (( written_bytes == 0 )); then
          zero_change_anchor="$snap_name"
        fi
      fi
      continue
    fi

    userrefs="$(send_snapshot_userrefs_count_cached "$snap_name")"
    (( userrefs == 0 )) || continue
    send_snapshot_has_clones_cached "$snap_name" && continue
    [[ -z "${protected[$snap_base]:-}" ]] || continue

    if [[ "$mode" == "zero_change" ]]; then
      written_bytes="$(send_snapshot_written_bytes_cached "$snap_name")"
      if (( written_bytes == 0 )); then
        if [[ -n "$zero_change_anchor" ]]; then
          snapshot_schedule_job_id="$(parse_send_checkpoint_schedule_id "$snap_base" 2>/dev/null || true)"
          if [[ -n "$snapshot_schedule_job_id" ]]; then
            [[ -z "${queued_checkpoint_basenames[$snap_base]:-}" ]] || continue
            queue_snapshot_delete_job "$dataset" "$snap_name" "$snap_epoch" "Queued by post-send zero-change cleanup." "$snapshot_schedule_job_id" "checkpoint" || true
            if (( QUEUE_DELETE_LAST_ADDED == 1 )); then
              add_planned_reclaim_for_capacity_dataset "$dataset" "$QUEUE_DELETE_LAST_ESTIMATED_RECLAIM" "$capacity_dataset" "$delta_map_name"
            fi
            queued_checkpoint_basenames["$snap_base"]=1
          else
            queue_snapshot_delete_job "$dataset" "$snap_name" "$snap_epoch" "Queued by post-send zero-change cleanup." || true
            if (( QUEUE_DELETE_LAST_ADDED == 1 )); then
              add_planned_reclaim_for_capacity_dataset "$dataset" "$QUEUE_DELETE_LAST_ESTIMATED_RECLAIM" "$capacity_dataset" "$delta_map_name"
            fi
          fi
          continue
        fi
        zero_change_anchor="$snap_name"
      else
        zero_change_anchor=""
      fi
      continue
    fi

    snap_age=$(( now_epoch - snap_epoch ))
    if (( snap_age > keep_weekly_seconds )); then
      snapshot_schedule_job_id="$(parse_send_checkpoint_schedule_id "$snap_base" 2>/dev/null || true)"
      if [[ -n "$snapshot_schedule_job_id" ]]; then
        [[ -z "${queued_checkpoint_basenames[$snap_base]:-}" ]] || continue
        queue_snapshot_delete_job "$dataset" "$snap_name" "$snap_epoch" "Queued by scheduled-send retention cleanup." "$snapshot_schedule_job_id" "checkpoint" || true
        if (( QUEUE_DELETE_LAST_ADDED == 1 )); then
          add_planned_reclaim_for_capacity_dataset "$dataset" "$QUEUE_DELETE_LAST_ESTIMATED_RECLAIM" "$capacity_dataset" "$delta_map_name"
        fi
        queued_checkpoint_basenames["$snap_base"]=1
      else
        queue_snapshot_delete_job "$dataset" "$snap_name" "$snap_epoch" "Queued by scheduled-send retention cleanup." || true
        if (( QUEUE_DELETE_LAST_ADDED == 1 )); then
          add_planned_reclaim_for_capacity_dataset "$dataset" "$QUEUE_DELETE_LAST_ESTIMATED_RECLAIM" "$capacity_dataset" "$delta_map_name"
        fi
      fi
      continue
    fi

    if (( snap_age > keep_daily_seconds )); then
      week_key="$(send_week_key_for_epoch "$snap_epoch")"
      if [[ -z "${kept_week[$week_key]:-}" ]]; then
        kept_week["$week_key"]=1
      else
        snapshot_schedule_job_id="$(parse_send_checkpoint_schedule_id "$snap_base" 2>/dev/null || true)"
        if [[ -n "$snapshot_schedule_job_id" ]]; then
          [[ -z "${queued_checkpoint_basenames[$snap_base]:-}" ]] || continue
          queue_snapshot_delete_job "$dataset" "$snap_name" "$snap_epoch" "Queued by scheduled-send weekly retention cleanup." "$snapshot_schedule_job_id" "checkpoint" || true
          if (( QUEUE_DELETE_LAST_ADDED == 1 )); then
            add_planned_reclaim_for_capacity_dataset "$dataset" "$QUEUE_DELETE_LAST_ESTIMATED_RECLAIM" "$capacity_dataset" "$delta_map_name"
          fi
          queued_checkpoint_basenames["$snap_base"]=1
        else
          queue_snapshot_delete_job "$dataset" "$snap_name" "$snap_epoch" "Queued by scheduled-send weekly retention cleanup." || true
          if (( QUEUE_DELETE_LAST_ADDED == 1 )); then
            add_planned_reclaim_for_capacity_dataset "$dataset" "$QUEUE_DELETE_LAST_ESTIMATED_RECLAIM" "$capacity_dataset" "$delta_map_name"
          fi
        fi
      fi
      continue
    fi

    if (( snap_age > keep_all_seconds )); then
      day_key="$(send_day_key_for_epoch "$snap_epoch")"
      if [[ -z "${kept_day[$day_key]:-}" ]]; then
        kept_day["$day_key"]=1
      else
        snapshot_schedule_job_id="$(parse_send_checkpoint_schedule_id "$snap_base" 2>/dev/null || true)"
        if [[ -n "$snapshot_schedule_job_id" ]]; then
          [[ -z "${queued_checkpoint_basenames[$snap_base]:-}" ]] || continue
          queue_snapshot_delete_job "$dataset" "$snap_name" "$snap_epoch" "Queued by scheduled-send daily retention cleanup." "$snapshot_schedule_job_id" "checkpoint" || true
          if (( QUEUE_DELETE_LAST_ADDED == 1 )); then
            add_planned_reclaim_for_capacity_dataset "$dataset" "$QUEUE_DELETE_LAST_ESTIMATED_RECLAIM" "$capacity_dataset" "$delta_map_name"
          fi
          queued_checkpoint_basenames["$snap_base"]=1
        else
          queue_snapshot_delete_job "$dataset" "$snap_name" "$snap_epoch" "Queued by scheduled-send daily retention cleanup." || true
          if (( QUEUE_DELETE_LAST_ADDED == 1 )); then
            add_planned_reclaim_for_capacity_dataset "$dataset" "$QUEUE_DELETE_LAST_ESTIMATED_RECLAIM" "$capacity_dataset" "$delta_map_name"
          fi
        fi
      fi
    fi
  done <<< "${SEND_DATASET_SNAPSHOT_LINES_DESC[$dataset]}"
}

active_delete_state_count_for_pool() {
  local pool="$1"
  ensure_active_delete_queue_index
  printf '%s' "${DELETE_QUEUE_COUNTS_BY_POOL[$pool]:-0}"
}

active_delete_inbox_count_for_pool() {
  local pool="$1"
  local count=0 line
  local fields=()
  local dataset delete_pool

  [[ -f "$DELETE_QUEUE_INBOX_FILE" ]] || {
    printf '0'
    return 0
  }

  while IFS= read -r line; do
    IFS=$'\t' read -r -a fields <<< "$line"
    [[ "${fields[0]:-}" == "ENQUEUE" ]] || continue
    dataset="${fields[4]:-}"
    delete_pool="${fields[10]:-${dataset%%/*}}"
    [[ "$delete_pool" == "$pool" ]] || continue
    count=$((count + 1))
  done < "$DELETE_QUEUE_INBOX_FILE"

  printf '%s' "$count"
}

active_delete_queue_count_for_pool() {
  local pool="$1"
  local state_count inbox_count

  state_count="$(active_delete_state_count_for_pool "$pool")"
  inbox_count="$(active_delete_inbox_count_for_pool "$pool")"
  [[ "$state_count" =~ ^[0-9]+$ ]] || state_count=0
  [[ "$inbox_count" =~ ^[0-9]+$ ]] || inbox_count=0
  printf '%s' "$(( state_count + inbox_count ))"
}

pool_has_active_delete_jobs() {
  local count
  count="$(active_delete_queue_count_for_pool "$1")"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  (( count > 0 ))
}

queue_pool_retention_cleanup() {
  local pool="$1"
  local capacity_dataset="$2"
  local delta_map_name="$3"
  local dataset

  while IFS= read -r dataset; do
    [[ -n "$dataset" ]] || continue
    queue_destination_retention_for_dataset "$dataset" "" "" "retention" "$capacity_dataset" "$delta_map_name"
  done < <(list_existing_destination_datasets_for_pool "$pool")
}

queue_pool_free_space_cleanup_for_schedule() {
  local schedule_job_id="$1"
  local capacity_dataset="$2"
  local delta_map_name="$3"
  local threshold="${SCHEDULE_THRESHOLD_BYTES[$schedule_job_id]}"
  local pool effective candidate_snapshot candidate_epoch candidate_dataset
  # shellcheck disable=SC2034
  local -a active_constraints=()

  pool="$(schedule_destination_pool "$schedule_job_id")"
  [[ -n "$pool" && -n "$capacity_dataset" ]] || return 1
  [[ "$threshold" =~ ^[0-9]+$ ]] || return 1

  while :; do
    get_dataset_active_constraints "$capacity_dataset" "$delta_map_name" effective active_constraints || return 1
    (( effective >= threshold )) && return 0

    candidate_snapshot=""
    candidate_epoch=0
    if ! find_oldest_deletable_destination_snapshot_for_pool "$pool" active_constraints candidate_snapshot candidate_epoch; then
      return 1
    fi

    candidate_dataset="${candidate_snapshot%@*}"
    queue_snapshot_delete_job "$candidate_dataset" "$candidate_snapshot" "$candidate_epoch" "Queued by scheduled-send low-space cleanup." || true
    if (( QUEUE_DELETE_LAST_ADDED == 1 )); then
      add_planned_reclaim_for_capacity_dataset "$candidate_dataset" "$QUEUE_DELETE_LAST_ESTIMATED_RECLAIM" "$capacity_dataset" "$delta_map_name"
      continue
    fi

    return 1
  done
}

queue_schedule_retention_cleanup() {
  local schedule_job_id="$1"
  local dataset newest_send_basename=""

  latest_checkpoint_basename_for_schedule "$schedule_job_id" newest_send_basename
  while IFS= read -r dataset; do
    [[ -n "$dataset" ]] || continue
    queue_destination_retention_for_dataset "$dataset" "$schedule_job_id" "$newest_send_basename" "retention"
  done < <(list_existing_destination_datasets_for_schedule "$schedule_job_id")
}

queue_schedule_zero_change_cleanup() {
  local schedule_job_id="$1"
  local dataset newest_send_basename=""

  latest_checkpoint_basename_for_schedule "$schedule_job_id" newest_send_basename
  while IFS= read -r dataset; do
    [[ -n "$dataset" ]] || continue
    queue_destination_retention_for_dataset "$dataset" "$schedule_job_id" "$newest_send_basename" "zero_change"
  done < <(list_existing_destination_datasets_for_schedule "$schedule_job_id")
}

queue_schedule_zero_change_cleanup_for_dataset() {
  local schedule_job_id="$1"
  local dataset="$2"
  local newest_send_basename="$3"

  [[ -n "$schedule_job_id" && -n "$dataset" && -n "$newest_send_basename" ]] || return 1
  queue_destination_retention_for_dataset "$dataset" "$schedule_job_id" "$newest_send_basename" "zero_change"
}
