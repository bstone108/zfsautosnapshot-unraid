#!/bin/bash
# One retention pass on a recursive SSH job must queue every stale checkpoint
# on the parent and on each child, including destination-only checkpoints.
# The ssh stub consumes stdin the way OpenSSH does when -n is absent, so a
# while-read loop that shares stdin with ssh fails this test instead of
# queueing only the first delete.
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
S1="${PREFIX}2026-10-26_01-00-00"
S2="${PREFIX}2026-10-27_01-00-00"
S3="${PREFIX}2026-10-28_01-00-00"
S4="${PREFIX}2026-10-29_01-00-00"
S5="${PREFIX}2026-10-30_01-00-00"
S6="${PREFIX}2026-10-31_01-00-00"
SHARED="${PREFIX}2026-11-01_01-00-00"
NEWEST="${PREFIX}2026-11-05_12-40-56"
NOW="$(date +%s)"
E1=$((NOW - 10 * 86400))
E2=$((NOW - 9 * 86400))
E3=$((NOW - 8 * 86400))
E4=$((NOW - 7 * 86400))
E5=$((NOW - 6 * 86400))
E6=$((NOW - 5 * 86400))
ESHARED=$((NOW - 4 * 86400))
ENEWEST=$((NOW - 60))
STALE_NAMES=("$S1" "$S2" "$S3" "$S4" "$S5" "$S6" "$SHARED")

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
  SEND_DESTINATION_DATASETS_BY_SCHEDULE=()
  SEND_DESTINATION_DATASETS_BY_POOL=()
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
      printf '%s\t%s\n' \\
        "\${dataset}@${SHARED}" "${ESHARED}" \\
        "\${dataset}@${NEWEST}" "${ENEWEST}"
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
      for pair in "${SHARED} ${ESHARED}" "${NEWEST} ${ENEWEST}"; do
        set -- \$pair
        snap="\${target}@\$1"
        printf '%s\tcreation\t%s\n' "\$snap" "\$2"
        printf '%s\twritten\t10\n' "\$snap"
        printf '%s\tuserrefs\t0\n' "\$snap"
        printf '%s\tclones\t-\n' "\$snap"
        printf '%s\tguid\t1\n' "\$snap"
        printf '%s\tcreatetxg\t1\n' "\$snap"
      done
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
# OpenSSH reads the caller's stdin unless -n is set. Drain it so a while-read
# loop cannot hide a missing -n. A tty is left alone so a local run does not block.
if [[ " \$* " != *" -n "* ]] && [[ ! -t 0 ]]; then
  cat >/dev/null || true
fi
remote="\${*: -1}"
remote="\${remote% 2>/dev/null}"
dataset="\${remote##* }"
dataset="\${dataset//\'/}"
emit_get() {
  local ds="\$1"
  local snap pair
  for pair in "${S1} ${E1}" "${S2} ${E2}" "${S3} ${E3}" "${S4} ${E4}" "${S5} ${E5}" "${S6} ${E6}" "${SHARED} ${ESHARED}" "${NEWEST} ${ENEWEST}"; do
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
      printf '%s\t%s\n' \\
        "\${dataset}@${S1}" "${E1}" \\
        "\${dataset}@${S2}" "${E2}" \\
        "\${dataset}@${S3}" "${E3}" \\
        "\${dataset}@${S4}" "${E4}" \\
        "\${dataset}@${S5}" "${E5}" \\
        "\${dataset}@${S6}" "${E6}" \\
        "\${dataset}@${SHARED}" "${ESHARED}" \\
        "\${dataset}@${NEWEST}" "${ENEWEST}"
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

assert_queued_once() {
  local needle="$1"
  local message="$2"
  local count
  [[ -f "$DELETE_QUEUE_INBOX_FILE" ]] || fail "$message (no delete was queued)"
  count="$(grep -F -c "$needle" "$DELETE_QUEUE_INBOX_FILE" || true)"
  [[ "$count" == "1" ]] || fail "$message (queued ${count} times)"
  grep -Fq $'destination_checkpoint\t'"${SCHEDULE}" "$DELETE_QUEUE_INBOX_FILE" || fail "$message (delete scope is not destination_checkpoint)"
}

assert_not_queued() {
  local needle="$1"
  local message="$2"
  if [[ -f "$DELETE_QUEUE_INBOX_FILE" ]] && grep -Fq "$needle" "$DELETE_QUEUE_INBOX_FILE"; then
    fail "$message"
  fi
}

assert_remote_listing_uses_ssh_n() {
  if grep -Fq "destroy" "$ZFS_LOG"; then
    fail "destination retention ran a local zfs destroy"
  fi
  if grep -E "LOCAL .*${PARENT}" "$ZFS_LOG" | grep -q "get"; then
    fail "destination snapshot metadata was read with local zfs"
  fi
  grep -Fq "zfs get" "$SSH_LOG" || fail "destination snapshots were not listed over SSH"
  grep -F " -n " "$SSH_LOG" | grep -Fq "zfs " || fail "non-streaming ssh did not pass -n, so it can drain a read loop"
}

assert_all_stales() {
  local label="$1"
  local dataset
  local stale
  for dataset in "$PARENT" "$CHILD1" "$CHILD2"; do
    for stale in "${STALE_NAMES[@]}"; do
      assert_queued_once "${dataset}@${stale}" "${label}: ${dataset}@${stale} must be queued once"
    done
    assert_not_queued "${dataset}@${NEWEST}" "${label}: newest common checkpoint on ${dataset} must stay"
  done
  assert_not_queued $'\t'"${SOURCE}@" "${label}: source checkpoints must not be queued for deletion"
  assert_remote_listing_uses_ssh_n
}

run_schedule_pass() {
  local root
  root="$(mktemp -d)"
  setup_tree "$root"
  write_stubs "parent-only"
  # One call. A stdin-draining ssh used to leave every stale checkpoint except
  # about one per dataset, and a parent-only inventory used to hide children.
  queue_schedule_retention_cleanup "$SCHEDULE" || true
  assert_all_stales "single schedule pass"
  rm -rf "$root"
  echo "PASS: single schedule pass queued every stale checkpoint"
}

run_post_send_pass() {
  local root stale
  root="$(mktemp -d)"
  setup_tree "$root"
  write_stubs "full-tree"
  queue_schedule_post_send_cleanup_for_dataset "$SCHEDULE" "$PARENT" "$NEWEST" || true
  for stale in "${STALE_NAMES[@]}"; do
    assert_queued_once "${PARENT}@${stale}" "single post-send pass: ${PARENT}@${stale} must be queued once"
  done
  assert_not_queued "${PARENT}@${NEWEST}" "single post-send pass: newest common parent checkpoint must stay"
  assert_not_queued "${CHILD1}@" "single post-send pass: parent cleanup must not invent child deletes"
  assert_not_queued $'\t'"${SOURCE}@" "single post-send pass: source checkpoints must not be queued"
  assert_remote_listing_uses_ssh_n
  rm -rf "$root"
  echo "PASS: single post-send pass queued every stale parent checkpoint"
}

SEND_SSH_HOST="kiki.example"
SEND_SSH_PORT="22"
SEND_SSH_USER="root"
SEND_SSH_KEY_PATH="/root/.ssh/id_ed25519"
query_command=""
build_ssh_zfs_command "zfs list -H -o name -- ${PARENT}" query_command || fail "query ssh command should build"
[[ "$query_command" == *" -n "* ]] || fail "query ssh must pass -n so it does not read the caller's stdin"
receive_command=""
build_ssh_receive_command "$PARENT" receive_command || fail "receive ssh command should build"
[[ "$receive_command" != *" -n "* ]] || fail "receive ssh must keep stdin for the zfs send stream"

run_schedule_pass
run_post_send_pass
