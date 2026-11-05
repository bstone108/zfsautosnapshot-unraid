#!/bin/bash
# Destination retention and the confirmed-absent check must use the destination
# host. A checkpoint that exists only on the SSH receiver is listed and destroyed
# there. A failed remote listing does not delete or reseed. A local destination
# still uses the local zfs binary.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${ROOT_DIR}/source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/ops-queue-lib.sh"
DELETE_WORKER="${ROOT_DIR}/source/usr/local/sbin/zfs_autosnapshot_delete_worker"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

PARENT="storage/Backups/susanoo-cache/appdata"
SOURCE="cache/appdata"
OLD="zfs-send-ef8948aa4533-2026-10-03_00-00-50"
NEW="zfs-send-ef8948aa4533-2026-11-03_00-00-50"
SCHEDULE="ef8948aa4533"
OLD_SNAP="${PARENT}@${OLD}"
NEW_SNAP="${PARENT}@${NEW}"

export ZFSAS_OPS_LIB="$LIB"
export ZFSAS_DELETE_WORKER_AS_LIBRARY=1
# shellcheck source=/dev/null
source "$DELETE_WORKER"

start_delete_queue_daemon() { return 0; }
delete_retry_sleep_hook() { :; }

reset_queue_memory() {
  QUEUE_IDS=()
  QUEUE_HEAD_INDEX=0
  QUEUE_MAX_INDEX=-1
  QUEUE_ACTIVE_COUNT=0
  QUEUE_RUNNING_COUNT=0
  QUEUE_RETRY_WAIT_COUNT=0
  QUEUE_QUEUED_COUNT=0
  QUEUE_INDEX_BY_ID=()
  QUEUE_STATE=()
  QUEUE_SNAPSHOT=()
  QUEUE_SEND_TRANSPORT=()
  QUEUE_DELETE_SCOPE=()
  QUEUE_SEND_PROTECTED=()
  QUEUE_SEND_SCHEDULE_JOB_ID=()
  CURRENT_JOB_ID=""
}

prepare_tree() {
  local root="$1"
  mkdir -p "${root}/bin" "${root}/ops/jobs" "${root}/ops/status" "${root}/run/delete-worker" "${root}/persist" "${root}/config" "${root}/state"
  export ZFS_LOG="${root}/zfs.log"
  export SSH_LOG="${root}/ssh.log"
  export SLEEP_LOG="${root}/sleep.log"
  export LOCAL_SNAPS="${root}/state/local.tsv"
  export REMOTE_SNAPS="${root}/state/remote.tsv"
  export STUB_MODE="${root}/mode"
  : > "$ZFS_LOG"
  : > "$SSH_LOG"
  : > "$SLEEP_LOG"
  : > "$LOCAL_SNAPS"
  : > "$REMOTE_SNAPS"
  export PATH="${root}/bin:${PATH}"
  CONFIG_DIR="${root}/config"
  SEND_CONFIG_FILE="${root}/config/zfs_send.conf"
  OPS_ROOT="${root}/ops"
  OPS_JOBS_DIR="${root}/ops/jobs"
  OPS_STATUS_DIR="${root}/ops/status"
  DELETE_QUEUE_STATE_FILE="${root}/ops/status/delete-queue.state"
  DELETE_QUEUE_INBOX_FILE="${root}/ops/delete-queue.inbox"
  DELETE_QUEUE_INBOX_LOCK_FILE="${root}/ops/delete-queue.inbox.lock"
  PERSISTED_QUEUE_DIR="${root}/persist"
  PERSISTED_DELETE_QUEUE_FILE="${root}/persist/delete-queue.persist"
  RUNTIME_DIR="${root}/run"
  LOG_FILE="${root}/send.log"
  DELETE_WORKER_RUNTIME_DIR="${root}/run/delete-worker"
  DELETE_QUEUE_PID_FILE="${root}/run/delete-worker/daemon.pid"
  DELETE_QUEUE_LOCK_DIR="${root}/run/delete-worker/daemon.lockdir"
  : > "$LOG_FILE"
  rm -f "$DELETE_QUEUE_INBOX_FILE"
  reset_queue_memory
  SEND_SSH_HOST="kiki.example"
  SEND_SSH_PORT="22"
  SEND_SSH_USER="root"
  SEND_SSH_KEY_PATH="/root/.ssh/id_ed25519"
  SEND_SNAPSHOT_PREFIX="zfs-send-"
  SEND_KEEP_ALL_FOR_DAYS=0
  SEND_KEEP_DAILY_UNTIL_DAYS=0
  SEND_KEEP_WEEKLY_UNTIL_DAYS=0
  SEND_REMOTE_RETRIES_ENABLED=0
  SEND_REMOTE_RETRY_DEPTH=0
  SEND_REMOTE_STEP_EXHAUSTED=0
  SEND_AUTO_RESEED=1
  SCHEDULE_JOB_IDS=("$SCHEDULE")
  SCHEDULE_SOURCE_ROOT["$SCHEDULE"]="$SOURCE"
  SCHEDULE_DEST_ROOT["$SCHEDULE"]="$PARENT"
  SCHEDULE_INCLUDE_CHILDREN["$SCHEDULE"]="0"
  SCHEDULE_PREFIX["$SCHEDULE"]="zfs-send-${SCHEDULE}-"
  SCHEDULE_THRESHOLD_BYTES["$SCHEDULE"]=0
  clear_send_cleanup_caches
}

write_stubs() {
  cat > "${PATH%%:*}/zfs" <<'EOF'
#!/bin/bash
printf 'LOCAL zfs %s\n' "$*" >> "${ZFS_LOG:?}"
mode="$(cat "${STUB_MODE:?}")"
dataset="${@: -1}"
args=" $* "
if [[ "$1" == "destroy" ]]; then
  if [[ "$mode" == "local-dest" && -f "${LOCAL_SNAPS:?}" ]]; then
    tmp="${LOCAL_SNAPS}.tmp"
    : > "$tmp"
    removed=0
    while IFS=$'\t' read -r ds base epoch; do
      if [[ "${ds}@${base}" == "$dataset" ]]; then
        removed=1
        continue
      fi
      printf '%s\t%s\t%s\n' "$ds" "$base" "$epoch" >> "$tmp"
    done < "$LOCAL_SNAPS"
    mv "$tmp" "$LOCAL_SNAPS"
    if (( removed == 1 )); then
      exit 0
    fi
  fi
  echo "cannot open '${dataset}': dataset does not exist" >&2
  exit 1
fi
emit_snaps() {
  local want="$1"
  local kind="$2"
  local found=0 ds base epoch snap
  while IFS=$'\t' read -r ds base epoch; do
    [[ "$ds" == "$want" ]] || continue
    found=1
    snap="${ds}@${base}"
    if [[ "$kind" == "get" ]]; then
      printf '%s\tcreation\t%s\n' "$snap" "$epoch"
      printf '%s\twritten\t10\n' "$snap"
      printf '%s\tuserrefs\t0\n' "$snap"
      printf '%s\tclones\t-\n' "$snap"
      printf '%s\tguid\t1\n' "$snap"
      printf '%s\tcreatetxg\t1\n' "$snap"
    else
      printf '%s\t%s\n' "$snap" "$epoch"
    fi
  done < "${LOCAL_SNAPS:?}"
  if (( found == 0 )); then
    echo "cannot open '${want}': dataset does not exist" >&2
    return 1
  fi
  return 0
}
if [[ "$1" == "get" && "$args" == *" -t snapshot "* ]]; then
  target="$dataset"
  [[ "$target" == *"@"* ]] && target="${target%@*}"
  emit_snaps "$target" get
  exit $?
fi
if [[ "$1" == "list" && "$args" == *" -t snapshot "* ]]; then
  if [[ "$dataset" == *"@"* ]]; then
    if awk -F '\t' -v s="$dataset" '$1"@"$2==s { found=1 } END { exit(found?0:1) }' "${LOCAL_SNAPS:?}"; then
      printf '%s\n' "$dataset"
      exit 0
    fi
    echo "cannot open '${dataset}': dataset does not exist" >&2
    exit 1
  fi
  emit_snaps "$dataset" list
  exit $?
fi
if [[ "$1" == "list" ]]; then
  if awk -F '\t' -v d="$dataset" '$1==d { found=1 } END { exit(found?0:1) }' "${LOCAL_SNAPS:?}"; then
    printf '%s\n' "$dataset"
    exit 0
  fi
  echo "cannot open '${dataset}': dataset does not exist" >&2
  exit 1
fi
echo "unsupported local zfs $*" >&2
exit 1
EOF
  cat > "${PATH%%:*}/ssh" <<'EOF'
#!/bin/bash
printf 'SSH %s\n' "$*" >> "${SSH_LOG:?}"
# OpenSSH reads the caller's stdin unless -n is set. Drain it so a while-read
# loop cannot hide a missing -n. A tty is left alone so a local run does not block.
if [[ " $* " != *" -n "* ]] && [[ ! -t 0 ]]; then
  cat >/dev/null || true
fi
remote="${*: -1}"
dataset="${remote##* }"
dataset="${dataset//\'/}"
mode="$(cat "${STUB_MODE:?}")"
if [[ "$mode" == "listing-fail" && "$remote" == *" -t snapshot "* ]]; then
  echo "temporary lookup failure" >&2
  exit 1
fi
if [[ "$remote" == *"zfs destroy"* ]]; then
  tmp="${REMOTE_SNAPS:?}.tmp"
  : > "$tmp"
  removed=0
  while IFS=$'\t' read -r ds base epoch; do
    if [[ "${ds}@${base}" == "$dataset" ]]; then
      removed=1
      continue
    fi
    printf '%s\t%s\t%s\n' "$ds" "$base" "$epoch" >> "$tmp"
  done < "${REMOTE_SNAPS:?}"
  mv "$tmp" "$REMOTE_SNAPS"
  if (( removed == 1 )); then
    exit 0
  fi
  echo "cannot open '${dataset}': dataset does not exist" >&2
  exit 1
fi
emit_remote() {
  local want="$1"
  local kind="$2"
  local found=0 ds base epoch snap
  while IFS=$'\t' read -r ds base epoch; do
    [[ "$ds" == "$want" ]] || continue
    found=1
    snap="${ds}@${base}"
    if [[ "$kind" == "get" ]]; then
      printf '%s\tcreation\t%s\n' "$snap" "$epoch"
      printf '%s\twritten\t10\n' "$snap"
      printf '%s\tuserrefs\t0\n' "$snap"
      printf '%s\tclones\t-\n' "$snap"
      printf '%s\tguid\t7\n' "$snap"
      printf '%s\tcreatetxg\t7\n' "$snap"
    else
      printf '%s\t%s\n' "$snap" "$epoch"
    fi
  done < "${REMOTE_SNAPS:?}"
  if (( found == 0 )); then
    echo "cannot open '${want}': dataset does not exist" >&2
    return 1
  fi
  return 0
}
if [[ "$remote" == *"zfs get"* && "$remote" == *"-t snapshot"* ]]; then
  target="$dataset"
  [[ "$target" == *"@"* ]] && target="${target%@*}"
  emit_remote "$target" get
  exit $?
fi
if [[ "$remote" == *"zfs list"* && "$remote" == *"-t snapshot"* ]]; then
  if [[ "$dataset" == *"@"* ]]; then
    if awk -F '\t' -v s="$dataset" '$1"@"$2==s { found=1 } END { exit(found?0:1) }' "${REMOTE_SNAPS:?}"; then
      printf '%s\n' "$dataset"
      exit 0
    fi
    echo "cannot open '${dataset}': dataset does not exist" >&2
    exit 1
  fi
  emit_remote "$dataset" list
  exit $?
fi
if [[ "$remote" == *"zfs list"* || "$remote" == *"zfs get"* ]]; then
  if awk -F '\t' -v d="$dataset" '$1==d { found=1 } END { exit(found?0:1) }' "${REMOTE_SNAPS:?}"; then
    if [[ "$remote" == *" -o avail "* ]]; then
      printf '1000000\n'
    else
      printf '%s\n' "$dataset"
    fi
    exit 0
  fi
  echo "cannot open '${dataset}': dataset does not exist" >&2
  exit 1
fi
echo "unsupported remote command: $remote" >&2
exit 1
EOF
  chmod 755 "${PATH%%:*}/zfs" "${PATH%%:*}/ssh"
}

add_snap() {
  local file="$1"
  local dataset="$2"
  local base="$3"
  local epoch="$4"
  printf '%s\t%s\t%s\n' "$dataset" "$base" "$epoch" >> "$file"
}

assert_no_local_destination() {
  local label="$1"
  if grep -F "$PARENT" "$ZFS_LOG"; then
    fail "${label}: local zfs touched ${PARENT}: $(cat "$ZFS_LOG")"
  fi
}

assert_ssh_has() {
  local label="$1"
  local needle="$2"
  grep -F "$needle" "$SSH_LOG" >/dev/null || fail "${label}: ssh log missing '${needle}': $(cat "$SSH_LOG")"
}

run_retention_and_deletes() {
  local out="$1"
  queue_schedule_retention_cleanup "$SCHEDULE" >"$out" 2>&1 || true
  drain_inbox || true
  while next_ready_job_id job_id; do
    CURRENT_JOB_ID="$job_id"
    process_delete_job >>"$out" 2>&1 || true
    CURRENT_JOB_ID=""
  done
}

test_remote_only_checkpoint_is_destroyed_over_ssh() {
  local root out
  root="$(mktemp -d)"
  prepare_tree "$root"
  printf 'remote-only\n' > "$STUB_MODE"
  write_stubs
  add_snap "$LOCAL_SNAPS" "$SOURCE" "$OLD" 100
  add_snap "$LOCAL_SNAPS" "$SOURCE" "$NEW" 200
  add_snap "$REMOTE_SNAPS" "$PARENT" "$OLD" 100
  add_snap "$REMOTE_SNAPS" "$PARENT" "$NEW" 200
  SCHEDULE_TRANSPORT["$SCHEDULE"]="ssh"
  dataset_has_snapshot_basename "$PARENT" "$OLD" ssh || fail "ssh existence check did not see the remote-only checkpoint"
  if dataset_has_snapshot_basename "$PARENT" "$OLD" local; then
    fail "local existence check reported a checkpoint that is only on the receiver"
  fi
  : > "$ZFS_LOG"
  : > "$SSH_LOG"
  clear_send_cleanup_caches
  out="${root}/retention.out"
  run_retention_and_deletes "$out"
  [[ -f "$DELETE_QUEUE_INBOX_FILE" ]] || true
  # The inbox is drained. Re-read the captured worker fields from the log of the queued job
  # by checking the remote state and the command logs instead.
  assert_ssh_has "remote retention" "zfs get -H -p -o name,property,value -t snapshot"
  assert_ssh_has "remote retention" "$PARENT"
  assert_ssh_has "remote destroy" "zfs destroy -- ${OLD_SNAP}"
  if grep -F -- "-d 1" "$SSH_LOG"; then
    fail "destination snapshot reads must not use -d 1: $(cat "$SSH_LOG")"
  fi
  assert_no_local_destination "remote retention"
  if grep -F "Delete already done" "$out"; then
    fail "a snapshot that still exists on the receiver was treated as already gone: $(cat "$out")"
  fi
  if awk -F '\t' -v ds="$PARENT" -v base="$OLD" '$1 == ds && $2 == base { found = 1 } END { exit(found ? 0 : 1) }' "$REMOTE_SNAPS"; then
    fail "remote destroy did not remove ${OLD_SNAP}"
  fi
  awk -F '\t' -v ds="$PARENT" -v base="$NEW" '$1 == ds && $2 == base { found = 1 } END { exit(found ? 0 : 1) }' "$REMOTE_SNAPS" \
    || fail "the newest remote checkpoint was removed"
  if grep -F "Reseed triggered" "$out" || grep -F "Purging destination" "$out"; then
    fail "deleting an old remote checkpoint must not reseed"
  fi
  rm -rf "$root"
  echo "PASS: remote-only checkpoint is listed and destroyed over ssh"
}

test_remote_listing_failure_does_not_delete_or_reseed() {
  local root out gets sleeps
  root="$(mktemp -d)"
  prepare_tree "$root"
  printf 'listing-fail\n' > "$STUB_MODE"
  write_stubs
  add_snap "$LOCAL_SNAPS" "$SOURCE" "$OLD" 100
  add_snap "$LOCAL_SNAPS" "$SOURCE" "$NEW" 200
  add_snap "$REMOTE_SNAPS" "$PARENT" "$OLD" 100
  add_snap "$REMOTE_SNAPS" "$PARENT" "$NEW" 200
  SCHEDULE_TRANSPORT["$SCHEDULE"]="ssh"
  SEND_REMOTE_RETRIES_ENABLED=1
  SEND_REMOTE_MAX_ATTEMPTS=5
  SEND_REMOTE_RETRY_DELAY_SECONDS=300
  send_remote_retry_sleep_hook() { printf '%s\n' "$1" >> "$SLEEP_LOG"; }
  out="${root}/retention.out"
  queue_schedule_retention_cleanup "$SCHEDULE" >"$out" 2>&1 || true
  if [[ -f "$DELETE_QUEUE_INBOX_FILE" ]] && grep -F "$PARENT@" "$DELETE_QUEUE_INBOX_FILE"; then
    fail "a failed remote listing queued a delete: $(cat "$DELETE_QUEUE_INBOX_FILE")"
  fi
  if grep -F "Reseed triggered" "$out" || grep -F "Purging destination" "$out"; then
    fail "a failed remote listing triggered a reseed: $(cat "$out")"
  fi
  grep -F "nothing will be deleted or reseeded" "$out" >/dev/null || fail "a failed remote listing must say deletes and reseed were skipped: $(cat "$out")"
  send_reseed_permitted && fail "a failed remote listing must not permit reseed"
  gets="$(grep -c 'zfs get -H -p -o name,property,value -t snapshot' "$SSH_LOG" || true)"
  [[ "$gets" == "5" ]] || fail "a failed remote snapshot get must be tried 5 times, saw ${gets}"
  sleeps="$(grep -c '^300$' "$SLEEP_LOG" || true)"
  [[ "$sleeps" -ge 4 ]] || fail "retries must wait 300 seconds only after a failure, saw ${sleeps} waits"
  if grep -E '^[0-9]+$' "$SLEEP_LOG" | grep -v '^300$' >/dev/null; then
    fail "retry delay must stay 300 seconds: $(cat "$SLEEP_LOG")"
  fi
  assert_no_local_destination "failed remote listing"
  if grep -F "zfs destroy" "$SSH_LOG" || grep -F "zfs destroy" "$ZFS_LOG"; then
    fail "a failed remote listing must not destroy anything"
  fi
  rm -rf "$root"
  echo "PASS: remote listing failure does not delete or reseed"
}

test_local_destination_still_deletes_locally() {
  local root out
  root="$(mktemp -d)"
  prepare_tree "$root"
  printf 'local-dest\n' > "$STUB_MODE"
  write_stubs
  add_snap "$LOCAL_SNAPS" "$SOURCE" "$OLD" 100
  add_snap "$LOCAL_SNAPS" "$SOURCE" "$NEW" 200
  add_snap "$LOCAL_SNAPS" "$PARENT" "$OLD" 100
  add_snap "$LOCAL_SNAPS" "$PARENT" "$NEW" 200
  SCHEDULE_TRANSPORT["$SCHEDULE"]="local"
  out="${root}/retention.out"
  run_retention_and_deletes "$out"
  grep -F "zfs destroy -- ${OLD_SNAP}" "$ZFS_LOG" >/dev/null || fail "local destination destroy did not run locally: $(cat "$ZFS_LOG")"
  if [[ -s "$SSH_LOG" ]]; then
    fail "local destination used ssh: $(cat "$SSH_LOG")"
  fi
  if grep -F "Delete already done" "$out"; then
    fail "a snapshot that existed locally was treated as already gone: $(cat "$out")"
  fi
  if awk -F '\t' -v ds="$PARENT" -v base="$OLD" '$1 == ds && $2 == base { found = 1 } END { exit(found ? 0 : 1) }' "$LOCAL_SNAPS"; then
    fail "local destroy did not remove ${OLD_SNAP}"
  fi
  awk -F '\t' -v ds="$PARENT" -v base="$NEW" '$1 == ds && $2 == base { found = 1 } END { exit(found ? 0 : 1) }' "$LOCAL_SNAPS" \
    || fail "the newest local checkpoint was removed"
  awk -F '\t' -v ds="$SOURCE" -v base="$OLD" '$1 == ds && $2 == base { found = 1 } END { exit(found ? 0 : 1) }' "$LOCAL_SNAPS" \
    || fail "destination retention removed the source checkpoint"
  rm -rf "$root"
  echo "PASS: local destination retention still uses local zfs"
}

test_confirmed_absent_check_uses_remote_host() {
  local root out destroys lists
  root="$(mktemp -d)"
  prepare_tree "$root"
  printf 'remote-only\n' > "$STUB_MODE"
  write_stubs
  add_snap "$REMOTE_SNAPS" "$PARENT" "$NEW" 200
  SCHEDULE_TRANSPORT["$SCHEDULE"]="ssh"
  out="${root}/absent.out"
  if ! destroy_snapshot_for_transport ssh "$OLD_SNAP" >"$out" 2>&1; then
    fail "a snapshot confirmed absent on the receiver must count as already done: $(cat "$out")"
  fi
  grep -F "Delete already done" "$out" >/dev/null || fail "confirmed-absent delete must say it is already done: $(cat "$out")"
  assert_ssh_has "confirmed absent" "zfs destroy -- ${OLD_SNAP}"
  assert_ssh_has "confirmed absent" "zfs list -H -o name -t snapshot -- ${OLD_SNAP}"
  destroys="$(grep -c "zfs destroy -- ${OLD_SNAP}" "$SSH_LOG" || true)"
  lists="$(grep -c "zfs list -H -o name -t snapshot -- ${OLD_SNAP}" "$SSH_LOG" || true)"
  [[ "$destroys" == "1" ]] || fail "confirmed-absent delete must not retry the destroy, saw ${destroys}"
  [[ "$lists" == "1" ]] || fail "confirmed-absent check must list the snapshot once on the receiver, saw ${lists}"
  assert_no_local_destination "confirmed absent"
  if grep -F "$OLD_SNAP" "$ZFS_LOG"; then
    fail "confirmed-absent check ran zfs on the local host: $(cat "$ZFS_LOG")"
  fi
  rm -rf "$root"
  echo "PASS: confirmed-absent check runs on the remote host"
}

test_enqueue_keeps_empty_fields_and_transport() {
  local root line count
  local -a fields=()
  local -A parsed=()
  root="$(mktemp -d)"
  prepare_tree "$root"
  printf 'remote-only\n' > "$STUB_MODE"
  write_stubs
  add_snap "$LOCAL_SNAPS" "$SOURCE" "$OLD" 100
  add_snap "$LOCAL_SNAPS" "$SOURCE" "$NEW" 200
  add_snap "$REMOTE_SNAPS" "$PARENT" "$OLD" 100
  add_snap "$REMOTE_SNAPS" "$PARENT" "$NEW" 200
  SCHEDULE_TRANSPORT["$SCHEDULE"]="ssh"
  queue_schedule_retention_cleanup "$SCHEDULE" >/dev/null 2>&1 || true
  [[ -f "$DELETE_QUEUE_INBOX_FILE" ]] || fail "retention did not queue the remote checkpoint"
  count="$(grep -c '^ENQUEUE' "$DELETE_QUEUE_INBOX_FILE" || true)"
  [[ "$count" == "1" ]] || fail "send transport was split onto another enqueue line: $(cat "$DELETE_QUEUE_INBOX_FILE")"
  line="$(head -n 1 "$DELETE_QUEUE_INBOX_FILE")"
  read_tsv_fields "$line" fields
  [[ "${fields[12]:-}" == "1" ]] || fail "send-protected flag shifted, saw ${fields[12]:-}"
  [[ "${fields[13]:-}" == "destination_checkpoint" ]] || fail "delete scope shifted, saw ${fields[13]:-}"
  [[ "${fields[15]:-}" == "ssh" ]] || fail "enqueue line lost ssh transport, saw ${fields[15]:-}"
  [[ -z "${fields[8]:-}" && -z "${fields[9]:-}" ]] || fail "empty guid/createtxg were not preserved"
  delete_queue_parse_enqueue_line "$line" parsed || fail "enqueue line did not parse"
  [[ "${parsed[SEND_TRANSPORT]}" == "ssh" ]] || fail "parsed transport is ${parsed[SEND_TRANSPORT]:-empty}"
  [[ "${parsed[DELETE_SCOPE]}" == "destination_checkpoint" ]] || fail "parsed scope is ${parsed[DELETE_SCOPE]:-empty}"
  [[ "${parsed[SEND_PROTECTED]}" == "1" ]] || fail "parsed protected flag is ${parsed[SEND_PROTECTED]:-empty}"
  rm -rf "$root"
  echo "PASS: delete queue keeps empty guid fields and ssh transport"
}

test_enqueue_keeps_empty_fields_and_transport
test_remote_only_checkpoint_is_destroyed_over_ssh
test_remote_listing_failure_does_not_delete_or_reseed
test_local_destination_still_deletes_locally
test_confirmed_absent_check_uses_remote_host
