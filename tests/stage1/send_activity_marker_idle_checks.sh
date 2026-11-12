#!/bin/bash
# Send-activity markers hold local cleanup only while a send is actually
# queued or running. An orphaned marker is removed on the 5th consecutive
# snapshot run that finds nothing queued or running, and not before.
# The count is in runs of the snapshot script. It does not use a clock interval.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AUTOSNAPSHOT="${ROOT_DIR}/source/usr/local/sbin/zfs_autosnapshot"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zfsas-send-activity.XXXXXX")"
WORKER_PIDS=()

cleanup() {
  local pid
  set +e
  for pid in "${WORKER_PIDS[@]+"${WORKER_PIDS[@]}"}"; do
    disown "$pid" >/dev/null 2>&1 || true
    kill -KILL "$pid" >/dev/null 2>&1 || true
  done
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

extract_function() {
  local name="$1"
  awk -v name="$name" '
    $0 ~ ("^" name "\\(\\)") { capture = 1 }
    capture { print }
    capture && $0 ~ /^}$/ { exit }
  ' "$AUTOSNAPSHOT"
}

load_helpers() {
  local name fn_file
  fn_file="${TEST_ROOT}/send_activity_fns.sh"
  : > "$fn_file"
  for name in \
    send_activity_pid_state \
    send_activity_pid_alive \
    send_activity_pid_is_send_worker \
    send_activity_marker_basename \
    send_activity_marker_pid \
    send_activity_marker_job_id \
    send_activity_job_field \
    send_activity_job_ids_match \
    send_activity_job_id_is_safe \
    send_activity_claim_pid \
    send_activity_claim_is_live \
    send_activity_queue_has_valid_work \
    send_activity_marker_is_live \
    send_activity_idle_counter_file \
    send_activity_marker_age_seconds \
    send_activity_age_text \
    send_activity_read_idle_count \
    send_activity_write_idle_count \
    send_activity_prune_idle_counters \
    send_activity_remove_orphaned_job_lock \
    reconcile_send_activity_markers \
    any_send_operation_active
  do
    extract_function "$name" >> "$fn_file"
    printf '\n' >> "$fn_file"
  done
  [[ -s "$fn_file" ]] || fail "send activity helpers were not extracted"
  # shellcheck disable=SC1090
  source "$fn_file"
}

log() {
  printf '%s\n' "$*" >> "${SEND_ACTIVITY_LOG:?}"
}

pid_is_gone() {
  local pid="$1"
  local stat_line state
  [[ -d "/proc/${pid}" ]] || return 0
  stat_line="$(cat "/proc/${pid}/stat" 2>/dev/null || true)"
  stat_line="${stat_line##*) }"
  state="${stat_line%% *}"
  [[ -z "$state" || "$state" == "Z" ]]
}

# An unused pid. No process is started, so nothing has to be reaped.
make_dead_pid() {
  local candidate
  for candidate in 2147483646 2147483645 2147483644 2147483000 2147482000; do
    if [[ ! -d "/proc/${candidate}" ]]; then
      LAST_PID="$candidate"
      return 0
    fi
  done
  fail "could not find an unused pid"
}

stop_pid() {
  local pid="$1"
  local _try
  # This bash runs an EXIT trap while it reaps a killed background job.
  # Drop the trap around the signal so the test directory stays put.
  trap - EXIT
  disown "$pid" >/dev/null 2>&1 || true
  kill -KILL "$pid" >/dev/null 2>&1 || true
  for _try in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    pid_is_gone "$pid" && break
    sleep 0.05
  done
  trap cleanup EXIT
  pid_is_gone "$pid" || fail "pid ${pid} was still alive after it was stopped"
}

start_send_worker() {
  local dir="$1"
  local script="${dir}/zfs_autosnapshot_send_worker"
  local _try
  mkdir -p "$dir"
  # Replace this process with sleep, keeping the script name in argv0, so the
  # pid stays one process and is blocked the way a send worker is during retry.
  cat > "$script" <<'EOF'
#!/bin/bash
exec -a "$0" sleep 60
EOF
  chmod +x "$script"
  "$script" &
  LAST_PID=$!
  WORKER_PIDS+=("$LAST_PID")
  for _try in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [[ -r "/proc/${LAST_PID}/cmdline" ]] && break
    sleep 0.05
  done
  [[ -r "/proc/${LAST_PID}/cmdline" ]] || fail "send worker ${LAST_PID} did not show a command line"
}

start_other_process() {
  local _try
  sleep 60 &
  LAST_PID=$!
  WORKER_PIDS+=("$LAST_PID")
  for _try in 1 2 3 4 5 6 7 8 9 10; do
    [[ -d "/proc/${LAST_PID}" ]] && break
    sleep 0.05
  done
}

new_ops() {
  local name="$1"
  OPS_ROOT="${TEST_ROOT}/${name}"
  mkdir -p "${OPS_ROOT}/active" "${OPS_ROOT}/idle" "${OPS_ROOT}/jobs" "${OPS_ROOT}/locks" "${OPS_ROOT}/bin"
  SEND_ACTIVITY_DIR="${OPS_ROOT}/active"
  SEND_ACTIVITY_IDLE_DIR="${OPS_ROOT}/idle"
  SEND_OPS_JOBS_DIR="${OPS_ROOT}/jobs"
  SEND_JOB_LOCKS_DIR="${OPS_ROOT}/locks"
  SEND_ACTIVITY_LOG="${OPS_ROOT}/activity.log"
  : > "$SEND_ACTIVITY_LOG"
}

write_marker() {
  local root="$1"
  local pid="$2"
  local job_id="$3"
  local marker="${root}/active/worker-${pid}-${job_id}.datasets"
  printf '%s\n' "tank/data" > "$marker"
  printf '%s' "$marker"
}

counter_for() {
  local marker="$1"
  printf '%s/%s.runs' "$SEND_ACTIVITY_IDLE_DIR" "$(basename "$marker")"
}

assert_hold() {
  local marker="$1"
  [[ -f "$marker" ]] || fail "expected send marker to remain: $(basename "$marker")"
  any_send_operation_active || fail "a remaining send marker must still hold cleanup"
}

assert_counter() {
  local marker="$1"
  local expected="$2"
  local counter value
  counter="$(counter_for "$marker")"
  [[ -f "$counter" ]] || fail "expected idle counter for $(basename "$marker")"
  value="$(head -n 1 "$counter")"
  [[ "$value" == "$expected" ]] || fail "idle counter for $(basename "$marker") was ${value:-<empty>}, expected ${expected}"
}

assert_no_counter() {
  local marker="$1"
  local counter
  counter="$(counter_for "$marker")"
  [[ ! -e "$counter" ]] || fail "expected idle counter to be gone for $(basename "$marker")"
}

test_threshold_counts_runs() {
  local block
  block="$(awk '
    /^send_activity_pid_state\(\)/ { capture = 1 }
    capture { print }
    capture && /^reconcile_send_activity_markers\(\)/ { seen = 1 }
    seen && /^}$/ { print; exit }
  ' "$AUTOSNAPSHOT")"
  [[ -n "$block" ]] || fail "could not isolate the send-activity reconciliation block"
  if grep -Eiq 'minute|15 min|900' <<< "$block"; then
    fail "send-activity reconciliation must count snapshot runs and must not encode a clock interval"
  fi
  grep -Eq '^SEND_ACTIVITY_ORPHAN_IDLE_RUNS=5$' "$AUTOSNAPSHOT" || fail "orphan idle threshold must be 5 snapshot runs"
  local calls
  calls="$(grep -c '^reconcile_send_activity_markers || true$' "$AUTOSNAPSHOT" || true)"
  [[ "$calls" == "1" ]] || fail "reconcile_send_activity_markers must run once per snapshot run (found ${calls})"
  awk '
    /^reconcile_send_activity_markers \|\| true$/ { called = NR }
    /^if any_send_operation_active; then$/ { gate = NR }
    END {
      if (!(called > 0 && gate > called)) exit 1
    }
  ' "$AUTOSNAPSHOT" || fail "marker reconciliation must run before the cleanup gate"
  echo "PASS: orphan threshold is 5 snapshot runs"
}

test_orphaned_marker_clears_on_fifth_idle_run() {
  local root job_id pid marker lock_dir run
  new_ops orphan
  root="$OPS_ROOT"
  job_id="send-child-send-c4e2f1a7b305-manual-1793916608-0"
  make_dead_pid
  pid="$LAST_PID"
  marker="$(write_marker "$root" "$pid" "$job_id")"
  lock_dir="${SEND_JOB_LOCKS_DIR}/job-${job_id}.lockdir"
  mkdir -p "$lock_dir"
  printf '%s\n' "$pid" > "${lock_dir}/pid"
  cat > "${SEND_OPS_JOBS_DIR}/stale.job" <<EOF
JOB_ID="${job_id}"
STATE="running"
WORKER_PID="${pid}"
EOF
  if send_activity_marker_is_live "$marker"; then
    fail "a running job whose worker pid is dead must not count as valid send activity"
  fi
  rm -f "${SEND_OPS_JOBS_DIR}/stale.job"

  for run in 1 2 3 4; do
    if [[ -d "/proc/${pid}" ]]; then
      fail "dead worker pid ${pid} was reused before idle run ${run}"
    fi
    reconcile_send_activity_markers
    assert_hold "$marker"
    assert_counter "$marker" "$run"
    [[ -d "$lock_dir" ]] || fail "job lock was removed on idle run ${run}"
    if grep -Fq "Removed orphaned send activity marker" "$SEND_ACTIVITY_LOG"; then
      fail "orphaned marker was removed on idle run ${run}"
    fi
  done

  reconcile_send_activity_markers
  [[ ! -e "$marker" ]] || fail "orphaned marker was still present after the fifth idle run"
  [[ ! -d "$lock_dir" ]] || fail "orphaned job lock was still present after the fifth idle run"
  assert_no_counter "$marker"
  any_send_operation_active && fail "cleanup must not stay held after the orphaned marker is removed"
  grep -Fq "Removed orphaned send activity marker $(basename "$marker")" "$SEND_ACTIVITY_LOG" || fail "removal log did not name the marker"
  grep -Fq "pid=${pid}" "$SEND_ACTIVITY_LOG" || fail "removal log did not include the worker pid"
  grep -Eq 'age=([0-9]+s|unknown)' "$SEND_ACTIVITY_LOG" || fail "removal log did not include the marker age"
  grep -Fq "Removed orphaned send job lock $(basename "$lock_dir")" "$SEND_ACTIVITY_LOG" || fail "removal log did not include the orphaned job lock"
  echo "PASS: orphaned marker clears on the fifth idle run"
}

test_live_send_worker_holds_and_resets_counter() {
  local root job_id pid marker
  new_ops live
  root="$OPS_ROOT"
  job_id="send-live-worker"
  start_send_worker "${root}/bin"
  pid="$LAST_PID"
  marker="$(write_marker "$root" "$pid" "$job_id")"
  printf '%s\n' "4" > "$(counter_for "$marker")"

  reconcile_send_activity_markers
  assert_hold "$marker"
  assert_no_counter "$marker"
  kill -0 "$pid" || fail "a live send worker must not be signaled"
  if grep -Fq "Removed orphaned send activity marker" "$SEND_ACTIVITY_LOG"; then
    fail "a live send worker marker was removed"
  fi

  # The worker is blocked in sleep, the same shape as a send-step retry wait.
  # Dropping that activity starts a new idle streak at 1 instead of continuing 4.
  stop_pid "$pid"
  reconcile_send_activity_markers
  assert_hold "$marker"
  assert_counter "$marker" "1"
  echo "PASS: live send worker holds cleanup and resets the idle counter"
}

test_counter_resets_when_activity_resumes() {
  local root job_id pid marker run
  new_ops resume
  root="$OPS_ROOT"
  job_id="send-resume-job"
  make_dead_pid
  pid="$LAST_PID"
  marker="$(write_marker "$root" "$pid" "$job_id")"

  for run in 1 2 3; do
    reconcile_send_activity_markers
    assert_counter "$marker" "$run"
  done

  cat > "${SEND_OPS_JOBS_DIR}/resume.job" <<EOF
JOB_ID="${job_id}"
STATE="queued"
WORKER_PID=""
EOF
  reconcile_send_activity_markers
  assert_hold "$marker"
  assert_no_counter "$marker"
  if grep -Fq "Removed orphaned send activity marker" "$SEND_ACTIVITY_LOG"; then
    fail "queued send work must keep the marker"
  fi

  rm -f "${SEND_OPS_JOBS_DIR}/resume.job"
  reconcile_send_activity_markers
  assert_hold "$marker"
  assert_counter "$marker" "1"
  echo "PASS: idle counter resets when queued send activity resumes"
}

test_live_claim_resets_counter() {
  local root job_id dead worker marker lock_dir
  new_ops claim
  root="$OPS_ROOT"
  job_id="send-live-claim"
  make_dead_pid
  dead="$LAST_PID"
  start_send_worker "${root}/bin"
  worker="$LAST_PID"
  marker="$(write_marker "$root" "$dead" "$job_id")"
  lock_dir="${SEND_JOB_LOCKS_DIR}/job-${job_id}.lockdir"
  mkdir -p "$lock_dir"
  printf '%s\n' "$worker" > "${lock_dir}/pid"
  printf '%s\n' "3" > "$(counter_for "$marker")"

  reconcile_send_activity_markers
  assert_hold "$marker"
  assert_no_counter "$marker"
  [[ -d "$lock_dir" ]] || fail "a live send claim must not be removed"
  kill -0 "$worker" || fail "a live claim owner must not be signaled"
  echo "PASS: a live send claim holds cleanup and resets the idle counter"
}

test_reused_pid_and_live_lock_owner() {
  local root job_id dead other marker lock_dir run
  new_ops reused
  root="$OPS_ROOT"
  job_id="send-reused-pid"
  make_dead_pid
  dead="$LAST_PID"
  start_other_process
  other="$LAST_PID"
  marker="$(write_marker "$root" "$other" "$job_id")"
  lock_dir="${SEND_JOB_LOCKS_DIR}/job-${job_id}.lockdir"
  mkdir -p "$lock_dir"
  printf '%s\n' "$other" > "${lock_dir}/pid"

  reconcile_send_activity_markers
  assert_counter "$marker" "1"
  kill -0 "$other" || fail "a non-worker process was signaled"

  # Switch the marker back to a dead worker pid, but leave the lock owned by
  # the unrelated live process. The marker can be cleared. The lock stays.
  rm -f "$marker" "$(counter_for "$marker")"
  marker="$(write_marker "$root" "$dead" "$job_id")"
  for run in 1 2 3 4 5; do
    reconcile_send_activity_markers
  done
  [[ ! -e "$marker" ]] || fail "marker with a dead worker was not cleared"
  [[ -d "$lock_dir" ]] || fail "job lock whose owner is still running was removed"
  kill -0 "$other" || fail "lock owner was signaled"
  grep -Fq "Left send job lock $(basename "$lock_dir") in place" "$SEND_ACTIVITY_LOG" || fail "a live lock owner was not reported"
  echo "PASS: a live non-worker pid is idle, and a live lock owner is left in place"
}

test_counter_removed_when_marker_is_gone() {
  local root marker counter
  new_ops gone
  root="$OPS_ROOT"
  marker="${SEND_ACTIVITY_DIR}/worker-404-missing-job.datasets"
  counter="$(counter_for "$marker")"
  printf '%s\n' "2" > "$counter"
  [[ ! -e "$marker" ]] || fail "setup marker should not exist"
  reconcile_send_activity_markers
  [[ ! -e "$counter" ]] || fail "idle counter remained after its marker was gone"
  echo "PASS: idle counter is removed when the marker is gone"
}

load_helpers
test_threshold_counts_runs
test_orphaned_marker_clears_on_fifth_idle_run
test_live_send_worker_holds_and_resets_counter
test_counter_resets_when_activity_resumes
test_live_claim_resets_counter
test_reused_pid_and_live_lock_owner
test_counter_removed_when_marker_is_gone
echo "All send-activity marker idle checks passed."
