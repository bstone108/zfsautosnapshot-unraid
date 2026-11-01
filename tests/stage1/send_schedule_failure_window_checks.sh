#!/bin/bash
# A failed scheduled member must end its window without blocking the next one,
# and a DST fall-back hour must not open an extra send window.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OPS_LIB="${ROOT_DIR}/source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/ops-queue-lib.sh"
WORKER="${ROOT_DIR}/source/usr/local/sbin/zfs_autosnapshot_send_worker"

# shellcheck source=/dev/null
source "$OPS_LIB"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"
  [[ "$actual" == "$expected" ]] || fail "${message}: expected '${expected}', got '${actual}'"
}

SCHEDULE_ID="ef8948aa4533"
ROOT=""

cleanup() {
  if [[ -n "$ROOT" && -d "$ROOT" ]]; then
    rm -rf "$ROOT"
  fi
}
trap cleanup EXIT

use_temp_root() {
  ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zfsas-schedule-window.XXXXXX")"
  CONFIG_DIR="${ROOT}/config"
  SEND_CONFIG_FILE="${CONFIG_DIR}/zfs_send.conf"
  OPS_ROOT="${ROOT}/ops"
  OPS_JOBS_DIR="${OPS_ROOT}/jobs"
  OPS_STATUS_DIR="${OPS_ROOT}/status"
  PERSISTED_QUEUE_DIR="${CONFIG_DIR}/runtime_queue"
  PERSISTED_DELETE_QUEUE_FILE="${PERSISTED_QUEUE_DIR}/delete-queue.persist"
  FAILED_SEND_LOGS_DIR="${CONFIG_DIR}/failed_send_logs"
  SEND_SCHEDULE_STATE_FILE="${CONFIG_DIR}/send_schedule_state.state"
  RUNTIME_DIR="${ROOT}/run"
  LOG_FILE="${ROOT}/send.log"
  LOG_ARCHIVE_FILE="${ROOT}/send.archive.log"
  : > "$LOG_FILE"
  ensure_runtime_layout || fail "unable to create temp queue layout"
  printf 'SEND_JOBS="%s|tank/data|backup/data|1d|0|1|local"\n' "$SCHEDULE_ID" > "$SEND_CONFIG_FILE"
  SEND_JOBS_PARSED=1
  SCHEDULE_JOB_IDS=("$SCHEDULE_ID")
  SCHEDULE_SOURCE_ROOT["$SCHEDULE_ID"]="tank/data"
  SCHEDULE_DEST_ROOT["$SCHEDULE_ID"]="backup/data"
  SCHEDULE_FREQUENCY["$SCHEDULE_ID"]="1d"
  SCHEDULE_THRESHOLD_RAW["$SCHEDULE_ID"]="0"
  SCHEDULE_THRESHOLD_BYTES["$SCHEDULE_ID"]="0"
  SCHEDULE_INCLUDE_CHILDREN["$SCHEDULE_ID"]="1"
  SCHEDULE_TRANSPORT["$SCHEDULE_ID"]="local"
  SCHEDULE_PREFIX["$SCHEDULE_ID"]="zfs-send-${SCHEDULE_ID}-"
  SCHEDULE_LAST_COMPLETED_WINDOW=()
}

scheduled_send_job_zfs_actionable() {
  return 0
}

schedule_can_resume_current_window() {
  return 1
}

reset_jobs() {
  rm -f "${OPS_JOBS_DIR}/"*.job "${SEND_SCHEDULE_STATE_FILE}"
  SCHEDULE_LAST_COMPLETED_WINDOW=()
}

write_state() {
  local window_key="$1"
  printf '%s|%s\n' "$SCHEDULE_ID" "$window_key" > "$SEND_SCHEDULE_STATE_FILE"
}

write_send_job() {
  local file_stamp="$1"
  local job_id="$2"
  local state="$3"
  local action="$4"
  local window_key="$5"
  local completes="${6:-0}"
  local path="${OPS_JOBS_DIR}/${file_stamp}-${job_id}.job"
  cat > "$path" <<EOF
JOB_ID="${job_id}"
JOB_TYPE="send"
JOB_MODE="scheduled"
JOB_ACTION="${action}"
STATE="${state}"
PHASE="${state}"
SCHEDULE_JOB_ID="${SCHEDULE_ID}"
WINDOW_KEY="${window_key}"
RETRY_AT="0"
COMPLETES_SCHEDULE_WINDOW="${completes}"
SOURCE_ROOT="tank/data"
DESTINATION_ROOT="backup/data"
LAST_ERROR="No common send checkpoint remains"
LAST_MESSAGE="No common send checkpoint remains"
EOF
  printf '%s\n' "$path"
}

count_prepare_jobs() {
  local window_key="$1"
  find "$OPS_JOBS_DIR" -maxdepth 1 -type f -name "*-send-${SCHEDULE_ID}-${window_key}.job" 2>/dev/null | wc -l | tr -d ' '
}

state_window() {
  load_schedule_state
  last_completed_schedule_window_key "$SCHEDULE_ID"
}

legacy_window_key() {
  local frequency="$1"
  local now_epoch="$2"
  local seconds offset local_epoch
  case "$frequency" in
    6h) seconds=21600 ;;
    12h) seconds=43200 ;;
    1d) seconds=86400 ;;
    7d) seconds=604800 ;;
    *) fail "unknown frequency ${frequency}" ;;
  esac
  offset="$(timezone_offset_seconds "$now_epoch")"
  local_epoch=$((now_epoch + offset))
  echo $(( (local_epoch - (local_epoch % seconds)) - offset ))
}

echo "PASS setup: remote retry and auto-reseed defaults stay in place"
[[ "$(send_remote_max_attempts)" == "1" ]] || fail "queue kicks must stay single-attempt"
SEND_REMOTE_RETRIES_ENABLED=1
[[ "$(send_remote_max_attempts)" == "5" ]] || fail "send worker retries must stay at 5 attempts"
[[ "$(send_remote_retry_delay_seconds)" == "300" ]] || fail "send retry delay must stay at 5 minutes"
send_auto_reseed_enabled || fail "SEND_AUTO_RESEED must stay enabled"
[[ "$FAILED_JOB_TTL_SECONDS" == "86400" ]] || fail "failed jobs should remain visible for a day before purge"

if grep -q 'queued|running|retry_wait|failed' "${OPS_LIB}"; then
  fail "schedule_job_blocked must not treat failed as an active state"
fi
if grep -q 'Skipped; child failed.' "$WORKER"; then
  fail "a failed member must end the window instead of skipping the finalizer without recording it"
fi
if ! grep -q 'Scheduled window finished partial:' "$WORKER"; then
  fail "a mixed member result must finish the window as partial"
fi
if ! grep -q 'Scheduled window failed:' "$WORKER"; then
  fail "a fully failed member set must finish the window as failed"
fi
if ! grep -q 'defer_current_job "Waiting for children." 1' "$WORKER"; then
  fail "the finalizer must keep waiting while other members are still sending"
fi

TZ=UTC
use_temp_root
export TZ

NOV1="$(date -u -d '2026-11-01 12:00:00' +%s)"
NOV2="$(date -u -d '2026-11-02 12:00:00' +%s)"
OCT30="$(date -u -d '2026-10-30 12:00:00' +%s)"
OCT31="$(date -u -d '2026-10-31 12:00:00' +%s)"
WINDOW_OCT30="$(frequency_window_key 1d "$OCT30")"
WINDOW_OCT31="$(frequency_window_key 1d "$OCT31")"
WINDOW_NOV1="$(frequency_window_key 1d "$NOV1")"
WINDOW_NOV2="$(frequency_window_key 1d "$NOV2")"
[[ "$WINDOW_OCT30" != "$WINDOW_NOV1" ]] || fail "daily windows must differ across days"
[[ "$WINDOW_NOV1" != "$WINDOW_NOV2" ]] || fail "Nov 1 and Nov 2 must be different daily windows"

reset_jobs
failed_path="$(write_send_job 1000 "send-child-${SCHEDULE_ID}-0" failed send_member "$WINDOW_OCT30" 0)"
queued_path="$(write_send_job 1001 "send-child-${SCHEDULE_ID}-1" queued send_member "$WINDOW_OCT30" 0)"
retry_path="$(write_send_job 1002 "send-child-${SCHEDULE_ID}-2" retry_wait send_member "$WINDOW_OCT30" 0)"
running_path="$(write_send_job 1003 "send-child-${SCHEDULE_ID}-3" running send_member "$WINDOW_OCT30" 0)"
schedule_job_blocked "$SCHEDULE_ID" || fail "queued, running, or retry_wait work must still block the schedule"
rm -f "$queued_path" "$retry_path" "$running_path"
if schedule_job_blocked "$SCHEDULE_ID"; then
  fail "a failed member must not block the schedule or --manual-now"
fi

reset_jobs
write_state "$WINDOW_OCT30"
active_path="$(write_send_job 1004 "send-child-${SCHEDULE_ID}-active" queued send_member "$WINDOW_NOV1" 0)"
failed_current="$(write_send_job 1005 "send-child-${SCHEDULE_ID}-failed" failed send_member "$WINDOW_NOV1" 0)"
settle_terminal_failed_jobs "$NOV1"
assert_eq "$(state_window)" "$WINDOW_OCT30" "an in-progress window must not be closed while a sibling is still queued"
[[ -f "$failed_current" ]] || fail "a failed member must stay while its window is still running"
enqueue_scheduled_send_jobs_due "$NOV1"
assert_eq "$(count_prepare_jobs "$WINDOW_NOV1")" "0" "an active window must not be started again"
rm -f "$active_path"

reset_jobs
write_state "$WINDOW_OCT31"
recent_failed="$(write_send_job 1006 "send-child-${SCHEDULE_ID}-recent" failed send_member "$WINDOW_NOV1" 0)"
touch -d '2026-11-01 12:00:00 UTC' "$recent_failed"
settle_terminal_failed_jobs "$NOV1"
assert_eq "$(state_window)" "$WINDOW_NOV1" "a terminal failed member must end the current window"
[[ -f "$recent_failed" ]] || fail "a recent failed member must stay visible until its purge time"
if schedule_job_blocked "$SCHEDULE_ID"; then
  fail "the ended window's failed member must not block later windows"
fi
enqueue_scheduled_send_jobs_due "$NOV1"
assert_eq "$(count_prepare_jobs "$WINDOW_NOV1")" "0" "the failed window must not start again the same day"
enqueue_scheduled_send_jobs_due "$NOV2"
assert_eq "$(count_prepare_jobs "$WINDOW_NOV2")" "1" "the next daily window must start for the schedule, including the dataset that failed"
[[ -f "$recent_failed" ]] || fail "the previous failure must still be on disk when the next window starts"

reset_jobs
write_state "$WINDOW_OCT30"
ancient="$(write_send_job 1007 "send-child-${SCHEDULE_ID}-ancient" failed send_member "$WINDOW_OCT31" 0)"
touch -d '2026-10-30 12:00:00 UTC' "$ancient"
if grep -q 'PURGE_AFTER_EPOCH=' "$ancient"; then
  fail "the fixture must reproduce a failed job with no purge time"
fi
settle_terminal_failed_jobs "$NOV1"
assert_eq "$(state_window)" "$WINDOW_OCT31" "a stale failed job must close its unfinished window on the next queue pass"
[[ ! -f "$ancient" ]] || fail "a stale failed job older than the retention must be removed without a manual delete"
if schedule_job_blocked "$SCHEDULE_ID"; then
  fail "removing the stale failed job must leave the schedule unblocked"
fi
enqueue_scheduled_send_jobs_due "$NOV1"
assert_eq "$(count_prepare_jobs "$WINDOW_NOV1")" "1" "after upgrade the next window must start without deleting the failed job by hand"

reset_jobs
write_state "$WINDOW_OCT30"
# shellcheck disable=SC2034
declare -A job=()
job[JOB_ID]="send-child-${SCHEDULE_ID}-member"
job[JOB_TYPE]="send"
job[JOB_MODE]="scheduled"
job[JOB_ACTION]="send_member"
job[STATE]="running"
job[SCHEDULE_JOB_ID]="$SCHEDULE_ID"
job[WINDOW_KEY]="$WINDOW_NOV1"
job[COMPLETES_SCHEDULE_WINDOW]="0"
mark_job_terminal_failure job "No common send checkpoint remains" "$NOV1"
assert_eq "${job[STATE]}" "failed" "terminal failure must record the member as failed"
assert_eq "${job[PHASE]}" "failed" "terminal failure must set PHASE=failed"
[[ "${job[PURGE_AFTER_EPOCH]}" =~ ^[0-9]+$ ]] || fail "a newly failed job must get a purge time"
(( job[PURGE_AFTER_EPOCH] > NOV1 )) || fail "a newly failed job must stay until its purge time"
assert_eq "$(state_window)" "$WINDOW_OCT30" "a member failure must not record the window before the finalizer finishes"
job[JOB_ACTION]="finalize"
job[COMPLETES_SCHEDULE_WINDOW]="1"
job[MEMBER_COUNT]="31"
mark_job_terminal_failure job "Scheduled window finished partial: 1 of 31 dataset send(s) failed." "$NOV1"
assert_eq "$(state_window)" "$WINDOW_NOV1" "the finalizer must record a partial window as finished"

echo "PASS: failed members end the window and the next window still starts"

TZ=America/Chicago
export TZ
epoch_0030="$(date -d '2026-11-01 00:30:00' +%s)"
epoch_0103_cst="$(date -d '2026-11-01 01:03:00 -0600' +%s)"
epoch_0600="$(date -d '2026-11-01 06:00:00' +%s)"
epoch_noon="$(date -d '2026-11-01 12:00:00' +%s)"
epoch_next_midnight="$(date -d '2026-11-02 00:00:00' +%s)"
epoch_oct30="$(date -d '2026-10-30 12:00:00' +%s)"
epoch_nov5="$(date -d '2026-11-05 00:00:00' +%s)"
epoch_normal="$(date -d '2026-11-02 12:00:00' +%s)"
# Nov 2 is still inside the week the old offset math shifts. A week that does
# not contain the transition must keep the previous alignment.
epoch_stable_week="$(date -d '2026-10-20 12:00:00' +%s)"

for frequency in 6h 12h 1d; do
  before="$(frequency_window_key "$frequency" "$epoch_0030")"
  during="$(frequency_window_key "$frequency" "$epoch_0103_cst")"
  legacy="$(legacy_window_key "$frequency" "$epoch_0103_cst")"
  assert_eq "$during" "$before" "${frequency} fall-back 01:03 CST must stay in the window that was already open at 00:30 CDT"
  [[ "$during" != "$legacy" ]] || fail "${frequency} legacy offset math must be the extra window we removed at 01:03 CST"
  at_0600="$(frequency_window_key "$frequency" "$epoch_0600")"
  if [[ "$frequency" == "6h" ]]; then
    [[ "$at_0600" != "$during" ]] || fail "6h must still open its next real window at 06:00 CST"
    (( at_0600 > during )) || fail "6h windows must move forward after the fall-back hour"
  else
    assert_eq "$at_0600" "$during" "${frequency} 06:00 CST must stay in the window opened at local midnight"
  fi
  if [[ "$frequency" == "12h" ]]; then
    noon="$(frequency_window_key 12h "$epoch_noon")"
    [[ "$noon" != "$during" ]] || fail "12h must open its next window at local noon"
  fi
  if [[ "$frequency" == "1d" ]]; then
    next_day="$(frequency_window_key 1d "$epoch_next_midnight")"
    [[ "$next_day" != "$during" ]] || fail "daily sends must open the next window at the next local midnight"
  fi
  normal="$(frequency_window_key "$frequency" "$epoch_normal")"
  assert_eq "$normal" "$(legacy_window_key "$frequency" "$epoch_normal")" "${frequency} window keys must stay unchanged on a normal day"
done

weekly_before="$(frequency_window_key 7d "$epoch_oct30")"
weekly_during="$(frequency_window_key 7d "$epoch_0103_cst")"
weekly_next="$(frequency_window_key 7d "$epoch_nov5")"
assert_eq "$weekly_during" "$weekly_before" "weekly fall-back 01:03 CST must stay in the week that was already open"
[[ "$weekly_during" != "$(legacy_window_key 7d "$epoch_0103_cst")" ]] || fail "weekly legacy offset math must be the extra window we removed"
[[ "$weekly_next" != "$weekly_during" ]] || fail "weekly schedule must still roll forward on its next boundary"
assert_eq "$(frequency_window_key 7d "$epoch_stable_week")" "$(legacy_window_key 7d "$epoch_stable_week")" "weekly keys must stay unchanged on a week that does not contain a DST transition"

echo "PASS: DST fall-back does not open an extra send window"
echo "PASS: send schedule failure window checks"
