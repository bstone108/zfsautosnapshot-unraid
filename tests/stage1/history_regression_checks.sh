#!/bin/bash
# Older fixes that stage1 did not execute directly:
# - low-space oldest-snapshot selection must not die with SIGPIPE
# - cron.d lines stay in BusyBox format (no username column) and always include the queue kicker
# - the delete-worker helper stays defined where it is called
# - the migrator does not parse array status through a printf pipe
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AUTOSNAPSHOT="${ROOT_DIR}/source/usr/local/sbin/zfs_autosnapshot"
SYNC_CRON="${ROOT_DIR}/source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/sync-cron.sh"
OPS_LIB="${ROOT_DIR}/source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/ops-queue-lib.sh"
SEND_WORKER="${ROOT_DIR}/source/usr/local/sbin/zfs_autosnapshot_send_worker"
MIGRATE="${ROOT_DIR}/source/usr/local/sbin/zfs_autosnapshot_migrate_datasets"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zfsas-history.XXXXXX")"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

extract_pick_oldest() {
  awk '
    $0 ~ /^pick_oldest_snapshot\(\)/ { capture = 1 }
    capture { print }
    capture && $0 ~ /^}$/ { exit }
  ' "$AUTOSNAPSHOT"
}

test_pick_oldest_survives_pipefail() {
  local fn_file="${TEST_ROOT}/pick_oldest.sh"
  local lines result
  extract_pick_oldest >"$fn_file"
  [[ -s "$fn_file" ]] || fail "pick_oldest_snapshot was not found in zfs_autosnapshot"
  if grep -v '^[[:space:]]*#' "$fn_file" | grep -Eq 'sort[^|]*\|[[:space:]]*head'; then
    fail "pick_oldest_snapshot must not use sort|head; that exits 141 under pipefail"
  fi
  python3 - <<PY
lines = []
for i in range(100000):
    lines.append(f"tank/data@newer-{i}\t{1000000 + i}")
lines.insert(50000, "tank/data@oldest\t10")
open("${TEST_ROOT}/snapshots.tsv", "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY
  result="$(
    LINES_FILE="${TEST_ROOT}/snapshots.tsv" bash -c '
      set -Eeuo pipefail
      source "$1"
      pick_oldest_snapshot "$(cat "$LINES_FILE")"
    ' bash "$fn_file"
  )" || fail "pick_oldest_snapshot failed under pipefail"
  [[ "$result" == "tank/data@oldest" ]] || fail "pick_oldest_snapshot chose ${result:-<empty>} instead of the oldest snapshot"
  echo "PASS: oldest snapshot selection survives pipefail"
}

write_main_config() {
  local dir="$1"
  local body="$2"
  mkdir -p "$dir"
  printf '%s\n' "$body" >"${dir}/zfs_autosnapshot.conf"
}

run_sync_cron() {
  local dir="$1"
  local cron_file="$2"
  ZFSAS_CRON_CONFIG_DIR="$dir" \
  ZFSAS_CRON_FILE="$cron_file" \
    bash "$SYNC_CRON"
}

assert_busybox_cron_line() {
  local line="$1"
  local command="$2"
  local message="$3"
  local sixth
  sixth="$(awk '{print $6}' <<<"$line")"
  [[ "$sixth" == "$command" ]] || fail "$message (field 6 was ${sixth:-<empty>} in: $line)"
  if [[ "$line" == *" root "* ]]; then
    fail "$message includes a username column"
  fi
}

test_cron_file_is_busybox_format() {
  local dir="${TEST_ROOT}/cron-daily"
  local cron_file="${dir}/cron"
  local output line
  write_main_config "$dir" $'SCHEDULE_MODE="daily"\nSCHEDULE_DAILY_HOUR="3"\nSCHEDULE_DAILY_MINUTE="15"'
  output="$(run_sync_cron "$dir" "$cron_file")"
  [[ -f "$cron_file" ]] || fail "sync-cron did not write the cron file"
  line="$(grep -F '/usr/local/sbin/zfs_autosnapshot ' "$cron_file" || true)"
  assert_busybox_cron_line "$line" "/usr/local/sbin/zfs_autosnapshot" "daily autosnapshot cron line must be 5 schedule fields plus the command"
  [[ "$line" == "15 3 * * * /usr/local/sbin/zfs_autosnapshot "* ]] || fail "daily schedule was not 15 3 * * *: $line"
  line="$(grep -F '/usr/local/sbin/zfs_autosnapshot_queue_kicker' "$cron_file" || true)"
  assert_busybox_cron_line "$line" "/usr/local/sbin/zfs_autosnapshot_queue_kicker" "queue kicker cron line must not have a username column"
  [[ "$line" == "* * * * * /usr/local/sbin/zfs_autosnapshot_queue_kicker "* ]] || fail "queue kicker must run every minute: $line"
  [[ "$output" == *"Cron schedule applied: 15 3 * * *"* ]] || fail "sync-cron did not report the applied schedule: $output"

  dir="${TEST_ROOT}/cron-disabled"
  cron_file="${dir}/cron"
  write_main_config "$dir" 'SCHEDULE_MODE="disabled"'
  run_sync_cron "$dir" "$cron_file" >/dev/null
  if grep -F '/usr/local/sbin/zfs_autosnapshot ' "${cron_file}" | grep -vq kicker; then
    fail "a disabled main schedule must not keep an autosnapshot cron line"
  fi
  grep -Fq '/usr/local/sbin/zfs_autosnapshot_queue_kicker' "$cron_file" || fail "a disabled main schedule must still install the queue kicker"

  dir="${TEST_ROOT}/cron-bad"
  cron_file="${dir}/cron"
  write_main_config "$dir" $'SCHEDULE_MODE="custom"\nCUSTOM_CRON_SCHEDULE="* * * * * root"'
  if run_sync_cron "$dir" "$cron_file" >"${dir}/out" 2>"${dir}/err"; then
    fail "a custom cron schedule with a username field must be rejected"
  fi
  [[ ! -e "$cron_file" ]] || fail "a rejected cron schedule must not replace the cron file"
  echo "PASS: cron file stays in BusyBox format"
}

test_delete_worker_helper_is_defined() {
  if ! grep -Fq 'ensure_delete_worker_for_backlog() {' "$OPS_LIB"; then
    fail "ops-queue-lib must define ensure_delete_worker_for_backlog"
  fi
  if ! grep -Fq 'ensure_delete_worker_for_backlog() {' "$SEND_WORKER"; then
    fail "send worker must define ensure_delete_worker_for_backlog before calling it"
  fi
  if grep -Fq 'printf '"'"'%s\n'"'"' "$status_text" | extract_status_value' "$MIGRATE"; then
    fail "dataset migrator must not parse array status through a printf pipe"
  fi
  echo "PASS: delete-worker helper and migrator status parsing"
}

test_pick_oldest_survives_pipefail
test_cron_file_is_busybox_format
test_delete_worker_helper_is_defined
