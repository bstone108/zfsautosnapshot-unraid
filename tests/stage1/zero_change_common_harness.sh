#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OPS_LIB="${ROOT_DIR}/source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/ops-queue-lib.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

export CONFIG_DIR="${TEST_ROOT}/config"
export RUNTIME_ROOT="${TEST_ROOT}/runtime"
export OPS_RUNTIME_DIR="${RUNTIME_ROOT}/ops"
export OPS_JOBS_DIR="${OPS_RUNTIME_DIR}/jobs"
export DELETE_QUEUE_DIR="${OPS_RUNTIME_DIR}/delete-queue"
export DELETE_QUEUE_INBOX_FILE="${DELETE_QUEUE_DIR}/inbox.tsv"
mkdir -p "$CONFIG_DIR" "$OPS_JOBS_DIR" "$DELETE_QUEUE_DIR"

# Source library after env paths are set.
# shellcheck source=/dev/null
source "$OPS_LIB"

# Mock ZFS world: dataset -> snapshots with creation/written/userrefs/clones/guid/createtxg.
declare -A DATASET_EXISTS=()
declare -A SNAP_CREATION=()
declare -A SNAP_WRITTEN=()
declare -A SNAP_USERREFS=()
declare -A SNAP_CLONES=()
declare -A SNAP_GUID=()
declare -A SNAP_TXG=()

mock_add_dataset() { DATASET_EXISTS["$1"]=1; }
mock_add_snapshot() {
  local snap="$1" creation="$2" written="$3"
  mock_add_dataset "${snap%@*}"
  SNAP_CREATION["$snap"]="$creation"
  SNAP_WRITTEN["$snap"]="$written"
  SNAP_USERREFS["$snap"]="0"
  SNAP_CLONES["$snap"]="-"
  SNAP_GUID["$snap"]="guid-${snap//[^A-Za-z0-9]/_}"
  SNAP_TXG["$snap"]="$creation"
}

dataset_exists() { [[ -n "${DATASET_EXISTS[$1]:-}" ]]; }
snapshot_exists() { [[ -n "${SNAP_CREATION[$1]:-}" ]]; }
list_tree_datasets() { printf '%s\n' "$1"; }
job_prefix_for_schedule() { printf 'zfs-send-%s-' "$1"; }
parse_send_checkpoint_schedule_id() {
  local base="$1"
  [[ "$base" == zfs-send-job1-* ]] || return 1
  printf 'job1'
}
send_retention_keep_all_seconds() { printf '1'; }
send_retention_keep_daily_until_seconds() { printf '2'; }
send_retention_keep_weekly_until_seconds() { printf '3'; }
send_day_key_for_epoch() { printf '%s' "$(( $1 / 86400 ))"; }
send_week_key_for_epoch() { printf '%s' "$(( $1 / 604800 ))"; }
add_planned_reclaim_for_capacity_dataset() { :; }
ensure_active_delete_queue_index() { :; }
snapshot_delete_checkpoint_job_exists() { return 1; }
snapshot_delete_job_exists_for_snapshot() { return 1; }
submit_delete_queue_job() {
  local assoc_name="$1"
  local -n ref="$assoc_name"
  printf '%s\t%s\t%s\n' "${ref[DELETE_SCOPE]}" "${ref[SEND_SCHEDULE_JOB_ID]:-}" "${ref[SNAPSHOT_NAME]}" >> "${TEST_ROOT}/queued.tsv"
  return 0
}
log() { printf 'LOG: %s\n' "$*" >&2; }

zfs() {
  local cmd="${1:-}"
  if [[ "$cmd" == "get" ]]; then
    local dataset="${@: -1}" snap prop value
    for snap in "${!SNAP_CREATION[@]}"; do
      [[ "${snap%@*}" == "$dataset" ]] || continue
      for prop in creation written userrefs clones guid createtxg; do
        case "$prop" in
          creation) value="${SNAP_CREATION[$snap]}" ;;
          written) value="${SNAP_WRITTEN[$snap]}" ;;
          userrefs) value="${SNAP_USERREFS[$snap]}" ;;
          clones) value="${SNAP_CLONES[$snap]}" ;;
          guid) value="${SNAP_GUID[$snap]}" ;;
          createtxg) value="${SNAP_TXG[$snap]}" ;;
        esac
        printf '%s\t%s\t%s\n' "$snap" "$prop" "$value"
      done
    done
    return 0
  fi
  if [[ "$cmd" == "list" ]]; then
    local dataset="${@: -1}" snap
    for snap in "${!SNAP_CREATION[@]}"; do
      [[ "${snap%@*}" == "$dataset" ]] || continue
      printf '%s\t%s\n' "$snap" "${SNAP_CREATION[$snap]}"
    done
    return 0
  fi
  printf 'unexpected zfs call: %s\n' "$*" >&2
  return 1
}

# Schedule model: one source/destination pair. Three snapshots all exist on both sides.
# Latest/current and previous have written=0 to stress zero-change cleanup.
SCHEDULE_JOB_IDS=(job1)
SCHEDULE_SOURCE_ROOT[job1]='tank/src'
SCHEDULE_DEST_ROOT[job1]='backup/src'
SCHEDULE_INCLUDE_CHILDREN[job1]='0'
mock_add_dataset 'tank/src'
mock_add_dataset 'backup/src'

for ds in tank/src backup/src; do
  mock_add_snapshot "${ds}@zfs-send-job1-old" 100 1024
  mock_add_snapshot "${ds}@zfs-send-job1-prev" 200 0
  mock_add_snapshot "${ds}@zfs-send-job1-current" 300 0
done

latest=''
latest_checkpoint_basename_for_schedule job1 latest
printf 'latest_common_before=%s\n' "$latest"
[[ "$latest" == 'zfs-send-job1-current' ]]

: > "${TEST_ROOT}/queued.tsv"
queue_schedule_zero_change_cleanup_for_dataset job1 backup/src zfs-send-job1-current
printf 'queued_after_zero_change:\n'
cat "${TEST_ROOT}/queued.tsv"

if grep -q $'checkpoint\tjob1\tzfs-send-job1-current' "${TEST_ROOT}/queued.tsv"; then
  printf 'FAIL: zero-change cleanup queued current latest common checkpoint\n' >&2
  exit 1
fi
if grep -q $'checkpoint\tjob1\tzfs-send-job1-prev' "${TEST_ROOT}/queued.tsv"; then
  printf 'FAIL: zero-change cleanup queued older send checkpoint instead of leaving checkpoint deletion to retention cleanup\n' >&2
  exit 1
fi
printf 'PASS: single-member zero-change cleanup leaves send checkpoints to retention cleanup\n'

# Multi-member stress: one child has current, another child only has prev. In that case
# prev is still the latest common checkpoint for the incomplete member and must not be queued.
clear_send_cleanup_caches
SCHEDULE_INCLUDE_CHILDREN[job1]='1'
list_tree_datasets() { printf '%s\n' 'tank/src' 'tank/src/child'; }
mock_add_dataset 'tank/src/child'
mock_add_dataset 'backup/src/child'
mock_add_snapshot 'tank/src/child@zfs-send-job1-old' 100 1024
mock_add_snapshot 'backup/src/child@zfs-send-job1-old' 100 1024
mock_add_snapshot 'tank/src/child@zfs-send-job1-prev' 200 0
mock_add_snapshot 'backup/src/child@zfs-send-job1-prev' 200 0
mock_add_snapshot 'tank/src/child@zfs-send-job1-current' 300 0
# Deliberately do NOT add backup/src/child@current.

: > "${TEST_ROOT}/queued.tsv"
latest=''
latest_checkpoint_basename_for_schedule job1 latest
printf 'latest_common_with_incomplete_child=%s\n' "$latest"
queue_schedule_zero_change_cleanup_for_dataset job1 backup/src zfs-send-job1-current
printf 'queued_with_incomplete_child:\n'
cat "${TEST_ROOT}/queued.tsv"
if grep -q $'checkpoint\tjob1\tzfs-send-job1-prev' "${TEST_ROOT}/queued.tsv"; then
  printf 'FAIL: zero-change cleanup queued prev even though another member still needs it as latest common\n' >&2
  exit 1
fi
printf 'PASS: multi-member zero-change cleanup protects checkpoint still common for an incomplete child\n'

# Delete-worker revalidation stress: if a send-protected checkpoint delete is processed
# while the schedule table is missing/stale, the latest-common guard cannot prove the
# snapshot is latest common. In production process_send_checkpoint_delete then falls
# through toward deletion instead of failing the protected delete.
clear_send_cleanup_caches
SCHEDULE_INCLUDE_CHILDREN[job1]='0'
list_tree_datasets() { printf '%s\n' "$1"; }
: > "${TEST_ROOT}/queued.tsv"
queue_snapshot_delete_job backup/src backup/src@zfs-send-job1-current 300 'loaded schedule should skip latest common' job1 checkpoint || true
if grep -q $'checkpoint\tjob1\tzfs-send-job1-current' "${TEST_ROOT}/queued.tsv"; then
  printf 'FAIL: loaded schedule queued latest common checkpoint\n' >&2
  exit 1
fi
unset 'SCHEDULE_SOURCE_ROOT[job1]' 'SCHEDULE_DEST_ROOT[job1]' 'SCHEDULE_INCLUDE_CHILDREN[job1]'
clear_send_cleanup_caches
queue_snapshot_delete_job backup/src backup/src@zfs-send-job1-current 300 'missing schedule must fail closed' job1 checkpoint || true
printf 'queued_with_missing_schedule_table:\n'
cat "${TEST_ROOT}/queued.tsv"
if grep -q $'checkpoint\tjob1\tzfs-send-job1-current' "${TEST_ROOT}/queued.tsv"; then
  printf 'FAIL: missing/stale schedule table queued latest-common checkpoint instead of failing closed\n' >&2
  exit 1
fi
printf 'PASS: missing/stale schedule table fails closed for protected checkpoint delete\n'
