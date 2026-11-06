#!/bin/bash
# Space approval must not loop when destination cleanup cannot free space.
# A 30-minute delete retry_wait still waits. An exhausted SSH host fails the
# send without planning again. A plan that queues nothing fails after one
# cooldown. The next scheduled retention pass is what clears that host.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${ROOT_DIR}/source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/ops-queue-lib.sh"
DELETE_WORKER="${ROOT_DIR}/source/usr/local/sbin/zfs_autosnapshot_delete_worker"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

SCHEDULE="sched0001dead"
OTHER="sched0002beef"
ALPHA="alpha.example"
MOCK_NOW=1700000000
OUT=""
SSH_LOG=""
SSH_MODE=""
PLAN_LOG=""
RETENTION_PLAN_CALLS=0
FREESPACE_PLAN_CALLS=0
RELEASED_JOB_IDS=""

export ZFSAS_OPS_LIB="$LIB"
export ZFSAS_DELETE_WORKER_AS_LIBRARY=1

ROOT="$(mktemp -d)"
mkdir -p "${ROOT}/bin" "${ROOT}/ops/jobs" "${ROOT}/ops/status" "${ROOT}/run/delete-worker" "${ROOT}/persist" "${ROOT}/config"
export PATH="${ROOT}/bin:${PATH}"
export CONFIG_DIR="${ROOT}/config"
export SEND_CONFIG_FILE="${ROOT}/config/zfs_send.conf"
export OPS_ROOT="${ROOT}/ops"
export OPS_JOBS_DIR="${ROOT}/ops/jobs"
export OPS_STATUS_DIR="${ROOT}/ops/status"
export DELETE_QUEUE_STATE_FILE="${ROOT}/ops/status/delete-queue.state"
export DELETE_QUEUE_INBOX_FILE="${ROOT}/ops/delete-queue.inbox"
export DELETE_QUEUE_INBOX_LOCK_FILE="${ROOT}/ops/delete-queue.inbox.lock"
export PERSISTED_QUEUE_DIR="${ROOT}/persist"
export PERSISTED_DELETE_QUEUE_FILE="${ROOT}/persist/delete-queue.persist"
export RUNTIME_DIR="${ROOT}/run"
export LOG_FILE="${ROOT}/send.log"
export DELETE_WORKER_RUNTIME_DIR="${ROOT}/run/delete-worker"
export DELETE_QUEUE_PID_FILE="${ROOT}/run/delete-worker/daemon.pid"
export DELETE_QUEUE_LOCK_DIR="${ROOT}/run/delete-worker/daemon.lockdir"
export JOB_LOCKS_DIR="${ROOT}/run/job-locks"
: > "$LOG_FILE"
: > "$SEND_CONFIG_FILE"

# shellcheck source=/dev/null
source "$DELETE_WORKER"

CONFIG_DIR="${ROOT}/config"
SEND_CONFIG_FILE="${ROOT}/config/zfs_send.conf"
OPS_ROOT="${ROOT}/ops"
OPS_JOBS_DIR="${ROOT}/ops/jobs"
OPS_STATUS_DIR="${ROOT}/ops/status"
DELETE_QUEUE_STATE_FILE="${ROOT}/ops/status/delete-queue.state"
DELETE_QUEUE_INBOX_FILE="${ROOT}/ops/delete-queue.inbox"
DELETE_QUEUE_INBOX_LOCK_FILE="${ROOT}/ops/delete-queue.inbox.lock"
PERSISTED_QUEUE_DIR="${ROOT}/persist"
PERSISTED_DELETE_QUEUE_FILE="${ROOT}/persist/delete-queue.persist"
RUNTIME_DIR="${ROOT}/run"
LOG_FILE="${ROOT}/send.log"
DELETE_WORKER_RUNTIME_DIR="${ROOT}/run/delete-worker"
DELETE_QUEUE_PID_FILE="${ROOT}/run/delete-worker/daemon.pid"
DELETE_QUEUE_LOCK_DIR="${ROOT}/run/delete-worker/daemon.lockdir"
JOB_LOCKS_DIR="${ROOT}/run/job-locks"
PREP_LOCKS_DIR="${ROOT}/run/prep-locks"
SEND_SPACE_RESERVATION_DIR="${ROOT}/run/send-space-reservations"
SEND_SPACE_RESERVATION_LOCK_FILE="${ROOT}/run/send-space-reservations.lock"
FAILED_SEND_LOGS_DIR="${ROOT}/config/failed_send_logs"
SEND_SCHEDULE_STATE_FILE="${ROOT}/config/send_schedule_state.state"
mkdir -p "$OPS_JOBS_DIR" "$OPS_STATUS_DIR" "$JOB_LOCKS_DIR" "$PREP_LOCKS_DIR" "$SEND_SPACE_RESERVATION_DIR" "$FAILED_SEND_LOGS_DIR" "$PERSISTED_QUEUE_DIR"
ensure_runtime_layout || fail "runtime layout was not created"

# Keep the original planners. Space-approval tests replace the names so they
# can see whether approval tried to plan. The scheduled-retry test calls the
# originals.
eval "$(declare -f queue_pool_retention_cleanup | sed '1s/^queue_pool_retention_cleanup/queue_pool_retention_cleanup_real/')"
eval "$(declare -f queue_pool_free_space_cleanup_for_target | sed '1s/^queue_pool_free_space_cleanup_for_target/queue_pool_free_space_cleanup_for_target_real/')"
eval "$(declare -f release_send_space_reservation_for_job | sed '1s/^release_send_space_reservation_for_job/release_send_space_reservation_for_job_real/')"

queue_pool_retention_cleanup() {
  RETENTION_PLAN_CALLS=$((RETENTION_PLAN_CALLS + 1))
  printf '%s\n' "$*" >> "${PLAN_LOG:?}"
  return 0
}
queue_pool_free_space_cleanup_for_target() {
  FREESPACE_PLAN_CALLS=$((FREESPACE_PLAN_CALLS + 1))
  printf '%s\n' "$*" >> "${PLAN_LOG:?}"
  return 0
}
release_send_space_reservation_for_job() {
  RELEASED_JOB_IDS="${RELEASED_JOB_IDS} ${1:-}"
  release_send_space_reservation_for_job_real "$@"
}

delete_queue_now_epoch_hook() { printf '%s\n' "$MOCK_NOW"; }
start_delete_queue_daemon() { return 0; }
checkpoint_basename_is_latest_common_for_schedule() { return 1; }
snapshot_delete_conflicts_with_send_jobs() { return 1; }
get_pool_freeing_for_transport() { printf '0'; }
nearest_existing_dataset_ancestor_for_transport() { printf '%s\n' "$1"; }

# Approval reads the clock with date +%s. Tests step that clock without sleeping.
date() {
  if [[ "${1:-}" == "+%s" ]]; then
    printf '%s\n' "${MOCK_NOW:?}"
    return 0
  fi
  command date "$@"
}

log() {
  printf '%s %s\n' "TEST" "$*" >> "${OUT:?}"
}

acquire_send_space_reservation_for_transport() {
  local destination="$3"
  local available_var="$7"
  local needed_var="$8"
  if [[ "$destination" == "other/data" ]]; then
    printf -v "$available_var" '%s' 5000
    printf -v "$needed_var" '%s' 1000
    return 0
  fi
  printf -v "$available_var" '%s' 0
  printf -v "$needed_var" '%s' 1000
  return 1
}

SEND_SSH_HOST="$ALPHA"
SEND_SSH_PORT="22"
SEND_SSH_USER="root"
SEND_SSH_KEY_PATH="/root/.ssh/id_ed25519"
SEND_SNAPSHOT_PREFIX="zfs-send-"
SCHEDULE_JOB_IDS=("$SCHEDULE" "$OTHER")
SCHEDULE_SOURCE_ROOT["$SCHEDULE"]="cache/appdata"
SCHEDULE_DEST_ROOT["$SCHEDULE"]="backup/appdata"
SCHEDULE_TRANSPORT["$SCHEDULE"]="ssh"
SCHEDULE_PREFIX["$SCHEDULE"]="zfs-send-${SCHEDULE}-"
SCHEDULE_INCLUDE_CHILDREN["$SCHEDULE"]="0"
SCHEDULE_FREQUENCY["$SCHEDULE"]="1d"
SCHEDULE_THRESHOLD_RAW["$SCHEDULE"]="0"
SCHEDULE_THRESHOLD_BYTES["$SCHEDULE"]="0"
SCHEDULE_SOURCE_ROOT["$OTHER"]="cache/other"
SCHEDULE_DEST_ROOT["$OTHER"]="other/data"
SCHEDULE_TRANSPORT["$OTHER"]="ssh"
SCHEDULE_PREFIX["$OTHER"]="zfs-send-${OTHER}-"
SCHEDULE_INCLUDE_CHILDREN["$OTHER"]="0"
SCHEDULE_FREQUENCY["$OTHER"]="1d"
SCHEDULE_THRESHOLD_RAW["$OTHER"]="0"
SCHEDULE_THRESHOLD_BYTES["$OTHER"]="0"

cat > "${ROOT}/bin/ssh" <<'EOF'
#!/bin/bash
printf 'SSH %s\n' "$*" >> "${SSH_LOG:?}"
# OpenSSH reads the caller's stdin unless -n is set. Drain it so a while-read
# loop cannot hide a missing -n. A tty is left alone so a local run does not block.
if [[ " $* " != *" -n "* ]] && [[ ! -t 0 ]]; then
  cat >/dev/null || true
fi
host_arg=""
if (( $# >= 2 )); then
  host_arg="${@: -2:1}"
fi
host="${host_arg#*@}"
mode="ok"
if [[ -f "${SSH_MODE:?}" ]]; then
  while IFS=$'\t' read -r seen_host seen_mode; do
    if [[ "$seen_host" == "$host" ]]; then
      mode="$seen_mode"
    fi
  done < "$SSH_MODE"
fi
case "$mode" in
  fail)
    echo "ssh: connect to host ${host} port 22: Connection refused" >&2
    exit 255
    ;;
  ok)
    exit 0
    ;;
  *)
    echo "unknown ssh mode ${mode}" >&2
    exit 1
    ;;
esac
EOF
cat > "${ROOT}/bin/zfs" <<'EOF'
#!/bin/bash
echo "local zfs must not run for these remote space checks: $*" >&2
exit 1
EOF
chmod 755 "${ROOT}/bin/ssh" "${ROOT}/bin/zfs"

reset_queue() {
  QUEUE_IDS=()
  QUEUE_HEAD_INDEX=0
  QUEUE_MAX_INDEX=-1
  QUEUE_ACTIVE_COUNT=0
  QUEUE_RUNNING_COUNT=0
  QUEUE_RETRY_WAIT_COUNT=0
  QUEUE_QUEUED_COUNT=0
  QUEUE_INDEX_BY_ID=()
  QUEUE_STATE=()
  QUEUE_RETRY_AT=()
  QUEUE_REQUESTED_EPOCH=()
  QUEUE_QUEUE_SORT=()
  QUEUE_DATASET=()
  QUEUE_SNAPSHOT=()
  QUEUE_SNAPSHOT_NAME=()
  QUEUE_SNAPSHOT_EPOCH=()
  QUEUE_SNAPSHOT_GUID=()
  QUEUE_SNAPSHOT_CREATETXG=()
  QUEUE_DELETE_POOL=()
  QUEUE_ESTIMATED_RECLAIM_BYTES=()
  QUEUE_SEND_PROTECTED=()
  QUEUE_DELETE_SCOPE=()
  QUEUE_SEND_SCHEDULE_JOB_ID=()
  QUEUE_SEND_TRANSPORT=()
  QUEUE_DEST_HOST=()
  QUEUE_WORKER_PID=()
  QUEUE_BY_SNAPSHOT=()
  QUEUE_BY_CHECKPOINT=()
  CURRENT_JOB_ID=""
  STATE_DIRTY=0
  DELETE_QUEUE_INDEX_LOADED=0
  rm -f "$(delete_dest_transport_state_path)" "$DELETE_QUEUE_STATE_FILE" "$DELETE_QUEUE_INBOX_FILE"
  rm -f "${OPS_JOBS_DIR}/"*.job "${SEND_SPACE_RESERVATION_DIR}/"*.reservation
  rm -rf "${JOB_LOCKS_DIR}/"* "${PREP_LOCKS_DIR}/"*
}

begin_case() {
  local name="$1"
  OUT="${ROOT}/${name}.out"
  SSH_LOG="${ROOT}/${name}.ssh"
  SSH_MODE="${ROOT}/${name}.mode"
  PLAN_LOG="${ROOT}/${name}.plan"
  : > "$OUT"
  : > "$SSH_LOG"
  : > "$SSH_MODE"
  : > "$PLAN_LOG"
  : > "$LOG_FILE"
  export SSH_LOG SSH_MODE
  MOCK_NOW=1700000000
  RETENTION_PLAN_CALLS=0
  FREESPACE_PLAN_CALLS=0
  RELEASED_JOB_IDS=""
  reset_queue
  clear_send_cleanup_caches
}

set_mode() {
  local host="$1"
  local mode="$2"
  printf '%s\t%s\n' "$host" "$mode" > "$SSH_MODE"
}

fail_count_for() {
  local host="$1"
  local path
  path="$(delete_dest_transport_state_path)"
  if [[ ! -f "$path" ]]; then
    printf '0'
    return 0
  fi
  awk -F '\t' -v h="$host" '$1 == h { print $2; found = 1 } END { if (!found) print 0 }' "$path"
}

mark_transport_failures() {
  local host="$1"
  local times="$2"
  local i
  for ((i = 0; i < times; i++)); do
    delete_dest_transport_locked_update "$host" fail >/dev/null || fail "could not record a connection failure for ${host}"
  done
}

write_send_job() {
  local name="$1"
  local destination="$2"
  local schedule_id="$3"
  local path="${OPS_JOBS_DIR}/${name}.job"
  local -A job=()

  job[JOB_ID]="$name"
  job[JOB_TYPE]="send"
  job[JOB_MODE]="scheduled"
  job[JOB_ACTION]="send_member"
  job[STATE]="queued"
  job[PHASE]="queued"
  job[RETRY_AT]="0"
  job[QUEUE_SORT]="1"
  job[SCHEDULE_JOB_ID]="$schedule_id"
  job[WINDOW_KEY]="100"
  job[COMPLETES_SCHEDULE_WINDOW]="0"
  job[SEND_TRANSPORT]="ssh"
  job[SEND_PLAN_DESTINATION]="$destination"
  job[DESTINATION_ROOT]="$destination"
  job[SOURCE_ROOT]="cache/appdata"
  job[SPACE_REQUIRED_BYTES]="100000"
  job[SPACE_ESTIMATE_KEY]="${destination}|full"
  job[THRESHOLD_BYTES]="0"
  job_write "$path" job || fail "could not write ${name}"
  printf '%s\n' "$path"
}

field_of() {
  local path="$1"
  local key="$2"
  local -A loaded=()
  job_load "$path" loaded || fail "could not read ${path}"
  job_get loaded "$key"
}

seed_retry_wait_delete() {
  local -A job=()
  job[JOB_ID]="del-wait"
  job[STATE]="retry_wait"
  job[RETRY_AT]="$((MOCK_NOW + 1800))"
  job[REQUESTED_EPOCH]="$MOCK_NOW"
  job[QUEUE_SORT]="1"
  job[DATASET]="backup/appdata"
  job[SNAPSHOT]="backup/appdata@zfs-send-${SCHEDULE}-old"
  job[SNAPSHOT_NAME]="zfs-send-${SCHEDULE}-old"
  job[SNAPSHOT_EPOCH]="$MOCK_NOW"
  job[DELETE_POOL]="backup"
  job[ESTIMATED_RECLAIM_BYTES]="1"
  job[SEND_PROTECTED]="1"
  job[DELETE_SCOPE]="destination_checkpoint"
  job[SEND_SCHEDULE_JOB_ID]="$SCHEDULE"
  job[SEND_TRANSPORT]="ssh"
  job[DEST_HOST]="$ALPHA"
  delete_queue_emit_state_line job > "$DELETE_QUEUE_STATE_FILE"
  DELETE_QUEUE_INDEX_LOADED=0
}

add_delete_job() {
  local job_id="$1"
  local host="$2"
  local snap="$3"
  local -A job=()

  job[JOB_ID]="$job_id"
  job[STATE]="queued"
  job[RETRY_AT]="0"
  job[SNAPSHOT]="$snap"
  job[SNAPSHOT_NAME]="${snap##*@}"
  job[DATASET]="${snap%@*}"
  job[DELETE_SCOPE]="destination_checkpoint"
  job[SEND_PROTECTED]="1"
  job[SEND_SCHEDULE_JOB_ID]="$SCHEDULE"
  job[SEND_TRANSPORT]="ssh"
  job[DEST_HOST]="$host"
  job[QUEUE_SORT]="1"
  queue_add_job job
}

LAST_RAN=""
run_one() {
  local id=""
  next_ready_job_id id || return 1
  CURRENT_JOB_ID="$id"
  mark_job_running
  process_delete_job || true
  CURRENT_JOB_ID=""
  LAST_RAN="$id"
}

assert_ssh_uses_n() {
  local label="$1"
  local line saw=0
  [[ -s "$SSH_LOG" ]] || fail "${label}: expected an ssh command so -n can be checked"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    saw=1
    [[ "$line" == *" -n "* ]] || fail "${label}: ssh dropped -n: ${line}"
  done < "$SSH_LOG"
  (( saw == 1 )) || fail "${label}: ssh log was empty"
}

assert_no_prep_lock() {
  local pool="$1"
  [[ ! -d "$(prep_lock_dir_for_pool "$pool")" ]] || fail "pool prep lock for ${pool} was left behind"
}

test_backoff_wait_still_waits() {
  local path state message
  begin_case "backoff-wait"
  set_mode "$ALPHA" fail
  mark_transport_failures "$ALPHA" 2
  seed_retry_wait_delete
  path="$(write_send_job send-backoff "backup/appdata" "$SCHEDULE")"
  [[ "$(fail_count_for "$ALPHA")" == "2" ]] || fail "setup count was $(fail_count_for "$ALPHA")"

  if approve_send_job_space_for_launch "$path" "$$"; then
    fail "a send with cleanup still in retry_wait should keep waiting"
  fi
  state="$(field_of "$path" STATE)"
  message="$(field_of "$path" LAST_MESSAGE)"
  [[ "$state" == "retry_wait" ]] || fail "backoff send state was ${state}"
  [[ "$message" == *"Waiting for queued destination cleanup to free space."* ]] || fail "backoff message was ${message}"
  [[ "$(fail_count_for "$ALPHA")" == "2" ]] || fail "waiting replanned the host: count $(fail_count_for "$ALPHA")"
  [[ "$RETENTION_PLAN_CALLS" == "0" && "$FREESPACE_PLAN_CALLS" == "0" ]] || fail "waiting planned cleanup: $(cat "$PLAN_LOG")"
  if grep -F "planning retention" "$OUT"; then
    fail "waiting cleared the destination backoff: $(cat "$OUT")"
  fi

  MOCK_NOW=$((MOCK_NOW + 10))
  if approve_send_job_space_for_launch "$path" "$$"; then
    fail "the send left the wait while the delete retry_wait was still in the future"
  fi
  state="$(field_of "$path" STATE)"
  [[ "$state" == "retry_wait" ]] || fail "second wait changed the send to ${state}"
  [[ "$(field_of "$path" STATE)" != "failed" ]] || fail "backoff wait failed the send"
  [[ "$(fail_count_for "$ALPHA")" == "2" ]] || fail "second wait changed the failure count"
  [[ "$RETENTION_PLAN_CALLS" == "0" ]] || fail "second wait planned retention"
  assert_no_prep_lock backup
  echo "PASS: delete retry_wait still holds the send"
}

test_exhausted_host_fails_without_replan() {
  local path other_path state ready
  begin_case "exhausted"
  set_mode "$ALPHA" fail
  mark_transport_failures "$ALPHA" 3
  path="$(write_send_job send-exhausted "backup/appdata" "$SCHEDULE")"
  other_path="$(write_send_job send-other "other/data" "$OTHER")"
  acquire_job_claim "send-exhausted" || fail "could not claim the send that will fail"
  [[ "$(fail_count_for "$ALPHA")" == "3" ]] || fail "host was not exhausted before approval"

  if approve_send_job_space_for_launch "$path" "$$"; then
    fail "an exhausted destination should not launch the send"
  fi
  state="$(field_of "$path" STATE)"
  [[ "$state" == "failed" ]] || fail "exhausted send state was ${state}"
  [[ "$(field_of "$path" PHASE)" == "failed" ]] || fail "exhausted send phase was not failed"
  [[ "$(field_of "$path" RETRY_AT)" == "0" ]] || fail "exhausted send was left in a retry wait"
  [[ "$(field_of "$path" LAST_ERROR)" == "Destination cleanup unreachable after 3 connection failures; will retry on next scheduled backup." ]] \
    || fail "exhausted failure text was: $(field_of "$path" LAST_ERROR)"
  grep -F "Destination cleanup unreachable after 3 connection failures; will retry on next scheduled backup." "$OUT" >/dev/null \
    || fail "exhausted failure was not logged: $(cat "$OUT")"
  [[ "$RETENTION_PLAN_CALLS" == "0" && "$FREESPACE_PLAN_CALLS" == "0" ]] || fail "exhausted approval planned cleanup: $(cat "$PLAN_LOG")"
  [[ "$(fail_count_for "$ALPHA")" == "3" ]] || fail "exhausted approval cleared the host: count $(fail_count_for "$ALPHA")"
  if grep -F "planning retention" "$OUT"; then
    fail "exhausted approval replanned retention: $(cat "$OUT")"
  fi
  [[ "$RELEASED_JOB_IDS" == *" send-exhausted"* ]] || fail "failed send did not release its reservation: ${RELEASED_JOB_IDS:-<none>}"
  [[ ! -e "$(send_space_reservation_file_for_job send-exhausted)" ]] || fail "failed send left a space reservation"
  [[ ! -d "$(job_lock_dir_for_id send-exhausted)" ]] || fail "failed send left its job claim lock"
  assert_no_prep_lock backup
  if schedule_job_blocked "$SCHEDULE"; then
    fail "the failed send still blocks the next scheduled run"
  fi
  ready="$(list_ready_send_job_paths "$MOCK_NOW" non_pool_prep_ready 10 || true)"
  [[ "$ready" != *"$path"* ]] || fail "the failed send is still launchable"
  [[ "$ready" == *"$other_path"* ]] || fail "the other send was not ready: ${ready:-<none>}"

  if ! approve_send_job_space_for_launch "$other_path" "$$"; then
    fail "a send that fits should still be approved after the other send failed"
  fi
  [[ "$(field_of "$other_path" LAST_MESSAGE)" == "Destination space approved." ]] || fail "other send was not approved: $(field_of "$other_path" LAST_MESSAGE)"
  [[ "$(field_of "$path" STATE)" == "failed" ]] || fail "approving the other send reopened the failed send"
  [[ "$(fail_count_for "$ALPHA")" == "3" ]] || fail "approving the other send cleared the down host"
  [[ "$RETENTION_PLAN_CALLS" == "0" ]] || fail "approving the other send planned cleanup"

  if approve_send_job_space_for_launch "$path" "$$"; then
    fail "a second look at the failed send launched it"
  fi
  [[ "$(field_of "$path" STATE)" == "failed" ]] || fail "a second look changed the failed send"
  [[ "$RETENTION_PLAN_CALLS" == "0" ]] || fail "a second look planned cleanup"
  echo "PASS: exhausted destination fails the send and leaves other work alone"
}

test_zero_new_deletes_fail_after_one_cooldown() {
  local path state
  begin_case "nothing-queued"
  set_mode "$ALPHA" ok
  path="$(write_send_job send-empty "backup/appdata" "$SCHEDULE")"

  if approve_send_job_space_for_launch "$path" "$$"; then
    fail "the first empty plan should not launch the send"
  fi
  state="$(field_of "$path" STATE)"
  [[ "$state" == "queued" ]] || fail "the first empty plan changed state to ${state}"
  [[ "$(field_of "$path" SPACE_CLEANUP_QUEUED_NONE)" == "1" ]] || fail "the empty plan was not recorded"
  [[ "$(field_of "$path" SPACE_CLEANUP_REQUESTED_AT)" == "$MOCK_NOW" ]] || fail "cooldown did not start at the plan"
  [[ "$RETENTION_PLAN_CALLS" == "1" && "$FREESPACE_PLAN_CALLS" == "1" ]] || fail "the first pass did not plan once: retention=${RETENTION_PLAN_CALLS} free=${FREESPACE_PLAN_CALLS}"
  grep -F "planned_reclaim 0" "$PLAN_LOG" >/dev/null || fail "space approval did not ask retention to leave the down host alone: $(cat "$PLAN_LOG")"
  assert_no_prep_lock backup

  MOCK_NOW=$((MOCK_NOW + 29))
  if approve_send_job_space_for_launch "$path" "$$"; then
    fail "the send should still be inside the one cooldown"
  fi
  state="$(field_of "$path" STATE)"
  [[ "$state" == "retry_wait" ]] || fail "cooldown state was ${state}"
  [[ "$(field_of "$path" LAST_MESSAGE)" == *"Waiting for destination cleanup planning cooldown."* ]] || fail "cooldown message was $(field_of "$path" LAST_MESSAGE)"
  [[ "$RETENTION_PLAN_CALLS" == "1" ]] || fail "cooldown planned again"
  [[ "$(field_of "$path" SPACE_CLEANUP_QUEUED_NONE)" == "1" ]] || fail "cooldown dropped the empty-plan marker"

  MOCK_NOW=$((MOCK_NOW + 1))
  if approve_send_job_space_for_launch "$path" "$$"; then
    fail "an empty plan should fail the send after one cooldown"
  fi
  [[ "$(field_of "$path" STATE)" == "failed" ]] || fail "empty plan left the send ${state}"
  [[ "$(field_of "$path" LAST_ERROR)" == *"Nothing left to clean; this send will retry on the next scheduled backup."* ]] \
    || fail "empty-plan failure text was: $(field_of "$path" LAST_ERROR)"
  grep -F "Nothing left to clean; this send will retry on the next scheduled backup." "$OUT" >/dev/null \
    || fail "empty-plan failure was not logged: $(cat "$OUT")"
  [[ "$RETENTION_PLAN_CALLS" == "1" && "$FREESPACE_PLAN_CALLS" == "1" ]] || fail "the failure planned another pass"
  [[ "$RELEASED_JOB_IDS" == *" send-empty"* ]] || fail "empty-plan failure did not release the reservation"
  [[ ! -e "$(send_space_reservation_file_for_job send-empty)" ]] || fail "empty-plan failure left a reservation"
  assert_no_prep_lock backup
  if schedule_job_blocked "$SCHEDULE"; then
    fail "the empty-plan failure still blocks the schedule"
  fi
  if list_ready_send_job_paths "$MOCK_NOW" non_pool_prep_ready 10 | grep -F "$path" >/dev/null; then
    fail "the failed send is still ready to launch"
  fi

  if approve_send_job_space_for_launch "$path" "$$"; then
    fail "looking at the failed send again launched it"
  fi
  [[ "$(field_of "$path" STATE)" == "failed" ]] || fail "another look reopened the failed send"
  [[ "$RETENTION_PLAN_CALLS" == "1" ]] || fail "another look planned cleanup again"
  echo "PASS: an empty cleanup plan fails the send after one cooldown"
}

test_next_scheduled_run_resets_and_retries() {
  local ran
  local -A planned_reclaim=()
  begin_case "next-schedule"
  set_mode "$ALPHA" fail
  mark_transport_failures "$ALPHA" 3
  [[ "$(fail_count_for "$ALPHA")" == "3" ]] || fail "host did not start exhausted"

  queue_pool_retention_cleanup_real "backup" "backup/appdata" planned_reclaim 0 || true
  [[ "$(fail_count_for "$ALPHA")" == "3" ]] || fail "space-approval retention cleared the down host"
  if grep -F "planning retention" "$OUT"; then
    fail "space-approval retention replanned: $(cat "$OUT")"
  fi
  assert_ssh_uses_n "space-approval retention"

  : > "$SSH_LOG"
  queue_pool_retention_cleanup_real "backup" "backup/appdata" planned_reclaim || true
  [[ "$(fail_count_for "$ALPHA")" == "0" ]] || fail "pool prep retention did not clear the down host: $(fail_count_for "$ALPHA")"
  grep -F "A send is planning retention, so cleanup for that destination can be queued again." "$OUT" >/dev/null \
    || fail "scheduled retention did not say it was retrying cleanup: $(cat "$OUT")"

  set_mode "$ALPHA" ok
  add_delete_job "retry1" "$ALPHA" "backup/appdata@zfs-send-${SCHEDULE}-old"
  run_one || fail "the replanned delete should run"
  ran="$LAST_RAN"
  [[ "$ran" == "retry1" ]] || fail "expected the replanned delete, ran ${ran}"
  queue_job_exists "retry1" && fail "the replanned delete did not finish"
  assert_ssh_uses_n "replanned destroy"

  mark_transport_failures "$ALPHA" 3
  [[ "$(fail_count_for "$ALPHA")" == "3" ]] || fail "host was not exhausted again"
  set_mode "$ALPHA" fail
  queue_schedule_retention_cleanup "$SCHEDULE" || true
  [[ "$(fail_count_for "$ALPHA")" == "0" ]] || fail "scheduled retention did not clear the host for the next backup"
  set_mode "$ALPHA" ok
  add_delete_job "retry2" "$ALPHA" "backup/appdata@zfs-send-${SCHEDULE}-older"
  run_one || fail "the second scheduled retry should run"
  ran="$LAST_RAN"
  [[ "$ran" == "retry2" ]] || fail "expected the second retry, ran ${ran}"
  queue_job_exists "retry2" && fail "the second retry did not finish"
  assert_ssh_uses_n "second retry"
  echo "PASS: the next scheduled retention pass clears the host and cleanup runs"
}

test_backoff_wait_still_waits
test_exhausted_host_fails_without_replan
test_zero_new_deletes_fail_after_one_cooldown
test_next_scheduled_run_resets_and_retries

rm -rf "$ROOT"
echo "PASS: space approval escape"
