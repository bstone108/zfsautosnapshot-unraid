#!/bin/bash

PLUGIN_NAME="zfs.autosnapshot"
CONFIG_DIR="/boot/config/plugins/${PLUGIN_NAME}"
SEND_CONFIG_FILE="${CONFIG_DIR}/zfs_send.conf"
OPS_ROOT="${CONFIG_DIR}/ops_queue"
OPS_JOBS_DIR="${OPS_ROOT}/jobs"
OPS_STATUS_DIR="${OPS_ROOT}/status"
RUNTIME_DIR="/var/run/zfs-autosnapshot-ops"
SEND_WORKER_RUNTIME_DIR="${RUNTIME_DIR}/send-workers"
DELETE_WORKER_RUNTIME_DIR="${RUNTIME_DIR}/delete-worker"
JOB_LOCKS_DIR="${RUNTIME_DIR}/job-locks"
ACTIVE_SEND_DATASETS_DIR="${RUNTIME_DIR}/active-send-datasets"
AUTOSNAPSHOT_RUNTIME_DIR="/var/run/zfs-autosnapshot"
AUTOSNAPSHOT_ACTIVE_FILE="${AUTOSNAPSHOT_RUNTIME_DIR}/zfs_autosnapshot.active"
LOG_FILE="/var/log/zfs_autosnapshot_send.log"

DEFAULT_SEND_SNAPSHOT_PREFIX="zfs-send-"
DEFAULT_SEND_MAX_PARALLEL="1"
DEFAULT_SEND_KEEP_ALL_FOR_DAYS="14"
DEFAULT_SEND_KEEP_DAILY_UNTIL_DAYS="30"
DEFAULT_SEND_KEEP_WEEKLY_UNTIL_DAYS="183"
DEFAULT_RETRY_DELAYS=(60 300 900)
POST_DELETE_RECHECK_WAIT_SECONDS="${POST_DELETE_RECHECK_WAIT_SECONDS:-3}"
POST_DELETE_RECHECK_INTERVAL_SECONDS="${POST_DELETE_RECHECK_INTERVAL_SECONDS:-1}"

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

log() {
  printf '%s %s\n' "$(date +'%Y-%m-%d %H:%M:%S %Z')" "$*"
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
  mkdir -p "$RUNTIME_DIR" "$SEND_WORKER_RUNTIME_DIR" "$DELETE_WORKER_RUNTIME_DIR" "$JOB_LOCKS_DIR" "$ACTIVE_SEND_DATASETS_DIR" "$(dirname "$LOG_FILE")" >/dev/null 2>&1 || true
  return 0
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

frequency_seconds() {
  case "$1" in
    15m) echo 900 ;;
    30m) echo 1800 ;;
    1h) echo 3600 ;;
    6h) echo 21600 ;;
    12h) echo 43200 ;;
    1d) echo 86400 ;;
    7d) echo 604800 ;;
    *) echo 0 ;;
  esac
}

frequency_window_key() {
  local frequency="$1"
  local now_epoch="$2"
  local seconds
  seconds="$(frequency_seconds "$frequency")"
  (( seconds > 0 )) || {
    echo "$now_epoch"
    return 0
  }
  echo $(( now_epoch - (now_epoch % seconds) ))
}

jobs_are_same_pool_overlap() {
  local source="$1"
  local dest="$2"

  [[ "${source%%/*}" == "${dest%%/*}" ]] || return 1
  [[ "$source" == "$dest" || "$source" == "$dest/"* || "$dest" == "$source/"* ]]
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
    freq="$(trim "$freq")"
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
    case "$freq" in
      15m|30m|1h|6h|12h|1d|7d) ;;
      *) continue ;;
    esac
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

  tmp="${path}.tmp.$$"
  : > "$tmp" || return 1

  while IFS= read -r key; do
    [[ "$key" == __* ]] && continue
    printf '%s="%s"\n' "$key" "$(kv_escape "${job_ref[$key]}")" >> "$tmp"
  done < <(printf '%s\n' "${!job_ref[@]}" | sort)

  mv "$tmp" "$path" || return 1
  chmod 0664 "$path" >/dev/null 2>&1 || true
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
  [[ -d "$DELETE_WORKER_RUNTIME_DIR/active.lockdir" ]]
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
  local pool_effective quota_avail refquota_avail

  pool_effective="$(get_pool_effective_avail "$pool")"
  [[ "$pool_effective" =~ ^[0-9]+$ ]] && printf 'pool:%s\t%s\n' "$pool" "$pool_effective"

  while [[ -n "$dataset" ]]; do
    quota_avail="$(zfs get -H -p -o value available "$dataset" 2>/dev/null || true)"
    [[ "$quota_avail" =~ ^[0-9]+$ ]] && printf 'quota:%s\t%s\n' "$dataset" "$quota_avail"

    refquota_avail="$(zfs get -H -p -o value available "$dataset" 2>/dev/null || true)"
    [[ "$refquota_avail" =~ ^[0-9]+$ ]] && printf 'refquota:%s\t%s\n' "$dataset" "$refquota_avail"

    [[ "$dataset" == */* ]] || break
    dataset="${dataset%/*}"
  done
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
  local command="$2"
  log "$description"
  bash -o pipefail -c "$command"
}

snapshot_exists() {
  zfs list -H -o name -t snapshot "$1" >/dev/null 2>&1
}

dataset_exists() {
  zfs list -H -o name "$1" >/dev/null 2>&1
}

zfs_get_snapshot_props() {
  local snapshot="$1"
  local result_name="$2"
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

  all_scheduled_job_protected_basenames protected

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
  done < <(zfs list -H -p -r -t snapshot -o name,creation "$dest_root" 2>/dev/null || true)

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

last_completed_schedule_job_epoch() {
  local schedule_job_id="$1"
  local latest=0
  local file
  local -A job=()
  local requested state

  while IFS= read -r file; do
    job_load "$file" job || continue
    [[ "$(job_get job JOB_TYPE)" == "send" ]] || continue
    [[ "$(job_get job JOB_MODE)" == "scheduled" ]] || continue
    [[ "$(job_get job SCHEDULE_JOB_ID)" == "$schedule_job_id" ]] || continue
    state="$(job_get job STATE)"
    [[ "$state" == "complete" ]] || continue
    requested="$(job_get job REQUESTED_EPOCH 0)"
    [[ "$requested" =~ ^[0-9]+$ ]] || requested=0
    (( requested > latest )) && latest="$requested"
  done < <(list_job_files)

  printf '%s' "$latest"
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
    [[ "$(job_get job WINDOW_KEY)" == "$window_key" ]] || return 0
  done < <(list_job_files)

  return 1
}

enqueue_scheduled_send_jobs_due() {
  local now_epoch="$1"
  local job_id frequency interval last_success window_key requested_at requested_epoch job_file
  local -A job=()
  local queued_count=0

  for job_id in "${SCHEDULE_JOB_IDS[@]}"; do
    frequency="${SCHEDULE_FREQUENCY[$job_id]}"
    interval="$(frequency_seconds "$frequency")"
    (( interval > 0 )) || continue
    last_success="$(last_completed_schedule_job_epoch "$job_id")"
    if (( last_success > 0 && now_epoch - last_success < interval )); then
      continue
    fi

    schedule_job_blocked "$job_id" && continue

    window_key="$(frequency_window_key "$frequency" "$now_epoch")"
    schedule_window_exists "$job_id" "$window_key" && continue

    requested_epoch="$now_epoch"
    requested_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ' -r "$requested_epoch" 2>/dev/null || date -u +'%Y-%m-%dT%H:%M:%SZ')"

    job=()
    job[JOB_ID]="send-${job_id}-${window_key}"
    job[JOB_TYPE]="send"
    job[JOB_MODE]="scheduled"
    job[STATE]="queued"
    job[PHASE]="queued"
    job[REQUESTED_EPOCH]="$requested_epoch"
    job[REQUESTED_AT]="$requested_at"
    job[QUEUE_SORT]="$requested_epoch"
    job[WINDOW_KEY]="$window_key"
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

    job_file="${OPS_JOBS_DIR}/$(printf '%010d-%s.job' "$requested_epoch" "send-${job_id}-${window_key}")"
    job_write "$job_file" job || continue
    queued_count=$((queued_count + 1))
  done

  return "$queued_count"
}

prune_old_jobs() {
  local keep_completed=100
  local file
  local -A job=()
  local complete_files=()
  local count=0

  while IFS= read -r file; do
    job_load "$file" job || continue
    case "$(job_get job STATE)" in
      complete|skipped)
        complete_files+=("$file")
        ;;
    esac
  done < <(list_job_files)

  if (( ${#complete_files[@]} <= keep_completed )); then
    return 0
  fi

  for file in "${complete_files[@]:keep_completed}"; do
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
  local file state
  local -A job=()

  while IFS= read -r file; do
    job_load "$file" job || continue
    [[ "$(job_get job JOB_TYPE)" == "snapshot_delete" ]] || continue
    [[ "$(job_get job SNAPSHOT)" == "$snapshot" ]] || continue
    state="$(job_get job STATE)"
    [[ "$state" == "complete" || "$state" == "skipped" ]] && continue
    return 0
  done < <(list_job_files)

  return 1
}

snapshot_delete_checkpoint_job_exists() {
  local schedule_job_id="$1"
  local basename="$2"
  local file state
  local -A job=()

  while IFS= read -r file; do
    job_load "$file" job || continue
    [[ "$(job_get job JOB_TYPE)" == "snapshot_delete" ]] || continue
    [[ "$(job_get job DELETE_SCOPE)" == "checkpoint" ]] || continue
    [[ "$(job_get job SEND_SCHEDULE_JOB_ID)" == "$schedule_job_id" ]] || continue
    [[ "$(job_get job SNAPSHOT_NAME)" == "$basename" ]] || continue
    state="$(job_get job STATE)"
    [[ "$state" == "complete" || "$state" == "skipped" ]] && continue
    return 0
  done < <(list_job_files)

  return 1
}

queue_snapshot_delete_job() {
  local dataset="$1"
  local snapshot="$2"
  local queue_sort_epoch="$3"
  local message="$4"
  local send_schedule_job_id="${5:-}"
  local delete_scope="${6:-snapshot}"
  local snapshot_name snapshot_epoch job_id requested_epoch path
  local guid="" createtxg=""
  local -A props=()
  local -A job=()

  if ! snapshot_exists "$snapshot"; then
    return 1
  fi

  snapshot_name="${snapshot##*@}"
  requested_epoch="$(date +%s)"

  if [[ "$delete_scope" == "checkpoint" && -n "$send_schedule_job_id" ]]; then
    snapshot_delete_checkpoint_job_exists "$send_schedule_job_id" "$snapshot_name" && return 0
  else
    snapshot_delete_job_exists_for_snapshot "$snapshot" && return 0
  fi

  zfs_get_snapshot_props "$snapshot" props || return 1
  snapshot_epoch="${props[creation]:-0}"
  guid="${props[guid]:-}"
  createtxg="${props[createtxg]:-}"
  [[ "$snapshot_epoch" =~ ^[0-9]+$ ]] || snapshot_epoch=0
  [[ "$queue_sort_epoch" =~ ^[0-9]+$ ]] || queue_sort_epoch="$snapshot_epoch"

  if command -v sha1sum >/dev/null 2>&1; then
    job_id="delete-$(printf '%s' "$snapshot" | sha1sum | awk '{print substr($1,1,16)}')-${requested_epoch}"
  else
    job_id="delete-$(printf '%s' "$snapshot" | shasum | awk '{print substr($1,1,16)}')-${requested_epoch}"
  fi
  path="${OPS_JOBS_DIR}/$(printf '%010d-%s.job' "$requested_epoch" "$job_id")"

  job[JOB_ID]="$job_id"
  job[JOB_TYPE]="snapshot_delete"
  job[STATE]="queued"
  job[PHASE]="queued"
  job[REQUESTED_EPOCH]="$requested_epoch"
  job[REQUESTED_AT]="$(date -u +'%Y-%m-%dT%H:%M:%SZ' -r "$requested_epoch" 2>/dev/null || date -u +'%Y-%m-%dT%H:%M:%SZ')"
  job[QUEUE_SORT]=$(( queue_sort_epoch * 1000 + (RANDOM % 1000) ))
  job[DATASET]="$dataset"
  job[SNAPSHOT]="$snapshot"
  job[SNAPSHOT_NAME]="$snapshot_name"
  job[SNAPSHOT_EPOCH]="$snapshot_epoch"
  job[SNAPSHOT_GUID]="$guid"
  job[SNAPSHOT_CREATETXG]="$createtxg"
  job[SEND_PROTECTED]="0"
  job[DELETE_SCOPE]="$delete_scope"
  job[LAST_ERROR]=""
  job[LAST_MESSAGE]="$message"
  job[WORKER_PID]=""
  job[RETRY_AT]="0"

  if [[ "$delete_scope" == "checkpoint" && -n "$send_schedule_job_id" ]]; then
    job[SEND_PROTECTED]="1"
    # shellcheck disable=SC2034
    job[SEND_SCHEDULE_JOB_ID]="$send_schedule_job_id"
  fi

  job_write "$path" job
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
  local dest_root include_children

  dest_root="${SCHEDULE_DEST_ROOT[$schedule_job_id]:-}"
  include_children="${SCHEDULE_INCLUDE_CHILDREN[$schedule_job_id]:-0}"
  [[ -n "$dest_root" ]] || return 0
  dataset_exists "$dest_root" || return 0

  if [[ "$include_children" == "1" ]]; then
    zfs list -H -o name -t filesystem,volume -r "$dest_root" 2>/dev/null || true
  else
    printf '%s\n' "$dest_root"
  fi
}

queue_destination_retention_for_dataset() {
  local dataset="$1"
  local schedule_job_id="$2"
  local newest_send_basename="$3"
  local mode="${4:-retention}"
  local snap_name snap_epoch snap_base snap_age written_bytes userrefs snapshot_schedule_job_id
  local newest_snapshot=""
  local zero_change_anchor=""
  local keep_all_seconds keep_daily_seconds keep_weekly_seconds
  local week_key day_key
  local kept_day=$'\n'
  local kept_week=$'\n'
  local -A protected=()
  local -A queued_checkpoint_basenames=()

  dataset_exists "$dataset" || return 0

  keep_all_seconds="$(send_retention_keep_all_seconds)"
  keep_daily_seconds="$(send_retention_keep_daily_until_seconds)"
  keep_weekly_seconds="$(send_retention_keep_weekly_until_seconds)"
  all_scheduled_job_protected_basenames protected
  [[ -n "$newest_send_basename" ]] && protected["$newest_send_basename"]=1

  while IFS=$'\t' read -r snap_name snap_epoch; do
    [[ -n "$snap_name" && -n "$snap_epoch" ]] || continue
    snap_base="${snap_name##*@}"

    if [[ -z "$newest_snapshot" ]]; then
      newest_snapshot="$snap_name"
      if [[ "$mode" == "zero_change" ]]; then
        written_bytes="$(snapshot_written_bytes "$snap_name")"
        if (( written_bytes == 0 )); then
          zero_change_anchor="$snap_name"
        fi
      fi
      continue
    fi

    userrefs="$(snapshot_userrefs_count "$snap_name")"
    (( userrefs == 0 )) || continue
    snapshot_has_clones "$snap_name" && continue
    [[ -z "${protected[$snap_base]:-}" ]] || continue

    if [[ "$mode" == "zero_change" ]]; then
      written_bytes="$(snapshot_written_bytes "$snap_name")"
      if (( written_bytes == 0 )); then
        if [[ -n "$zero_change_anchor" ]]; then
          snapshot_schedule_job_id="$(parse_send_checkpoint_schedule_id "$snap_base" 2>/dev/null || true)"
          if [[ -n "$snapshot_schedule_job_id" ]]; then
            [[ -z "${queued_checkpoint_basenames[$snap_base]:-}" ]] || continue
            queue_snapshot_delete_job "$dataset" "$snap_name" "$snap_epoch" "Queued by post-send zero-change cleanup." "$snapshot_schedule_job_id" "checkpoint" || true
            queued_checkpoint_basenames["$snap_base"]=1
          else
            queue_snapshot_delete_job "$dataset" "$snap_name" "$snap_epoch" "Queued by post-send zero-change cleanup." || true
          fi
          continue
        fi
        zero_change_anchor="$snap_name"
      else
        zero_change_anchor=""
      fi
      continue
    fi

    snap_age=$(( $(date +%s) - snap_epoch ))
    if (( snap_age > keep_weekly_seconds )); then
      snapshot_schedule_job_id="$(parse_send_checkpoint_schedule_id "$snap_base" 2>/dev/null || true)"
      if [[ -n "$snapshot_schedule_job_id" ]]; then
        [[ -z "${queued_checkpoint_basenames[$snap_base]:-}" ]] || continue
        queue_snapshot_delete_job "$dataset" "$snap_name" "$snap_epoch" "Queued by scheduled-send retention cleanup." "$snapshot_schedule_job_id" "checkpoint" || true
        queued_checkpoint_basenames["$snap_base"]=1
      else
        queue_snapshot_delete_job "$dataset" "$snap_name" "$snap_epoch" "Queued by scheduled-send retention cleanup." || true
      fi
      continue
    fi

    if (( snap_age > keep_daily_seconds )); then
      week_key="$(date -d @"$snap_epoch" +%Y-%W)"
      if [[ "$kept_week" != *$'\n'"$week_key"$'\n'* ]]; then
        kept_week+="$week_key"$'\n'
      else
        snapshot_schedule_job_id="$(parse_send_checkpoint_schedule_id "$snap_base" 2>/dev/null || true)"
        if [[ -n "$snapshot_schedule_job_id" ]]; then
          [[ -z "${queued_checkpoint_basenames[$snap_base]:-}" ]] || continue
          queue_snapshot_delete_job "$dataset" "$snap_name" "$snap_epoch" "Queued by scheduled-send weekly retention cleanup." "$snapshot_schedule_job_id" "checkpoint" || true
          queued_checkpoint_basenames["$snap_base"]=1
        else
          queue_snapshot_delete_job "$dataset" "$snap_name" "$snap_epoch" "Queued by scheduled-send weekly retention cleanup." || true
        fi
      fi
      continue
    fi

    if (( snap_age > keep_all_seconds )); then
      day_key="$(date -d @"$snap_epoch" +%Y-%m-%d)"
      if [[ "$kept_day" != *$'\n'"$day_key"$'\n'* ]]; then
        kept_day+="$day_key"$'\n'
      else
        snapshot_schedule_job_id="$(parse_send_checkpoint_schedule_id "$snap_base" 2>/dev/null || true)"
        if [[ -n "$snapshot_schedule_job_id" ]]; then
          [[ -z "${queued_checkpoint_basenames[$snap_base]:-}" ]] || continue
          queue_snapshot_delete_job "$dataset" "$snap_name" "$snap_epoch" "Queued by scheduled-send daily retention cleanup." "$snapshot_schedule_job_id" "checkpoint" || true
          queued_checkpoint_basenames["$snap_base"]=1
        else
          queue_snapshot_delete_job "$dataset" "$snap_name" "$snap_epoch" "Queued by scheduled-send daily retention cleanup." || true
        fi
      fi
    fi
  done < <(zfs list -H -p -t snapshot -o name,creation -S creation -d 1 "$dataset" 2>/dev/null || true)
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
