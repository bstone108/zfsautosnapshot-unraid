#!/bin/bash
# Confirmed remote snapshot listings, and send-step retries that wait only
# after a failure of that same step.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OPS_LIB="${ROOT_DIR}/source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/ops-queue-lib.sh"

# shellcheck source=/dev/null
source "$OPS_LIB"

log() {
  printf '%s %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

sleep_log="$(mktemp)"
ssh_log="$(mktemp)"
send_count_file="$(mktemp)"
cleanup() {
  rm -f "$sleep_log" "$ssh_log" "$send_count_file"
}
trap cleanup EXIT

send_remote_retry_sleep_hook() {
  printf '%s\n' "$1" >> "$sleep_log"
}

reset_attempt_logs() {
  : > "$sleep_log"
  : > "$ssh_log"
}

sleep_count() {
  grep -c . "$sleep_log" || true
}

ssh_count() {
  grep -c . "$ssh_log" || true
}

[[ "$(send_remote_max_attempts)" == "1" ]] || fail "retries stay single-attempt until the send worker enables them"
SEND_REMOTE_RETRIES_ENABLED=1
SEND_REMOTE_MAX_ATTEMPTS=5
SEND_REMOTE_RETRY_DELAY_SECONDS=300
[[ "$(send_remote_max_attempts)" == "5" ]] || fail "enabled send retries must default to 5 attempts"
[[ "$(send_remote_retry_delay_seconds)" == "300" ]] || fail "send retry delay must default to 300 seconds"

tmp_bin="$(mktemp -d)"
trap 'rm -rf "$tmp_bin"; cleanup' EXIT

cat > "${tmp_bin}/ssh" <<'EOF'
#!/bin/bash
remote_command="${*: -1}"
printf '%s\n' "$remote_command" >> "$SSH_CALL_LOG"
mode="${SSH_LIST_MODE:-ok}"
case "$mode" in
  fail)
    exit 1
    ;;
  fail-twice)
    seen="$(grep -c . "$SSH_CALL_LOG" || true)"
    if (( seen <= 2 )); then
      exit 1
    fi
    printf '%s\t%s\n' "backup/data@zfs-send-ef8948aa4533-2026-10-29_00-00-55" "100"
    exit 0
    ;;
  absent)
    echo "cannot open 'backup/data': dataset does not exist" >&2
    exit 1
    ;;
  empty)
    exit 0
    ;;
  garbage)
    printf '%s\n' "not-a-snapshot-list"
    exit 0
    ;;
  other-snaps)
    printf '%s\t%s\n' "backup/data@manual-only" "50"
    exit 0
    ;;
  resume-absent)
    if [[ "$remote_command" == *"receive_resume_token"* ]]; then
      printf '%s\n' "__ZFSAS_RECEIVER_DATASET_ABSENT__"
      exit 0
    fi
    if [[ "$remote_command" == *"zfs receive"* ]]; then
      cat >/dev/null
      exit 0
    fi
    exit 1
    ;;
  *)
    printf '%s\t%s\n' "backup/data@zfs-send-ef8948aa4533-2026-10-29_00-00-55" "100"
    exit 0
    ;;
esac
EOF
chmod +x "${tmp_bin}/ssh"
export SSH_CALL_LOG="$ssh_log"
export PATH="${tmp_bin}:$PATH"

SEND_SSH_HOST="backup.example.test"
SEND_SSH_PORT="22"
SEND_SSH_USER="replicator"
SEND_SSH_KEY_PATH=""
SEND_RATE_LIMIT="0"

zfs() {
  if [[ "$1" == "send" ]]; then
    local count
    count="$(cat "$SEND_COUNT_FILE")"
    count=$((count + 1))
    printf '%s' "$count" > "$SEND_COUNT_FILE"
    if [[ "${ZFS_SEND_MODE:-ok}" == "mismatch" ]]; then
      echo "cannot receive incremental stream: most recent snapshot of backup/data does not match incremental source" >&2
      return 1
    fi
    if [[ "${ZFS_SEND_MODE:-ok}" == "fail" ]]; then
      return 9
    fi
    if [[ "${ZFS_SEND_MODE:-ok}" == "fail-once" && "$count" -lt 2 ]]; then
      return 9
    fi
    printf 'stream'
    return 0
  fi
  if [[ "$1" == "list" ]]; then
    local args=" $* "
    if [[ "$args" == *" -t snapshot "* && "$args" == *" source/data "* ]]; then
      printf '%s\t%s\n' \
        "source/data@zfs-send-ef8948aa4533-2026-10-29_00-00-55" "100" \
        "source/data@zfs-send-ef8948aa4533-2026-10-30_00-00-55" "200"
      return 0
    fi
    if [[ "$args" == *" source/data "* ]]; then
      printf '%s\n' "source/data"
      return 0
    fi
  fi
  return 1
}
export SEND_COUNT_FILE="$send_count_file"
export -f zfs

lookup_common() {
  latest=""
  find_latest_common_basename_for_member_transport "source/data" "backup/data" "zfs-send-ef8948aa4533-" latest ssh
}

reset_attempt_logs
export SSH_LIST_MODE="ok"
latest=""
lookup_common
[[ "$latest" == "zfs-send-ef8948aa4533-2026-10-29_00-00-55" ]] || fail "confirmed listings must select the shared snapshot, got '${latest}'"
[[ "${SEND_COMMON_BASE_LISTING}" == "ok" ]] || fail "a successful listing must be marked ok"
if send_common_base_missing_proven "$latest" "zfs-send-ef8948aa4533-2026-10-30_00-00-55"; then
  fail "a confirmed common snapshot must not take the no-common/reseed path"
fi
[[ "$(sleep_count)" == "0" ]] || fail "a successful listing must not wait before the next step"
first_success_ssh="$(ssh_count)"
reset_attempt_logs
lookup_common
[[ "$latest" == "zfs-send-ef8948aa4533-2026-10-29_00-00-55" ]] || fail "a second successful listing should still find the common snapshot"
[[ "$(sleep_count)" == "0" ]] || fail "successful steps must not insert a delay between them"
[[ "$(ssh_count)" == "$first_success_ssh" ]] || fail "a successful listing must not be repeated"

reset_attempt_logs
export SSH_LIST_MODE="empty"
lookup_common
[[ -z "$latest" ]] || fail "a confirmed empty listing has no common snapshot"
[[ "${SEND_COMMON_BASE_LISTING}" == "ok" ]] || fail "exit 0 with no rows is a verified empty listing"
[[ "${SEND_COMMON_BASE_DEST_SNAPSHOT_COUNT}" == "0" ]] || fail "a verified empty listing must report zero snapshots"
if send_common_base_missing_proven "$latest" "zfs-send-ef8948aa4533-2026-10-30_00-00-55"; then
  fail "a verified empty destination must not suggest purge/reseed"
fi
[[ "$(ssh_count)" == "1" ]] || fail "a verified empty listing is success and must not be retried"
[[ "$(sleep_count)" == "0" ]] || fail "a verified empty listing must not wait"

reset_attempt_logs
export SSH_LIST_MODE="garbage"
if lookup_common; then
  fail "an unreadable listing must not look like a successful base lookup"
fi
[[ "${SEND_COMMON_BASE_LISTING}" == "failed" ]] || fail "unreadable listing text must stay unverified"
if send_common_base_missing_proven "" "zfs-send-ef8948aa4533-2026-10-30_00-00-55"; then
  fail "an unverified listing must not suggest purge/reseed"
fi
[[ "$(sleep_count)" == "0" ]] || fail "exit 0 with unreadable text is not a connection retry"

reset_attempt_logs
export SSH_LIST_MODE="other-snaps"
lookup_common
[[ -z "$latest" ]] || fail "unrelated destination snapshots are not a common send checkpoint"
[[ "${SEND_COMMON_BASE_LISTING}" == "ok" ]] || fail "a real snapshot list is confirmed"
[[ "${SEND_COMMON_BASE_DEST_SNAPSHOT_COUNT}" == "1" ]] || fail "confirmed destination snapshots must be counted"
if ! send_common_base_missing_proven "$latest" "zfs-send-ef8948aa4533-2026-10-30_00-00-55"; then
  fail "a confirmed list with snapshots and no shared checkpoint may take the no-common path"
fi
[[ "$(sleep_count)" == "0" ]] || fail "a confirmed no-common result must not wait to retry"

reset_attempt_logs
export SSH_LIST_MODE="absent"
lookup_common
[[ -z "$latest" ]] || fail "a proven-absent destination has no common snapshot"
[[ "${SEND_COMMON_BASE_LISTING}" == "absent" ]] || fail "dataset does not exist must be proven absence, not an empty list"
if send_common_base_missing_proven "$latest" "zfs-send-ef8948aa4533-2026-10-30_00-00-55"; then
  fail "a proven-absent destination must not suggest purge/reseed"
fi
[[ "$(ssh_count)" == "1" ]] || fail "proven dataset absence must not be retried"
[[ "$(sleep_count)" == "0" ]] || fail "proven dataset absence must not wait"

reset_attempt_logs
export SSH_LIST_MODE="fail"
if lookup_common; then
  fail "a failed remote listing must not be treated as a successful base lookup"
fi
[[ "${SEND_COMMON_BASE_LISTING}" == "failed" ]] || fail "a failed remote listing must stay failed"
if send_common_base_missing_proven "" "zfs-send-ef8948aa4533-2026-10-30_00-00-55"; then
  fail "a failed remote listing must not suggest purge/reseed"
fi
[[ "$(ssh_count)" == "5" ]] || fail "a failed listing must be tried 5 times, saw $(ssh_count)"
[[ "$(sleep_count)" == "4" ]] || fail "delay only between failed attempts, saw $(sleep_count) sleeps"
[[ "$(sort -u "$sleep_log")" == "300" ]] || fail "the retry delay must be 300 seconds"

reset_attempt_logs
export SSH_LIST_MODE="fail-twice"
lookup_common
[[ "$latest" == "zfs-send-ef8948aa4533-2026-10-29_00-00-55" ]] || fail "listing must succeed on the third attempt"
[[ "$(ssh_count)" == "3" ]] || fail "success must stop the listing retries, saw $(ssh_count)"
[[ "$(sleep_count)" == "2" ]] || fail "two failures must wait twice, saw $(sleep_count)"
export SSH_LIST_MODE="empty"
lookup_common
[[ -z "$latest" ]] || fail "the next successful listing should run after the recovered one"
[[ "$(sleep_count)" == "2" ]] || fail "a later successful step must not add another wait"

# Send/receive retries are a separate step from the listing. A failure waits,
# then repeats that send. Success does not wait, and an incremental base
# mismatch is not retried.
run_send_case() {
  local mode="$1"
  export ZFS_SEND_MODE="$mode"
  export SSH_LIST_MODE="resume-absent"
  printf '0' > "$SEND_COUNT_FILE"
  declare -gA job=()
  job[SEND_TRANSPORT]="ssh"
  local before_sleep after_sleep sends
  before_sleep="$(sleep_count)"
  if [[ "$mode" == "fail" ]]; then
    if run_pipeline_with_status "full send" "" "source/data@zfs-send-ef8948aa4533-2026-10-30_00-00-55" "backup/data" 0 0 99; then
      fail "a send that keeps failing must fail after the last attempt"
    fi
    [[ "${SEND_REMOTE_STEP_EXHAUSTED}" == "1" ]] || fail "the send step must be exhausted only after the last attempt"
  elif [[ "$mode" == "mismatch" ]]; then
    if run_pipeline_with_status "incremental send" "source/data@zfs-send-ef8948aa4533-2026-10-29_00-00-55" "source/data@zfs-send-ef8948aa4533-2026-10-30_00-00-55" "backup/data" 0 0 99; then
      fail "an incremental base mismatch must fail"
    fi
    [[ "${SEND_PIPELINE_NEEDS_FULL_RESEND}" == "1" ]] || fail "an incremental base mismatch must request a full resend instead of another incremental retry"
    [[ "${SEND_REMOTE_STEP_EXHAUSTED:-0}" == "0" ]] || fail "an incremental base mismatch must not consume the transient retry budget"
  else
    if ! run_pipeline_with_status "full send" "" "source/data@zfs-send-ef8948aa4533-2026-10-30_00-00-55" "backup/data" 0 0 99; then
      fail "a send that succeeds on a later attempt must succeed"
    fi
  fi
  after_sleep="$(sleep_count)"
  sends="$(cat "$SEND_COUNT_FILE")"
  printf '%s %s\n' "$((after_sleep - before_sleep))" "$sends"
}

reset_attempt_logs
read -r sleeps sends < <(run_send_case fail-once)
[[ "$sends" == "2" ]] || fail "a failed send must be retried once and then continue, saw ${sends} sends"
[[ "$sleeps" == "1" ]] || fail "one send failure must wait once, saw ${sleeps}"

read -r sleeps sends < <(run_send_case mismatch)
[[ "$sends" == "1" ]] || fail "an incremental mismatch must not be sent again, saw ${sends}"
[[ "$sleeps" == "0" ]] || fail "an incremental mismatch must not wait to retry the same incremental"

read -r sleeps sends < <(run_send_case fail)
[[ "$sends" == "5" ]] || fail "a failing send must be attempted 5 times, saw ${sends}"
[[ "$sleeps" == "4" ]] || fail "a failing send must wait only between attempts, saw ${sleeps}"

SEND_AUTO_RESEED=1
SEND_COMMON_BASE_LISTING="ok"
SEND_COMMON_BASE_DEST_SNAPSHOT_COUNT=2
send_reseed_permitted || fail "a confirmed listing must allow reseed by default"
SEND_COMMON_BASE_LISTING="failed"
if send_reseed_permitted; then
  fail "a failed listing must not allow reseed"
fi
SEND_COMMON_BASE_LISTING="ok"
SEND_COMMON_BASE_DEST_SNAPSHOT_COUNT=0
send_reseed_permitted || fail "a confirmed empty listing may rebuild with a full send and no purge"
SEND_AUTO_RESEED=0
if send_reseed_permitted; then
  fail "SEND_AUTO_RESEED=0 must disable the rebuild"
fi
SEND_AUTO_RESEED=1

printf '%s\n' "PASS: send remote retry and confirmed listing checks"
