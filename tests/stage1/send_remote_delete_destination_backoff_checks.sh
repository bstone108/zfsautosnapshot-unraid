#!/bin/bash
# Remote retention deletes retry per destination host.
# A connection failure waits 30 minutes before that host is tried again.
# Three failures drop only that host's pending cleanup jobs.
# A success clears the count. Sends and other destinations are not held.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${ROOT_DIR}/source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/ops-queue-lib.sh"
DELETE_WORKER="${ROOT_DIR}/source/usr/local/sbin/zfs_autosnapshot_delete_worker"
SEND_WORKER="${ROOT_DIR}/source/usr/local/sbin/zfs_autosnapshot_send_worker"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

SCHEDULE="sched0001dead"
ALPHA="alpha.example"
BETA="beta.example"
MOCK_NOW=1700000000
OUT=""
SSH_LOG=""
SSH_MODE=""
SLEEP_LOG=""

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

# The library assigns its default paths while it is sourced.
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
mkdir -p "$OPS_JOBS_DIR" "$OPS_STATUS_DIR" "$JOB_LOCKS_DIR" "$PERSISTED_QUEUE_DIR"

delete_queue_now_epoch_hook() { printf '%s\n' "$MOCK_NOW"; }
delete_retry_sleep_hook() { printf '%s\n' "$1" >> "$SLEEP_LOG"; }
checkpoint_basename_is_latest_common_for_schedule() { return 1; }
snapshot_delete_conflicts_with_send_jobs() { return 1; }
start_delete_queue_daemon() { return 0; }

log() {
  printf '%s %s\n' "TEST" "$*" >> "${OUT:?}"
}

SEND_SSH_HOST="$ALPHA"
SEND_SSH_PORT="22"
SEND_SSH_USER="root"
SEND_SSH_KEY_PATH="/root/.ssh/id_ed25519"
SEND_SNAPSHOT_PREFIX="zfs-send-"
SCHEDULE_JOB_IDS=("$SCHEDULE")
SCHEDULE_SOURCE_ROOT["$SCHEDULE"]="cache/appdata"
SCHEDULE_DEST_ROOT["$SCHEDULE"]="backup/appdata"
SCHEDULE_TRANSPORT["$SCHEDULE"]="ssh"
SCHEDULE_PREFIX["$SCHEDULE"]="zfs-send-${SCHEDULE}-"
SCHEDULE_INCLUDE_CHILDREN["$SCHEDULE"]="0"

cat > "${ROOT}/bin/ssh" <<'EOF'
#!/bin/bash
printf 'SSH %s\n' "$*" >> "${SSH_LOG:?}"
# OpenSSH reads the caller's stdin unless -n is set. Drain it so a while-read
# loop cannot hide a missing -n. A tty is left alone so a local run does not block.
if [[ " $* " != *" -n "* ]] && [[ ! -t 0 ]]; then
  cat >/dev/null || true
fi
remote="${*: -1}"
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
  reset)
    echo "Connection reset by peer" >&2
    exit 1
    ;;
  timeout)
    echo "ssh: connect to host ${host} port 22: Connection timed out" >&2
    exit 255
    ;;
  busy)
    echo "cannot destroy snapshot: dataset is busy" >&2
    exit 1
    ;;
  absent)
    echo "cannot open '${remote##* }': dataset does not exist" >&2
    exit 1
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
echo "local zfs must not run for these remote deletes: $*" >&2
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
  rm -f "$(delete_dest_transport_state_path)" "${DELETE_QUEUE_STATE_FILE}"
}

begin_case() {
  local name="$1"
  OUT="${ROOT}/${name}.out"
  SSH_LOG="${ROOT}/${name}.ssh"
  SSH_MODE="${ROOT}/${name}.mode"
  SLEEP_LOG="${ROOT}/${name}.sleep"
  : > "$OUT"
  : > "$SSH_LOG"
  : > "$SSH_MODE"
  : > "$SLEEP_LOG"
  export SSH_LOG SSH_MODE
  reset_queue
  MOCK_NOW=1700000000
}

set_mode() {
  local host="$1"
  local mode="$2"
  local tmp="${SSH_MODE}.tmp"
  : > "$tmp"
  if [[ -f "$SSH_MODE" ]]; then
    while IFS=$'\t' read -r seen_host seen_mode; do
      [[ -n "$seen_host" ]] || continue
      if [[ "$seen_host" != "$host" ]]; then
        printf '%s\t%s\n' "$seen_host" "$seen_mode" >> "$tmp"
      fi
    done < "$SSH_MODE"
  fi
  printf '%s\t%s\n' "$host" "$mode" >> "$tmp"
  mv "$tmp" "$SSH_MODE"
}

add_delete_job() {
  local job_id="$1"
  local host="$2"
  local snap="$3"
  local state="${4:-queued}"
  local retry_at="${5:-0}"
  local -A job=()

  job[JOB_ID]="$job_id"
  job[STATE]="$state"
  job[RETRY_AT]="$retry_at"
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

assert_destroy_uses_ssh_n() {
  local label="$1"
  local line
  local saw=0
  while IFS= read -r line; do
    [[ "$line" == *"zfs destroy"* ]] || continue
    saw=1
    [[ "$line" == *" -n "* ]] || fail "${label}: destroy ssh dropped -n: ${line}"
  done < "$SSH_LOG"
  (( saw == 1 )) || fail "${label}: no destroy ssh command was recorded"
}

test_timeout_value() {
  local command="" query="" receive=""
  begin_case "timeout"
  [[ "$(delete_remote_destroy_connect_timeout_seconds)" == "300" ]] || fail "default destroy connect timeout must be 300 seconds"
  [[ "$DELETE_DESTINATION_TRANSPORT_BACKOFF_SECONDS" == "1800" ]] || fail "destination backoff must be 1800 seconds"
  [[ "$DELETE_DESTINATION_TRANSPORT_MAX_ATTEMPTS" == "3" ]] || fail "destination attempts must be 3"
  DELETE_REMOTE_DESTROY_CONNECT_TIMEOUT_SECONDS=600
  [[ "$(delete_remote_destroy_connect_timeout_seconds)" == "600" ]] || fail "a connect timeout already above 300 seconds must be left alone"
  DELETE_REMOTE_DESTROY_CONNECT_TIMEOUT_SECONDS=30
  [[ "$(delete_remote_destroy_connect_timeout_seconds)" == "300" ]] || fail "a connect timeout under 300 seconds must be raised to 300"
  unset DELETE_REMOTE_DESTROY_CONNECT_TIMEOUT_SECONDS

  build_ssh_zfs_command "zfs destroy -- backup/appdata@snap" command 0 "$(delete_remote_destroy_connect_timeout_seconds)" \
    || fail "destroy ssh command should build"
  [[ "$command" == *"ConnectTimeout=300"* ]] || fail "destroy ssh must wait 300 seconds to connect: ${command}"
  [[ "$command" == *" -n "* ]] || fail "destroy ssh must keep -n: ${command}"
  [[ "$command" != *" timeout "* ]] || fail "destroy ssh must not use a shorter timeout wrapper: ${command}"

  build_ssh_zfs_command "zfs list -H -o name -- backup/appdata" query \
    || fail "list ssh command should build"
  [[ "$query" == *" -n "* ]] || fail "non-streaming list ssh must keep -n"
  [[ "$query" != *"ConnectTimeout"* ]] || fail "snapshot list ssh must keep its existing timeout: ${query}"

  build_ssh_receive_command "backup/appdata" receive || fail "receive ssh command should build"
  [[ "$receive" != *" -n "* ]] || fail "receive ssh must keep stdin"
  [[ "$receive" != *"ConnectTimeout"* ]] || fail "receive ssh must keep its existing timeout: ${receive}"

  if grep -E 'sleep[[:space:]]+.*BACKOFF|sleep[[:space:]]+1800' "$DELETE_WORKER"; then
    fail "the 30 minute wait must not be a sleep in the delete worker"
  fi
  if grep -F 'delete_dest_transport_locked_update' "$SEND_WORKER" || grep -F 'delete_destination_note_transport_failure' "$SEND_WORKER"; then
    fail "the send worker must not apply delete-destination backoff"
  fi
  echo "PASS: remote destroy connect timeout is 300 seconds and sends are not wrapped"
}

test_classification() {
  ssh_failure_is_transport_class 255 "ssh: connect to host alpha.example port 22: Connection refused" \
    || fail "ssh exit 255 must be a transport failure"
  ssh_failure_is_transport_class 1 "Connection reset by peer" || fail "connection reset must be a transport failure"
  ssh_failure_is_transport_class 1 "Broken pipe" || fail "broken pipe must be a transport failure"
  ssh_failure_is_transport_class 255 "Connection timed out" || fail "timeout must be a transport failure"
  if ssh_failure_is_transport_class 1 "cannot destroy snapshot: dataset is busy"; then
    fail "snapshot busy must stay a per-item failure"
  fi
  if ssh_failure_is_transport_class 1 "cannot open 'pool/a@snap': dataset does not exist"; then
    fail "dataset does not exist must stay a per-item result"
  fi
  echo "PASS: transport failures are connection errors, not busy or missing datasets"
}

test_backoff_and_other_destination() {
  local first="" second="" early=""
  begin_case "backoff"
  set_mode "$ALPHA" fail
  set_mode "$BETA" ok
  add_delete_job "a1" "$ALPHA" "backup/appdata@zfs-send-${SCHEDULE}-old-a1"
  add_delete_job "a2" "$ALPHA" "backup/appdata@zfs-send-${SCHEDULE}-old-a2"
  add_delete_job "b1" "$BETA" "backup/other@zfs-send-${SCHEDULE}-old-b1"

  run_one || fail "first ready delete should run"
  first="$LAST_RAN"
  [[ "$first" == "a1" ]] || fail "expected alpha job first, ran ${first}"
  [[ "$(fail_count_for "$ALPHA")" == "1" ]] || fail "one connection failure should count once for the host, saw $(fail_count_for "$ALPHA")"
  [[ "${QUEUE_STATE[a1]}" == "retry_wait" ]] || fail "failed alpha job should wait, state ${QUEUE_STATE[a1]:-missing}"
  [[ "${QUEUE_STATE[a2]}" == "retry_wait" ]] || fail "other alpha job should wait with the destination, state ${QUEUE_STATE[a2]:-missing}"
  [[ "${QUEUE_RETRY_AT[a1]}" == "$((MOCK_NOW + 1800))" ]] || fail "alpha retry time is ${QUEUE_RETRY_AT[a1]:-missing}, want $((MOCK_NOW + 1800))"
  [[ "${QUEUE_RETRY_AT[a2]}" == "$((MOCK_NOW + 1800))" ]] || fail "second alpha job was not deferred with the destination"
  [[ "${QUEUE_STATE[b1]}" == "queued" ]] || fail "beta was held by alpha's failure"
  grep -F "Waiting 1800s before retrying that destination" "$OUT" >/dev/null || fail "backoff was not logged: $(cat "$OUT")"
  assert_destroy_uses_ssh_n "backoff"
  grep -F "ConnectTimeout=300" "$SSH_LOG" >/dev/null || fail "running destroy did not use ConnectTimeout=300: $(cat "$SSH_LOG")"
  if grep -F "$BETA" "$SSH_LOG"; then
    fail "beta was contacted during alpha's failure: $(cat "$SSH_LOG")"
  fi
  if [[ -s "$SLEEP_LOG" ]]; then
    fail "transport failure used the per-item retry sleep: $(cat "$SLEEP_LOG")"
  fi

  run_one || fail "beta should run while alpha is waiting"
  second="$LAST_RAN"
  [[ "$second" == "b1" ]] || fail "expected beta while alpha waits, ran ${second}"
  queue_job_exists "b1" && fail "beta delete did not finish"
  [[ "${QUEUE_STATE[a1]}" == "retry_wait" ]] || fail "alpha changed while beta ran"

  MOCK_NOW=$((MOCK_NOW + 1799))
  if next_ready_job_id early; then
    fail "alpha became ready 1 second before the 30 minute wait: ${early}"
  fi
  MOCK_NOW=$((MOCK_NOW + 1))
  next_ready_job_id early || fail "alpha should be ready at 30 minutes"
  [[ "$early" == "a1" || "$early" == "a2" ]] || fail "ready job after the wait was ${early}"
  echo "PASS: one destination waits 30 minutes and the other destination still runs"
}

test_three_failures_purge_one_destination() {
  local held_retry="" ran=""
  begin_case "purge"
  set_mode "$ALPHA" fail
  set_mode "$BETA" ok
  held_retry=$((MOCK_NOW + 999999))
  add_delete_job "a1" "$ALPHA" "backup/appdata@zfs-send-${SCHEDULE}-old-a1"
  add_delete_job "a2" "$ALPHA" "backup/appdata@zfs-send-${SCHEDULE}-old-a2"
  add_delete_job "bhold" "$BETA" "backup/other@zfs-send-${SCHEDULE}-old-b" "retry_wait" "$held_retry"

  run_one || fail "attempt 1 should run"
  ran="$LAST_RAN"
  [[ "$ran" == a* ]] || fail "attempt 1 ran ${ran}"
  MOCK_NOW=$((MOCK_NOW + 1800))
  run_one || fail "attempt 2 should run"
  ran="$LAST_RAN"
  [[ "$ran" == a* ]] || fail "attempt 2 ran ${ran}"
  [[ "$(fail_count_for "$ALPHA")" == "2" ]] || fail "two failures should not purge, count $(fail_count_for "$ALPHA")"
  queue_job_exists "a1" || fail "alpha jobs were dropped before the third failure"
  queue_job_exists "a2" || fail "alpha jobs were dropped before the third failure"
  MOCK_NOW=$((MOCK_NOW + 1800))
  run_one || fail "attempt 3 should run"
  ran="$LAST_RAN"
  [[ "$ran" == a* ]] || fail "attempt 3 ran ${ran}"

  queue_job_exists "a1" && fail "alpha job a1 remained after the destination was marked down"
  queue_job_exists "a2" && fail "alpha job a2 remained after the destination was marked down"
  queue_job_exists "bhold" || fail "beta job was purged with alpha"
  [[ "${QUEUE_STATE[bhold]}" == "retry_wait" ]] || fail "beta state changed: ${QUEUE_STATE[bhold]:-missing}"
  [[ "${QUEUE_RETRY_AT[bhold]}" == "$held_retry" ]] || fail "beta retry time changed: ${QUEUE_RETRY_AT[bhold]:-missing}"
  [[ "$(fail_count_for "$ALPHA")" == "3" ]] || fail "down host count is $(fail_count_for "$ALPHA")"
  [[ "$(fail_count_for "$BETA")" == "0" ]] || fail "beta gained a failure count"
  grep -F "Destination host ${ALPHA} is down after 3 connection failures" "$OUT" >/dev/null || fail "down host was not logged: $(cat "$OUT")"
  grep -F "Dropped 2 pending cleanup/delete job(s) for that destination" "$OUT" >/dev/null \
    || fail "purge did not say how many alpha jobs were dropped: $(cat "$OUT")"
  grep -F "next time a send to that destination runs retention" "$OUT" >/dev/null || fail "purge did not say why the jobs were dropped: $(cat "$OUT")"
  assert_destroy_uses_ssh_n "purge"
  if grep -F "$BETA" "$SSH_LOG"; then
    fail "beta was contacted while alpha was failing: $(cat "$SSH_LOG")"
  fi

  add_delete_job "a3" "$ALPHA" "backup/appdata@zfs-send-${SCHEDULE}-old-a3"
  queue_job_exists "a3" && fail "a new alpha delete was queued while the host is down"
  grep -F "is not being retried" "$OUT" >/dev/null || fail "dropping a later alpha job was not logged: $(cat "$OUT")"

  delete_destination_replan_if_exhausted "$ALPHA"
  [[ "$(fail_count_for "$ALPHA")" == "0" ]] || fail "retention replan did not clear the down host"
  set_mode "$ALPHA" ok
  add_delete_job "a4" "$ALPHA" "backup/appdata@zfs-send-${SCHEDULE}-old-a4"
  queue_job_exists "a4" || fail "retention replan did not allow a new alpha delete"
  run_one || fail "replanned alpha delete should run"
  ran="$LAST_RAN"
  [[ "$ran" == "a4" ]] || fail "replanned job did not run, ran ${ran}"
  queue_job_exists "a4" && fail "replanned alpha delete did not finish"
  queue_job_exists "bhold" || fail "beta job disappeared after alpha recovered"
  echo "PASS: three connection failures drop only that destination's delete jobs"
}

test_success_resets_counter() {
  local ran=""
  begin_case "reset"
  set_mode "$ALPHA" fail
  add_delete_job "a1" "$ALPHA" "backup/appdata@zfs-send-${SCHEDULE}-old-a1"
  add_delete_job "a2" "$ALPHA" "backup/appdata@zfs-send-${SCHEDULE}-old-a2"
  run_one >/dev/null || fail "first failure should run"
  [[ "$(fail_count_for "$ALPHA")" == "1" ]] || fail "count after one failure is $(fail_count_for "$ALPHA")"

  set_mode "$ALPHA" ok
  MOCK_NOW=$((MOCK_NOW + 1800))
  run_one || fail "the next alpha delete should run after the wait"
  ran="$LAST_RAN"
  queue_job_exists "$ran" && fail "successful delete ${ran} stayed queued"
  [[ "$(fail_count_for "$ALPHA")" == "0" ]] || fail "success did not reset the failure count"
  grep -F "connection failure count was reset" "$OUT" >/dev/null || fail "reset was not logged: $(cat "$OUT")"

  set_mode "$ALPHA" reset
  run_one || fail "a later connection reset should run"
  ran="$LAST_RAN"
  [[ "$(fail_count_for "$ALPHA")" == "1" ]] || fail "failure after a success counted as $(fail_count_for "$ALPHA"), want 1"
  queue_job_exists "$ran" || fail "a single new connection failure purged the job"
  [[ "${QUEUE_RETRY_AT[$ran]}" == "$((MOCK_NOW + 1800))" ]] || fail "post-reset failure did not wait 30 minutes"
  if grep -F "Dropped " "$OUT"; then
    fail "a reset counter was purged: $(cat "$OUT")"
  fi
  assert_destroy_uses_ssh_n "reset"
  echo "PASS: a successful delete resets the destination failure count"
}

test_non_transport_stays_per_item() {
  local destroys=""
  begin_case "busy"
  set_mode "$ALPHA" busy
  set_mode "$BETA" ok
  add_delete_job "a1" "$ALPHA" "backup/appdata@zfs-send-${SCHEDULE}-old-a1"
  add_delete_job "a2" "$ALPHA" "backup/appdata@zfs-send-${SCHEDULE}-old-a2"
  add_delete_job "b1" "$BETA" "backup/other@zfs-send-${SCHEDULE}-old-b1"

  run_one >/dev/null || fail "busy delete should run"
  queue_job_exists "a1" && fail "busy snapshot was left queued"
  [[ "${QUEUE_STATE[a2]}" == "queued" ]] || fail "sibling alpha job was deferred for a busy snapshot: ${QUEUE_STATE[a2]:-missing}"
  [[ "${QUEUE_RETRY_AT[a2]}" == "0" ]] || fail "sibling alpha job got a destination wait"
  [[ "$(fail_count_for "$ALPHA")" == "0" ]] || fail "busy snapshot counted as a connection failure"
  destroys="$(grep -c "zfs destroy -- backup/appdata@zfs-send-${SCHEDULE}-old-a1" "$SSH_LOG" || true)"
  [[ "$destroys" == "3" ]] || fail "busy snapshot should keep 3 per-item attempts, saw ${destroys}"
  [[ "$(grep -c '^1$' "$SLEEP_LOG" || true)" == "1" ]] || fail "per-item retry delay was not kept"
  [[ "$(grep -c '^2$' "$SLEEP_LOG" || true)" == "1" ]] || fail "second per-item retry delay was not kept"
  if grep -F "Waiting 1800s" "$OUT"; then
    fail "busy snapshot started the destination backoff: $(cat "$OUT")"
  fi

  set_mode "$ALPHA" ok
  run_one >/dev/null || fail "sibling alpha delete should still run"
  queue_job_exists "a2" && fail "sibling alpha delete did not finish"
  run_one >/dev/null || fail "beta delete should still run"
  queue_job_exists "b1" && fail "beta delete did not finish"
  assert_destroy_uses_ssh_n "busy"
  echo "PASS: snapshot busy stays a per-item failure"
}

test_absent_is_not_a_connection_failure() {
  begin_case "absent"
  set_mode "$ALPHA" absent
  set_mode "$BETA" ok
  add_delete_job "a1" "$ALPHA" "backup/appdata@zfs-send-${SCHEDULE}-missing"
  add_delete_job "b1" "$BETA" "backup/other@zfs-send-${SCHEDULE}-old-b1"
  run_one >/dev/null || fail "absent delete should run"
  queue_job_exists "a1" && fail "confirmed-absent delete stayed queued"
  grep -F "Delete already done" "$OUT" >/dev/null || fail "absent snapshot was not treated as already done: $(cat "$OUT")"
  [[ "$(grep -c "zfs destroy -- backup/appdata@zfs-send-${SCHEDULE}-missing" "$SSH_LOG" || true)" == "1" ]] \
    || fail "absent destroy was retried: $(cat "$SSH_LOG")"
  [[ "$(fail_count_for "$ALPHA")" == "0" ]] || fail "absent snapshot counted as a connection failure"
  [[ "${QUEUE_STATE[b1]}" == "queued" ]] || fail "beta changed when alpha was already gone"
  assert_destroy_uses_ssh_n "absent"
  echo "PASS: a missing dataset stays per item and does not back off the destination"
}

test_sends_are_not_blocked() {
  local send_path="" ready="" claimed=""
  local -A send_job=()
  begin_case "sends"
  set_mode "$ALPHA" fail
  set_mode "$BETA" ok
  add_delete_job "a1" "$ALPHA" "backup/appdata@zfs-send-${SCHEDULE}-old-a1"
  add_delete_job "b1" "$BETA" "backup/other@zfs-send-${SCHEDULE}-old-b1"
  run_one >/dev/null || fail "alpha failure should run"
  [[ "${QUEUE_STATE[a1]}" == "retry_wait" ]] || fail "alpha did not enter the 30 minute wait"

  send_job[JOB_TYPE]="send"
  send_job[JOB_ID]="send-alpha-1"
  send_job[STATE]="queued"
  send_job[RETRY_AT]="0"
  send_job[QUEUE_SORT]="1"
  send_job[JOB_ACTION]="send_member"
  send_job[SEND_TRANSPORT]="ssh"
  send_job[DESTINATION_ROOT]="backup/appdata"
  send_path="${OPS_JOBS_DIR}/0000000001-send-alpha-1.job"
  job_write "$send_path" send_job || fail "send job file was not written"
  ready="$(list_ready_send_job_paths "$MOCK_NOW" any 10)"
  [[ "$ready" == *"$send_path"* ]] || fail "send to the backed-off host was not ready: ${ready:-<none>}"
  claim_send_job_path_for_launch "$send_path" claimed || fail "send queue would not launch a send to the backed-off host"
  [[ "$claimed" == "send-alpha-1" ]] || fail "claimed send id was ${claimed}"
  release_job_claim "$claimed" || fail "could not release the send claim"
  grep -F 'RETRY_AT="0"' "$send_path" >/dev/null || fail "send job picked up the delete backoff: $(cat "$send_path")"

  SEND_SSH_HOST="$BETA"
  run_zfs_for_transport ssh "list backup/other" -- list -H -o name -- backup/other >/dev/null \
    || fail "a send-path ssh command failed while deletes were waiting"
  SEND_SSH_HOST="$ALPHA"
  grep -F "zfs list -H -o name -- backup/other" "$SSH_LOG" >/dev/null || fail "send-path ssh did not run: $(cat "$SSH_LOG")"
  if grep -F "ConnectTimeout" "$SSH_LOG" | grep -F "zfs list" >/dev/null; then
    fail "send-path list picked up the destroy connect timeout: $(cat "$SSH_LOG")"
  fi

  run_one >/dev/null || fail "beta delete should run during alpha's wait and while a send is queued"
  queue_job_exists "b1" && fail "beta delete was held behind alpha and the send"
  [[ "${QUEUE_STATE[a1]}" == "retry_wait" ]] || fail "running beta and a send cleared alpha's wait"
  grep -F 'RETRY_AT="0"' "$send_path" >/dev/null || fail "send job retry time changed after more delete work"
  if [[ -s "$SLEEP_LOG" ]]; then
    fail "delete backoff slept inside the worker: $(cat "$SLEEP_LOG")"
  fi
  echo "PASS: delete backoff does not block sends or other destinations"
}

test_timeout_value
test_classification
test_backoff_and_other_destination
test_three_failures_purge_one_destination
test_success_resets_counter
test_non_transport_stays_per_item
test_absent_is_not_a_connection_failure
test_sends_are_not_blocked

rm -rf "$ROOT"
echo "PASS: remote delete destination backoff"
