#!/bin/bash
# A manual enqueue must not create a second run while another enqueue holds the
# schedule lock. A full send planned before the destination received a checkpoint
# must become an incremental, or a no-op when that checkpoint is already the
# common one. "destination has snapshots" must not be retried across the
# five-minute delays.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${ROOT_DIR}/source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/ops-queue-lib.sh"
# shellcheck source=/dev/null
source "$LIB"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

SCHEDULE="c4e2f1a7b305"
SOURCE="cache/grokbot-retention-test"
DEST="storage/Backups/neko-cache/grokbot-retention-test"
PREFIX="zfs-send-${SCHEDULE}-"
COMMON="${PREFIX}2026-11-04_10-47-37"
REQUESTED="${PREFIX}2026-11-04_10-48-05"

root="$(mktemp -d)"
mkdir -p "${root}/bin" "${root}/ops/jobs" "${root}/ops/status" "${root}/config" "${root}/run" "${root}/persist"
export PATH="${root}/bin:${PATH}"
export CONFIG_DIR="${root}/config"
export SEND_CONFIG_FILE="${root}/config/zfs_send.conf"
export SEND_SCHEDULE_STATE_FILE="${root}/config/send_schedule_state.state"
: > "$SEND_CONFIG_FILE"
export OPS_ROOT="${root}/ops"
export OPS_JOBS_DIR="${root}/ops/jobs"
export OPS_STATUS_DIR="${root}/ops/status"
export RUNTIME_DIR="${root}/run"
export LOG_FILE="${root}/send.log"
: > "$LOG_FILE"
export ZFS_LOG="${root}/zfs.log"
export SSH_LOG="${root}/ssh.log"
export SLEEP_LOG="${root}/sleep.log"
: > "$ZFS_LOG"
: > "$SSH_LOG"
: > "$SLEEP_LOG"

send_remote_retry_sleep_hook() {
  printf '%s\n' "$1" >> "$SLEEP_LOG"
}

cat > "${root}/bin/zfs" <<EOF
#!/bin/bash
printf 'LOCAL %s\n' "\$*" >> "\${ZFS_LOG:?}"
dataset="\${@: -1}"
args=" \$* "
if [[ "\$1" == "send" ]]; then
  count=0
  if [[ -f "\${SEND_COUNT_FILE:-}" ]]; then
    count="\$(cat "\$SEND_COUNT_FILE")"
  fi
  count=\$((count + 1))
  printf '%s' "\$count" > "\${SEND_COUNT_FILE:?}"
  printf 'stream'
  exit 0
fi
if [[ "\$1" == "list" && "\$args" == *" -t snapshot "* ]]; then
  printf '%s\t%s\n' "${SOURCE}@${COMMON}" 100 "${SOURCE}@${REQUESTED}" 200
  exit 0
fi
if [[ "\$1" == "list" ]]; then
  printf '%s\n' "\$dataset"
  exit 0
fi
if [[ "\$1" == "get" ]]; then
  exit 0
fi
exit 0
EOF
cat > "${root}/bin/ssh" <<EOF
#!/bin/bash
printf 'SSH %s\n' "\$*" >> "\${SSH_LOG:?}"
remote="\${*: -1}"
mode="\${SSH_MODE:-common}"
if [[ "\$remote" == *"receive_resume_token"* ]]; then
  printf '%s\n' "__ZFSAS_RECEIVER_DATASET_ABSENT__"
  exit 0
fi
if [[ "\$remote" == *"zfs receive"* ]]; then
  cat >/dev/null
  if [[ "\$mode" == "dest-snapshots" ]]; then
    echo "cannot receive new filesystem stream: destination has snapshots" >&2
    echo "must destroy them to overwrite it" >&2
    exit 1
  fi
  exit 0
fi
if [[ "\$remote" == *" -t snapshot "* ]]; then
  if [[ "\$mode" == "already" ]]; then
    printf '%s\t%s\n' "${DEST}@${COMMON}" 100 "${DEST}@${REQUESTED}" 200
    exit 0
  fi
  printf '%s\t%s\n' "${DEST}@${COMMON}" 100
  exit 0
fi
exit 0
EOF
chmod 755 "${root}/bin/zfs" "${root}/bin/ssh"

SCHEDULE_JOB_IDS=("$SCHEDULE")
SCHEDULE_SOURCE_ROOT["$SCHEDULE"]="$SOURCE"
SCHEDULE_DEST_ROOT["$SCHEDULE"]="$DEST"
SCHEDULE_INCLUDE_CHILDREN["$SCHEDULE"]="1"
SCHEDULE_PREFIX["$SCHEDULE"]="$PREFIX"
SCHEDULE_TRANSPORT["$SCHEDULE"]="local"
SCHEDULE_FREQUENCY["$SCHEDULE"]="1d"
SCHEDULE_THRESHOLD_RAW["$SCHEDULE"]="100G"
SCHEDULE_THRESHOLD_BYTES["$SCHEDULE"]=100
SEND_SNAPSHOT_PREFIX="zfs-send-"
SEND_SSH_HOST="kiki.example"
SEND_SSH_PORT="22"
SEND_SSH_USER="root"
SEND_SSH_KEY_PATH=""
SEND_RATE_LIMIT="0"
SEND_REMOTE_RETRIES_ENABLED=1
SEND_REMOTE_MAX_ATTEMPTS=5
SEND_REMOTE_RETRY_DELAY_SECONDS=300
SEND_REMOTE_RETRY_DEPTH=0
SEND_JOBS_PARSED=0

resolved=""
reselect_stale_full_send_base "$SOURCE" "$DEST" "${SOURCE}@${REQUESTED}" "$PREFIX" ssh resolved
[[ "$resolved" == "${SOURCE}@${COMMON}" ]] || fail "a stale full send must switch to the common checkpoint, got '${resolved}'"

export SSH_MODE="already"
resolved=""
reselect_stale_full_send_base "$SOURCE" "$DEST" "${SOURCE}@${REQUESTED}" "$PREFIX" ssh resolved
[[ "$resolved" == "skip" ]] || fail "a checkpoint the destination already has must be a no-op, got '${resolved}'"
export SSH_MODE="common"

if acquire_schedule_enqueue_lock "$SCHEDULE"; then
  :
else
  fail "the first enqueue lock must be acquired"
fi
enqueue_out="$(enqueue_scheduled_send_jobs_due "$(date +%s)" 2>&1 || true)"
prepare_jobs="$(find "$OPS_JOBS_DIR" -type f -name "*send-${SCHEDULE}-*" -print 2>/dev/null || true)"
[[ -z "$prepare_jobs" ]] || fail "a second enqueue must not create a prepare job while the schedule lock is held"
[[ "$enqueue_out" == *"Skipping scheduled send ${SCHEDULE}"* ]] || fail "the skipped enqueue must say why"
release_schedule_enqueue_lock "$SCHEDULE"
if ! acquire_schedule_enqueue_lock "$SCHEDULE"; then
  fail "releasing the enqueue lock must allow the next enqueue"
fi
release_schedule_enqueue_lock "$SCHEDULE"

export SSH_MODE="dest-snapshots"
export SEND_COUNT_FILE="${root}/sends.count"
printf '0' > "$SEND_COUNT_FILE"
: > "$SLEEP_LOG"
declare -gA job=()
job[SEND_TRANSPORT]="ssh"
if run_pipeline_with_status "full send" "" "${SOURCE}@${REQUESTED}" "$DEST" 0 0 99; then
  fail "a destination-has-snapshots full send must fail"
fi
sends="$(cat "$SEND_COUNT_FILE")"
sleeps="$(grep -c . "$SLEEP_LOG" || true)"
[[ "$sends" == "1" ]] || fail "destination has snapshots must not be sent again, saw ${sends}"
[[ "$sleeps" == "0" ]] || fail "destination has snapshots must not wait out the retry budget, saw ${sleeps}"
[[ "${SEND_PIPELINE_PERMANENT_FAILURE}" == "1" ]] || fail "destination has snapshots must be a permanent send failure"
[[ "${SEND_PIPELINE_NEEDS_FULL_RESEND:-0}" == "0" ]] || fail "destination has snapshots must not purge the destination for a reseed"
[[ "${SEND_REMOTE_STEP_EXHAUSTED:-0}" == "0" ]] || fail "a permanent destination conflict must not be reported as an exhausted transient retry"

rm -rf "$root"
echo "PASS: manual/scheduled race does not duplicate a full send or stall on destination has snapshots"
