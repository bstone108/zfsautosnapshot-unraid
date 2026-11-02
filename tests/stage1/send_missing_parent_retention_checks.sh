#!/bin/bash
# Destination retention must delete only snapshots a direct listing of that
# dataset returned. A missing or empty parent must not inherit child or source
# checkpoints, and a confirmed-absent destroy is already done.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${ROOT_DIR}/source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/ops-queue-lib.sh"
# shellcheck source=/dev/null
source "$LIB"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

PARENT="storage/Backups/susanoo-cache/appdata"
CHILD="${PARENT}/nginx"
SOURCE="cache/appdata"
SOURCE_CHILD="${SOURCE}/nginx"
OLD="zfs-send-ef8948aa4533-2026-10-01_10-28-04"
NEW="zfs-send-ef8948aa4533-2026-11-02_00-01-46"
SCHEDULE="ef8948aa4533"

setup_tree() {
  local root="$1"
  mkdir -p "${root}/bin" "${root}/ops" "${root}/config" "${root}/persist"
  export ZFS_LOG="${root}/zfs.log"
  export SSH_LOG="${root}/ssh.log"
  : > "$ZFS_LOG"
  : > "$SSH_LOG"
  export PATH="${root}/bin:${PATH}"
  export CONFIG_DIR="${root}/config"
  export SEND_CONFIG_FILE="${root}/config/zfs_send.conf"
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
  SCHEDULE_JOB_IDS=("$SCHEDULE")
  SCHEDULE_SOURCE_ROOT["$SCHEDULE"]="$SOURCE"
  SCHEDULE_DEST_ROOT["$SCHEDULE"]="$PARENT"
  SCHEDULE_INCLUDE_CHILDREN["$SCHEDULE"]="1"
  SCHEDULE_PREFIX["$SCHEDULE"]="zfs-send-${SCHEDULE}-"
  SEND_SNAPSHOT_PREFIX="zfs-send-"
  SEND_KEEP_ALL_FOR_DAYS=0
  SEND_KEEP_DAILY_UNTIL_DAYS=0
  SEND_KEEP_WEEKLY_UNTIL_DAYS=0
}

write_zfs_stub() {
  local mode="$1"
  cat > "${PATH%%:*}/zfs" <<EOF
#!/bin/bash
log="\${ZFS_LOG:?}"
printf 'zfs %s\n' "\$*" >> "\$log"
dataset="\${@: -1}"
args=" \$* "
if [[ "\$1" == "destroy" ]]; then
  echo "cannot open '\${dataset}': dataset does not exist" >&2
  exit 1
fi
if [[ "\$1" == "list" && "\$args" == *" -t snapshot "* ]]; then
  if [[ "\$dataset" == "${PARENT}" && "\$args" == *" -d 1 "* ]]; then
    printf '%s\t%s\n' "${PARENT}@${OLD}" 50
    exit 0
  fi
  if [[ "\$dataset" == "${PARENT}" && "${mode}" == "empty-parent" ]]; then
    exit 0
  fi
  if [[ "\$dataset" == "${CHILD}" ]]; then
    printf '%s\t%s\n' "${CHILD}@${OLD}" 50 "${CHILD}@${NEW}" 300
    exit 0
  fi
  if [[ "\$dataset" == "${SOURCE_CHILD}" ]]; then
    printf '%s\t%s\n' "${SOURCE_CHILD}@${OLD}" 50 "${SOURCE_CHILD}@${NEW}" 300
    exit 0
  fi
  if [[ "\$dataset" == "${SOURCE}" ]]; then
    printf '%s\t%s\n' "${SOURCE}@${OLD}" 50 "${SOURCE}@${NEW}" 300
    exit 0
  fi
  echo "cannot open '\${dataset}': dataset does not exist" >&2
  exit 1
fi
if [[ "\$1" == "list" && "\$args" == *" -r "* ]]; then
  if [[ "\$dataset" == "${SOURCE}" ]]; then
    printf '%s\n' "${SOURCE}" "${SOURCE_CHILD}"
    exit 0
  fi
  if [[ "\$dataset" == "${PARENT}" && "${mode}" == "empty-parent" ]]; then
    printf '%s\n' "${PARENT}" "${CHILD}"
    exit 0
  fi
  echo "cannot open '\${dataset}': dataset does not exist" >&2
  exit 1
fi
if [[ "\$1" == "list" ]]; then
  case "\$dataset" in
    "${SOURCE}"|"${SOURCE_CHILD}"|"${CHILD}") exit 0 ;;
    "${PARENT}")
      if [[ "${mode}" == "empty-parent" ]]; then exit 0; fi
      echo "cannot open '\${dataset}': dataset does not exist" >&2
      exit 1
      ;;
    *) echo "cannot open '\${dataset}': dataset does not exist" >&2; exit 1 ;;
  esac
fi
if [[ "\$1" == "get" ]]; then
  if [[ "\$args" == *" -d 1 "* && "\$dataset" == "${PARENT}" ]]; then
    printf '%s\tcreation\t50\n' "${PARENT}@${OLD}"
    printf '%s\twritten\t10\n' "${PARENT}@${OLD}"
    printf '%s\tuserrefs\t0\n' "${PARENT}@${OLD}"
    printf '%s\tclones\t-\n' "${PARENT}@${OLD}"
    printf '%s\tguid\t9\n' "${PARENT}@${OLD}"
    printf '%s\tcreatetxg\t9\n' "${PARENT}@${OLD}"
    exit 0
  fi
  if [[ "\$dataset" == "${CHILD}" || "\$dataset" == "${SOURCE_CHILD}" || "\$dataset" == "${SOURCE}" ]]; then
    snap_prefix="\$dataset"
    for pair in "${OLD} 50" "${NEW} 300"; do
      set -- \$pair
      printf '%s\tcreation\t%s\n' "\${snap_prefix}@\$1" "\$2"
      printf '%s\twritten\t10\n' "\${snap_prefix}@\$1"
      printf '%s\tuserrefs\t0\n' "\${snap_prefix}@\$1"
      printf '%s\tclones\t-\n' "\${snap_prefix}@\$1"
      printf '%s\tguid\t1\n' "\${snap_prefix}@\$1"
      printf '%s\tcreatetxg\t1\n' "\${snap_prefix}@\$1"
    done
    exit 0
  fi
  if [[ "\$dataset" == "${PARENT}" && "${mode}" == "empty-parent" ]]; then
    exit 0
  fi
  echo "cannot open '\${dataset}': dataset does not exist" >&2
  exit 1
fi
echo "unsupported zfs \$*" >&2
exit 1
EOF
  chmod 755 "${PATH%%:*}/zfs"
}

write_ssh_stub() {
  local mode="$1"
  cat > "${PATH%%:*}/ssh" <<EOF
#!/bin/bash
printf 'ssh %s\n' "\$*" >> "\${SSH_LOG:?}"
remote="\${*: -1}"
dataset="\${remote##* }"
if [[ "\$remote" == *" -d 1 "* && "\$dataset" == "${PARENT}" ]]; then
  printf '%s\tcreation\t50\n' "${PARENT}@${OLD}"
  exit 0
fi
if [[ "\$remote" == *" -t filesystem,volume"* && "\$remote" == *"-r"* ]]; then
  if [[ "${mode}" == "empty-parent" && "\$dataset" == "${PARENT}" ]]; then
    printf '%s\n' "${PARENT}" "${CHILD}"
    exit 0
  fi
  echo "cannot open '\$dataset': dataset does not exist" >&2
  exit 1
fi
if [[ "\$remote" == *"zfs list -H -o name"* ]]; then
  case "\$dataset" in
    "${CHILD}") exit 0 ;;
    "${PARENT}")
      if [[ "${mode}" == "empty-parent" ]]; then exit 0; fi
      echo "cannot open '\$dataset': dataset does not exist" >&2
      exit 1
      ;;
  esac
  echo "cannot open '\$dataset': dataset does not exist" >&2
  exit 1
fi
if [[ "\$remote" == *"zfs get"* && "\$dataset" == "${CHILD}" ]]; then
  for pair in "${OLD} 50" "${NEW} 300"; do
    set -- \$pair
    printf '%s\tcreation\t%s\n' "${CHILD}@\$1" "\$2"
    printf '%s\twritten\t10\n' "${CHILD}@\$1"
    printf '%s\tuserrefs\t0\n' "${CHILD}@\$1"
    printf '%s\tclones\t-\n' "${CHILD}@\$1"
    printf '%s\tguid\t1\n' "${CHILD}@\$1"
    printf '%s\tcreatetxg\t1\n' "${CHILD}@\$1"
  done
  exit 0
fi
if [[ "\$remote" == *"zfs get"* && "\$dataset" == "${PARENT}" && "${mode}" == "empty-parent" ]]; then
  exit 0
fi
if [[ "\$remote" == *"zfs get"* && "\$dataset" == "${PARENT}" && "\$remote" == *" -d 1 "* ]]; then
  printf '%s\tcreation\t50\n' "${PARENT}@${OLD}"
  exit 0
fi
if [[ "\$remote" == *" -t snapshot "* && "\$dataset" == "${PARENT}" && "\$remote" == *" -d 1 "* ]]; then
  printf '%s\t%s\n' "${PARENT}@${OLD}" 50
  exit 0
fi
if [[ "\$remote" == *" -t snapshot "* && "\$dataset" == "${PARENT}" && "${mode}" == "empty-parent" ]]; then
  exit 0
fi
if [[ "\$remote" == *" -t snapshot "* && "\$dataset" == "${CHILD}" ]]; then
  printf '%s\t%s\n' "${CHILD}@${OLD}" 50 "${CHILD}@${NEW}" 300
  exit 0
fi
if [[ "\$remote" == *"zfs get"* && "\$dataset" == "${CHILD}" ]]; then
  for pair in "${OLD} 50" "${NEW} 300"; do
    set -- \$pair
    printf '%s\tcreation\t%s\n' "${CHILD}@\$1" "\$2"
    printf '%s\twritten\t10\n' "${CHILD}@\$1"
    printf '%s\tuserrefs\t0\n' "${CHILD}@\$1"
    printf '%s\tclones\t-\n' "${CHILD}@\$1"
    printf '%s\tguid\t1\n' "${CHILD}@\$1"
    printf '%s\tcreatetxg\t1\n' "${CHILD}@\$1"
  done
  exit 0
fi
if [[ "\$remote" == *"zfs get"* && "\$dataset" == "${PARENT}" && "${mode}" == "empty-parent" ]]; then
  exit 0
fi
echo "cannot open '\$dataset': dataset does not exist" >&2
exit 1
EOF
  chmod 755 "${PATH%%:*}/ssh"
}

assert_not_queued() {
  local inbox="$1"
  local needle="$2"
  local message="$3"
  if [[ -f "$inbox" ]] && grep -Fq "$needle" "$inbox"; then
    printf 'Did not expect %s in:\n%s\n' "$needle" "$(cat "$inbox")" >&2
    fail "$message"
  fi
}

assert_queued() {
  local inbox="$1"
  local needle="$2"
  local message="$3"
  [[ -f "$inbox" ]] || fail "$message (no delete was queued)"
  grep -Fq "$needle" "$inbox" || fail "$message"
}

run_retention() {
  local transport="$1"
  SCHEDULE_TRANSPORT["$SCHEDULE"]="$transport"
  if [[ "$transport" == "ssh" ]]; then
    SEND_SSH_HOST="kiki.example"
    SEND_SSH_PORT="22"
    SEND_SSH_USER="root"
    SEND_SSH_KEY_PATH="/root/.ssh/id_ed25519"
  fi
  clear_send_cleanup_caches
  : > "$LOG_FILE"
  rm -f "$DELETE_QUEUE_INBOX_FILE"
  queue_schedule_retention_cleanup "$SCHEDULE" || true
}

test_retention() {
  local transport="$1"
  local mode="$2"
  local root
  root="$(mktemp -d)"
  setup_tree "$root"
  write_zfs_stub "$mode"
  if [[ "$transport" == "ssh" ]]; then
    write_ssh_stub "$mode"
  fi
  run_retention "$transport"
  assert_not_queued "$DELETE_QUEUE_INBOX_FILE" "${PARENT}@${OLD}" \
    "${transport} ${mode}: retention must not delete a parent checkpoint that was not received"
  assert_queued "$DELETE_QUEUE_INBOX_FILE" "${CHILD}@${OLD}" \
    "${transport} ${mode}: retention must still delete an old checkpoint listed on the received child"
  assert_not_queued "$DELETE_QUEUE_INBOX_FILE" "${CHILD}@${NEW}" \
    "${transport} ${mode}: the newest received child checkpoint stays"
  if grep -Fq "Reseed triggered" "$LOG_FILE" || grep -Fq "Purging destination" "$LOG_FILE"; then
    fail "${transport} ${mode}: a missing parent must not reseed"
  fi
  rm -rf "$root"
  echo "PASS: ${transport} ${mode} retention ignores the missing parent snapshot"
}

test_confirmed_absent_delete_is_done() {
  local root
  root="$(mktemp -d)"
  setup_tree "$root"
  write_zfs_stub "missing-parent"
  local out=""
  if ! out="$(destroy_snapshot_for_transport local "${PARENT}@${OLD}" 2>&1)"; then
    fail "a confirmed-absent snapshot delete must count as already done"
  fi
  destroys="$(grep -c 'zfs destroy' "$ZFS_LOG" || true)"
  [[ "$destroys" == "1" ]] || fail "a confirmed-absent delete must not retry, saw ${destroys} destroy calls"
  [[ "$out" == *"Delete already done"* ]] || fail "an absent delete must say it is already done"
  rm -rf "$root"
  echo "PASS: confirmed-absent delete is already done"
}

test_failed_listing_does_not_delete_or_reseed() {
  local root
  root="$(mktemp -d)"
  setup_tree "$root"
  write_zfs_stub "missing-parent"
  cat > "${PATH%%:*}/zfs" <<EOF
#!/bin/bash
printf 'zfs %s\n' "\$*" >> "\${ZFS_LOG:?}"
dataset="\${@: -1}"
args=" \$* "
if [[ "\$1" == "list" && "\$args" != *" -t snapshot "* && "\$args" != *" -r "* ]]; then
  case "\$dataset" in
    "${SOURCE}"|"${SOURCE_CHILD}"|"${CHILD}") exit 0 ;;
  esac
  echo "cannot open '\$dataset': dataset does not exist" >&2
  exit 1
fi
if [[ "\$1" == "list" && "\$args" == *" -r "* && "\$dataset" == "${SOURCE}" ]]; then
  printf '%s\n' "${SOURCE}" "${SOURCE_CHILD}"
  exit 0
fi
if [[ "\$1" == "list" && "\$args" == *" -t snapshot "* ]]; then
  if [[ "\$dataset" == "${CHILD}" || "\$dataset" == "${SOURCE_CHILD}" || "\$dataset" == "${SOURCE}" ]]; then
    printf '%s\t%s\n' "\${dataset}@${OLD}" 50 "\${dataset}@${NEW}" 300
    exit 0
  fi
  echo "cannot open '\$dataset': dataset does not exist" >&2
  exit 1
fi
if [[ "\$1" == "get" ]]; then
  echo "temporary lookup failure" >&2
  exit 1
fi
exit 1
EOF
  chmod 755 "${PATH%%:*}/zfs"
  local out=""
  SCHEDULE_TRANSPORT["$SCHEDULE"]="local"
  clear_send_cleanup_caches
  rm -f "$DELETE_QUEUE_INBOX_FILE"
  out="$(queue_schedule_retention_cleanup "$SCHEDULE" 2>&1 || true)"
  assert_not_queued "$DELETE_QUEUE_INBOX_FILE" "${CHILD}@" \
    "a failed snapshot listing must not queue destination deletes"
  assert_not_queued "$DELETE_QUEUE_INBOX_FILE" "${PARENT}@" \
    "a failed snapshot listing must not invent a parent delete"
  if [[ "$out" == *"Reseed triggered"* || "$out" == *"Purging destination"* ]]; then
    fail "a failed snapshot listing must not reseed"
  fi
  [[ "$out" == *"not queueing deletes or a reseed"* ]] || fail "a failed listing must say deletes and reseed were skipped"
  rm -rf "$root"
  echo "PASS: failed listing does not delete or reseed"
}

test_retention local missing-parent
test_retention local empty-parent
test_retention ssh missing-parent
test_retention ssh empty-parent
test_confirmed_absent_delete_is_done
test_failed_listing_does_not_delete_or_reseed
