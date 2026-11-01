#!/bin/bash
# Destination zfs commands must follow the send transport.
# SSH destinations run list/destroy/rollback/destroy -r on the receiver.
# Local destinations stay on the local zfs binary.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OPS_LIB="${ROOT_DIR}/source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/ops-queue-lib.sh"
DELETE_WORKER="${ROOT_DIR}/source/usr/local/sbin/zfs_autosnapshot_delete_worker"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "${TMP}/bin" "${TMP}/ops" "${TMP}/run" "${TMP}/config"
ZFS_LOG="${TMP}/zfs.log"
SSH_LOG="${TMP}/ssh.log"
: > "$ZFS_LOG"
: > "$SSH_LOG"

cat > "${TMP}/bin/zfs" <<'EOF'
#!/bin/bash
printf 'zfs %s\n' "$*" >> "${ZFS_LOG:?}"
if [[ "${1:-}" == "list" ]]; then
  printf '%s\n' "storage/Backups/susanoo-cache/appdata"
  printf '%s\t%s\n' "storage/Backups/susanoo-cache/appdata@zfs-send-ef8948aa4533-2026-10-01_10-28-04" "100"
  exit 0
fi
if [[ "${1:-}" == "destroy" || "${1:-}" == "rollback" ]]; then
  echo "cannot open '$*': dataset does not exist" >&2
  exit 1
fi
exit 0
EOF
cat > "${TMP}/bin/ssh" <<'EOF'
#!/bin/bash
printf 'ssh %s\n' "$*" >> "${SSH_LOG:?}"
exit 0
EOF
chmod +x "${TMP}/bin/zfs" "${TMP}/bin/ssh"

export ZFS_LOG SSH_LOG
export PATH="${TMP}/bin:${PATH}"
export ZFSAS_OPS_LIB="$OPS_LIB"
export ZFSAS_DELETE_WORKER_AS_LIBRARY=1
export CONFIG_DIR="${TMP}/config"
export SEND_CONFIG_FILE="${CONFIG_DIR}/zfs_send.conf"
export OPS_ROOT="${TMP}/ops"
export OPS_JOBS_DIR="${OPS_ROOT}/jobs"
export OPS_STATUS_DIR="${OPS_ROOT}/status"
export RUNTIME_DIR="${TMP}/run"
export LOG_FILE="${TMP}/send.log"
: > "$LOG_FILE"

# shellcheck source=/dev/null
source "$DELETE_WORKER"

delete_retry_sleep_hook() { :; }
checkpoint_basename_is_latest_common_for_schedule() { return 1; }
snapshot_delete_conflicts_with_send_jobs() { return 1; }

SEND_SSH_HOST="kiki.example"
SEND_SSH_PORT="22"
SEND_SSH_USER="root"
SEND_SSH_KEY_PATH="/root/.ssh/id_ed25519"
SEND_SNAPSHOT_PREFIX="zfs-send-"
SCHEDULE_SOURCE_ROOT["ef8948aa4533"]="cache/appdata"
SCHEDULE_DEST_ROOT["ef8948aa4533"]="storage/Backups/susanoo-cache/appdata"
SCHEDULE_PREFIX["ef8948aa4533"]="zfs-send-ef8948aa4533-"

reset_logs() {
  : > "$ZFS_LOG"
  : > "$SSH_LOG"
}

zfs_log() { cat "$ZFS_LOG"; }
ssh_log() { cat "$SSH_LOG"; }

assert_ssh_destroy() {
  local label="$1"
  grep -q 'zfs destroy' "$SSH_LOG" || fail "${label}: expected ssh to carry zfs destroy, saw: $(ssh_log)"
  if grep -q 'zfs destroy' "$ZFS_LOG"; then
    fail "${label}: local zfs destroy ran: $(zfs_log)"
  fi
}

assert_local_destroy() {
  local label="$1"
  grep -q 'zfs destroy' "$ZFS_LOG" || fail "${label}: expected a local zfs destroy, saw: $(zfs_log)"
  if grep -q 'zfs destroy' "$SSH_LOG"; then
    fail "${label}: ssh destroy ran for a local destination: $(ssh_log)"
  fi
}

queue_destination_delete() {
  local job_id="$1"
  local transport="$2"
  local -A queued=()
  queued[JOB_ID]="$job_id"
  queued[STATE]="queued"
  queued[SNAPSHOT]="storage/Backups/susanoo-cache/appdata@zfs-send-ef8948aa4533-2026-10-01_10-28-04"
  queued[SNAPSHOT_NAME]="zfs-send-ef8948aa4533-2026-10-01_10-28-04"
  queued[DATASET]="storage/Backups/susanoo-cache/appdata"
  queued[DELETE_SCOPE]="destination_checkpoint"
  queued[SEND_PROTECTED]="1"
  queued[SEND_SCHEDULE_JOB_ID]="ef8948aa4533"
  queued[SEND_TRANSPORT]="$transport"
  queue_add_job queued
}

SNAPSHOT="storage/Backups/susanoo-cache/appdata@zfs-send-ef8948aa4533-2026-10-01_10-28-04"
DATASET="storage/Backups/susanoo-cache/appdata"

reset_logs
unset 'SCHEDULE_TRANSPORT[ef8948aa4533]' || true
queue_destination_delete "job-ssh-field" "ssh"
CURRENT_JOB_ID="job-ssh-field"
process_send_checkpoint_delete
assert_ssh_destroy "delete worker uses the transport saved on the job when the schedule table has no transport"

reset_logs
SCHEDULE_TRANSPORT["ef8948aa4533"]="SSH"
queue_destination_delete "job-ssh-schedule" ""
CURRENT_JOB_ID="job-ssh-schedule"
process_send_checkpoint_delete
assert_ssh_destroy "delete worker treats schedule transport SSH as remote"

reset_logs
SCHEDULE_TRANSPORT["ef8948aa4533"]="local"
queue_destination_delete "job-local" "local"
CURRENT_JOB_ID="job-local"
# Local destroy fails in the stub. Do not spend the real retry sleeps.
set +e
process_send_checkpoint_delete
set -e
assert_local_destroy "local destination checkpoint delete stays on local zfs"

reset_logs
list_snapshots_for_transport ssh "$DATASET" 0 >/dev/null
grep -q 'zfs list' "$SSH_LOG" || fail "SSH snapshot list must go over ssh: $(ssh_log)"
if grep -q 'zfs list' "$ZFS_LOG"; then
  fail "SSH snapshot list must not call local zfs: $(zfs_log)"
fi

reset_logs
list_snapshots_for_transport local "$DATASET" 0 >/dev/null
grep -q 'zfs list' "$ZFS_LOG" || fail "local snapshot list must call local zfs: $(zfs_log)"
if grep -q 'zfs list' "$SSH_LOG"; then
  fail "local snapshot list must not call ssh: $(ssh_log)"
fi

reset_logs
rollback_snapshot_for_transport ssh "$SNAPSHOT"
grep -q 'zfs rollback' "$SSH_LOG" || fail "SSH rollback must go over ssh: $(ssh_log)"
if grep -q 'zfs rollback' "$ZFS_LOG"; then
  fail "SSH rollback must not call local zfs: $(zfs_log)"
fi

reset_logs
set +e
rollback_snapshot_for_transport local "$SNAPSHOT"
set -e
grep -q 'zfs rollback' "$ZFS_LOG" || fail "local rollback must call local zfs: $(zfs_log)"
if grep -q 'zfs rollback' "$SSH_LOG"; then
  fail "local rollback must not call ssh: $(ssh_log)"
fi

reset_logs
export ZFSAS_SEND_WORKER_AS_LIBRARY=1
# shellcheck source=/dev/null
source "$ROOT_DIR/source/usr/local/sbin/zfs_autosnapshot_send_worker"
SEND_SSH_HOST="kiki.example"
SEND_SSH_PORT="22"
SEND_SSH_USER="root"
SEND_SSH_KEY_PATH="/root/.ssh/id_ed25519"
declare -A job=()
job[JOB_TYPE]="send"
job[SEND_TRANSPORT]="ssh"
SEND_REMOTE_RETRIES_ENABLED=0
purge_destination_for_reseed "$DATASET"
grep -q 'zfs destroy -r' "$SSH_LOG" || fail "SSH reseed must destroy -r over ssh: $(ssh_log)"
if grep -q 'zfs destroy' "$ZFS_LOG"; then
  fail "SSH reseed must not destroy the destination locally: $(zfs_log)"
fi

reset_logs
job[SEND_TRANSPORT]="local"
set +e
purge_destination_for_reseed "$DATASET"
set -e
grep -q 'zfs destroy -r' "$ZFS_LOG" || fail "local reseed must destroy -r locally: $(zfs_log)"
if grep -q 'zfs destroy' "$SSH_LOG"; then
  fail "local reseed must not destroy over ssh: $(ssh_log)"
fi

[[ "$(send_remote_max_attempts)" == "1" ]] || fail "queue path must keep send retries disabled"
SEND_REMOTE_RETRIES_ENABLED=1
[[ "$(send_remote_max_attempts)" == "5" ]] || fail "send worker retries must stay at 5 attempts"
[[ "$(send_remote_retry_delay_seconds)" == "300" ]] || fail "send retry delay must stay at 5 minutes"
send_auto_reseed_enabled || fail "auto reseed must stay enabled"

echo "PASS: destination zfs commands follow the send transport"
