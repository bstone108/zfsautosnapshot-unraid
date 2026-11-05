#!/bin/bash
# Recursive SSH destination retention must prune stale send checkpoints on the
# parent and on every child, including checkpoints that exist only on the
# destination. A recursive inventory that returns only the parent must not hide
# those children. Post-send cleanup must do the same retention pass: zero-change
# cleanup alone leaves send checkpoints in place. The newest common checkpoint
# stays, and nothing is destroyed on the source or with a local zfs command
# against the destination.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${ROOT_DIR}/source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/ops-queue-lib.sh"
# shellcheck source=/dev/null
source "$LIB"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

PARENT="storage/Backups/neko-cache/grokbot-retention-test"
CHILD1="${PARENT}/child1"
CHILD2="${PARENT}/child2"
SOURCE="cache/grokbot-retention-test"
SOURCE1="${SOURCE}/child1"
SOURCE2="${SOURCE}/child2"
SCHEDULE="c4e2f1a7b305"
PREFIX="zfs-send-${SCHEDULE}-"
OLD="${PREFIX}2026-11-04_10-48-05"
NEWEST="${PREFIX}2026-11-05_12-40-56"
NOW="$(date +%s)"
OLD_EPOCH=$((NOW - 3 * 86400))
NEWEST_EPOCH=$((NOW - 60))

setup_tree() {
  local root="$1"
  mkdir -p "${root}/bin" "${root}/ops/jobs" "${root}/ops/status" "${root}/config" "${root}/persist"
  export ZFS_LOG="${root}/zfs.log"
  export SSH_LOG="${root}/ssh.log"
  : > "$ZFS_LOG"
  : > "$SSH_LOG"
  export PATH="${root}/bin:${PATH}"
  export CONFIG_DIR="${root}/config"
  export SEND_CONFIG_FILE="${root}/config/zfs_send.conf"
  : > "$SEND_CONFIG_FILE"
  export OPS_ROOT="${root}/ops"
  export OPS_JOBS_DIR="${root}/ops/jobs"
  export OPS_STATUS_DIR="${root}/ops/status"
  export DELETE_QUEUE_STATE_FILE="${root}/ops/status/delete-queue.state"
  export DELETE_QUEUE_INBOX_FILE="${root}/ops/delete-queue.inbox"
  export DELETE_QUEUE_INBOX_LOCK_FILE="${root}/ops/delete-queue.inbox.lock"
  export PERSISTED_QUEUE_DIR="${root}/persist"
  export PERSISTED_DELETE_QUEUE_FILE="${root}/persist/delete-queue.persist"
  export LOG_FILE="${root}/send.log"
  : > "$LOG_FILE"
  export RUNTIME_DIR="${root}/run"
  mkdir -p "$RUNTIME_DIR"
  rm -f "$DELETE_QUEUE_INBOX_FILE"

  SCHEDULE_JOB_IDS=("$SCHEDULE")
  SCHEDULE_SOURCE_ROOT["$SCHEDULE"]="$SOURCE"
  SCHEDULE_DEST_ROOT["$SCHEDULE"]="$PARENT"
  SCHEDULE_INCLUDE_CHILDREN["$SCHEDULE"]="1"
  SCHEDULE_PREFIX["$SCHEDULE"]="$PREFIX"
  SCHEDULE_TRANSPORT["$SCHEDULE"]="ssh"
  SCHEDULE_THRESHOLD_BYTES["$SCHEDULE"]=0
  SEND_SNAPSHOT_PREFIX="zfs-send-"
  SEND_KEEP_ALL_FOR_DAYS=0
  SEND_KEEP_DAILY_UNTIL_DAYS=0
  SEND_KEEP_WEEKLY_UNTIL_DAYS=0
  SEND_SSH_HOST="kiki.example"
  SEND_SSH_PORT="22"
  SEND_SSH_USER="root"
  SEND_SSH_KEY_PATH="/root/.ssh/id_ed25519"
  SEND_REMOTE_RETRIES_ENABLED=0
  clear_send_cleanup_caches
}

write_stubs() {
  local inventory_mode="$1"
  cat > "${PATH%%:*}/zfs" <<EOF
#!/bin/bash
printf 'LOCAL %s\n' "\$*" >> "\${ZFS_LOG:?}"
dataset="\${@: -1}"
args=" \$* "
if [[ "\$1" == "destroy" ]]; then
  echo "local destroy \${dataset}" >> "\${ZFS_LOG:?}"
  exit 0
fi
if [[ "\$1" == "list" && "\$args" == *" -r "* && "\$args" != *" -t snapshot "* ]]; then
  if [[ "\$dataset" == "${SOURCE}" ]]; then
    printf '%s\n' "${SOURCE}" "${SOURCE1}" "${SOURCE2}"
    exit 0
  fi
fi
if [[ "\$1" == "list" && "\$args" == *" -t snapshot "* ]]; then
  case "\$dataset" in
    "${SOURCE}"|"${SOURCE1}"|"${SOURCE2}")
      printf '%s\t%s\n' "\${dataset}@${NEWEST}" "${NEWEST_EPOCH}"
      exit 0
      ;;
  esac
  echo "cannot open '\${dataset}': dataset does not exist" >&2
  exit 1
fi
if [[ "\$1" == "get" && "\$args" == *" -t snapshot "* ]]; then
  target="\$dataset"
  [[ "\$target" == *"@"* ]] && target="\${target%@*}"
  case "\$target" in
    "${SOURCE}"|"${SOURCE1}"|"${SOURCE2}")
      snap="\${target}@${NEWEST}"
      printf '%s\tcreation\t%s\n' "\$snap" "${NEWEST_EPOCH}"
      printf '%s\twritten\t10\n' "\$snap"
      printf '%s\tuserrefs\t0\n' "\$snap"
      printf '%s\tclones\t-\n' "\$snap"
      printf '%s\tguid\t1\n' "\$snap"
      printf '%s\tcreatetxg\t1\n' "\$snap"
      exit 0
      ;;
  esac
  echo "cannot open '\${target}': dataset does not exist" >&2
  exit 1
fi
if [[ "\$1" == "list" ]]; then
  case "\$dataset" in
    "${SOURCE}"|"${SOURCE1}"|"${SOURCE2}") exit 0 ;;
  esac
  echo "cannot open '\${dataset}': dataset does not exist" >&2
  exit 1
fi
echo "unsupported local zfs \$*" >&2
exit 1
EOF
  cat > "${PATH%%:*}/ssh" <<EOF
#!/bin/bash
printf 'SSH %s\n' "\$*" >> "\${SSH_LOG:?}"
remote="\${*: -1}"
remote="\${remote% 2>/dev/null}"
dataset="\${remote##* }"
dataset="\${dataset//\'/}"
emit_get() {
  local ds="\$1"
  local snap
  for pair in "${OLD} ${OLD_EPOCH}" "${NEWEST} ${NEWEST_EPOCH}"; do
    set -- \$pair
    snap="\${ds}@\$1"
    printf '%s\tcreation\t%s\n' "\$snap" "\$2"
    printf '%s\twritten\t10\n' "\$snap"
    printf '%s\tuserrefs\t0\n' "\$snap"
    printf '%s\tclones\t-\n' "\$snap"
    printf '%s\tguid\t7\n' "\$snap"
    printf '%s\tcreatetxg\t7\n' "\$snap"
  done
}
if [[ "\$remote" == *"zfs destroy"* ]]; then
  echo "remote destroy must not run during queueing: \$remote" >> "\${SSH_LOG:?}"
  exit 1
fi
if [[ "\$remote" == *" -t filesystem,volume"* ]]; then
  if [[ "${inventory_mode}" == "parent-only" ]]; then
    printf '%s\n' "${PARENT}"
    exit 0
  fi
  printf '%s\n' "${PARENT}" "${CHILD1}" "${CHILD2}"
  exit 0
fi
if [[ "\$remote" == *"zfs list -H -o name"* && "\$remote" != *" -t snapshot "* ]]; then
  case "\$dataset" in
    "${PARENT}"|"${CHILD1}"|"${CHILD2}") exit 0 ;;
  esac
  echo "cannot open '\$dataset': dataset does not exist" >&2
  exit 1
fi
if [[ "\$remote" == *"zfs get"* && "\$remote" == *" -t snapshot "* ]]; then
  case "\$dataset" in
    "${PARENT}"|"${CHILD1}"|"${CHILD2}")
      emit_get "\$dataset"
      exit 0
      ;;
  esac
  echo "cannot open '\$dataset': dataset does not exist" >&2
  exit 1
fi
if [[ "\$remote" == *" -t snapshot "* ]]; then
  case "\$dataset" in
    "${PARENT}"|"${CHILD1}"|"${CHILD2}")
      printf '%s\t%s\n' "\${dataset}@${OLD}" "${OLD_EPOCH}" "\${dataset}@${NEWEST}" "${NEWEST_EPOCH}"
      exit 0
      ;;
  esac
  echo "cannot open '\$dataset': dataset does not exist" >&2
  exit 1
fi
echo "unsupported ssh [\$remote]" >&2
exit 1
EOF
  chmod 755 "${PATH%%:*}/zfs" "${PATH%%:*}/ssh"
}

assert_queued() {
  local needle="$1"
  local message="$2"
  [[ -f "$DELETE_QUEUE_INBOX_FILE" ]] || fail "$message (no delete was queued)"
  grep -Fq "$needle" "$DELETE_QUEUE_INBOX_FILE" || fail "$message"
  grep -Fq $'destination_checkpoint\t'"${SCHEDULE}" "$DELETE_QUEUE_INBOX_FILE" || fail "$message (delete scope is not destination_checkpoint)"
}

assert_not_queued() {
  local needle="$1"
  local message="$2"
  if [[ -f "$DELETE_QUEUE_INBOX_FILE" ]] && grep -Fq "$needle" "$DELETE_QUEUE_INBOX_FILE"; then
    fail "$message"
  fi
}

assert_remote_only() {
  if grep -Fq "destroy" "$ZFS_LOG"; then
    fail "destination retention ran a local zfs destroy"
  fi
  if grep -E "LOCAL .*${PARENT}" "$ZFS_LOG" | grep -q "get"; then
    fail "destination snapshot metadata was read with local zfs"
  fi
  grep -Fq "zfs get" "$SSH_LOG" || fail "destination snapshots were not listed over SSH"
}

run_case() {
  local label="$1"
  local mode="$2"
  local root
  root="$(mktemp -d)"
  setup_tree "$root"
  write_stubs "$mode"
  if [[ "$label" == "post-send" ]]; then
    queue_schedule_post_send_cleanup_for_dataset "$SCHEDULE" "$PARENT" "$NEWEST" || true
    queue_schedule_post_send_cleanup_for_dataset "$SCHEDULE" "$CHILD1" "$NEWEST" || true
    queue_schedule_post_send_cleanup_for_dataset "$SCHEDULE" "$CHILD2" "$NEWEST" || true
  else
    queue_schedule_retention_cleanup "$SCHEDULE" || true
  fi
  assert_queued "${PARENT}@${OLD}" "${label}: parent destination-only checkpoint must be queued"
  assert_queued "${CHILD1}@${OLD}" "${label}: child1 destination-only checkpoint must be queued"
  assert_queued "${CHILD2}@${OLD}" "${label}: child2 destination-only checkpoint must be queued"
  assert_not_queued "${PARENT}@${NEWEST}" "${label}: newest common parent checkpoint must stay"
  assert_not_queued "${CHILD1}@${NEWEST}" "${label}: newest common child1 checkpoint must stay"
  assert_not_queued "${CHILD2}@${NEWEST}" "${label}: newest common child2 checkpoint must stay"
  assert_not_queued $'\t'"${SOURCE}@" "${label}: source checkpoints must not be queued for deletion"
  assert_remote_only
  rm -rf "$root"
  echo "PASS: ${label}"
}

run_case "partial-inventory" "parent-only"
run_case "post-send" "full-tree"
