#!/bin/bash
# The version-change sweep removes leftover upgrade residue once per installed
# version. An unchanged version is a no-op, a failed step is retried, and two
# overlapping runs cannot record a version until the cleanup actually finishes.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${ROOT_DIR}/source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/upgrade-migration.sh"
POST_INSTALL="${ROOT_DIR}/source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/post-install.sh"
PRE_REMOVE="${ROOT_DIR}/source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/pre-remove.sh"
SNAPSHOT="${ROOT_DIR}/source/usr/local/sbin/zfs_autosnapshot"
KICKER="${ROOT_DIR}/source/usr/local/sbin/zfs_autosnapshot_queue_kicker"
DISKS_MOUNTED="${ROOT_DIR}/source/usr/local/emhttp/plugins/zfs.autosnapshot/event/disks_mounted"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zfsas-upgrade-migration.XXXXXX")"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq "$needle" "$file"; then
    echo "Expected to find: $needle" >&2
    echo "In file: $file" >&2
    sed -n '1,200p' "$file" >&2 || true
    fail "assert_file_contains failed"
  fi
}

assert_file_not_contains() {
  local file="$1"
  local needle="$2"
  if [[ -f "$file" ]] && grep -Fq "$needle" "$file"; then
    echo "Did not expect to find: $needle" >&2
    echo "In file: $file" >&2
    sed -n '1,200p' "$file" >&2 || true
    fail "assert_file_not_contains failed"
  fi
}

BOOT="${TEST_ROOT}/boot/zfs.autosnapshot"
PLUGIN="${TEST_ROOT}/plugin/zfs.autosnapshot"
SBIN="${TEST_ROOT}/sbin"
PKGDB="${TEST_ROOT}/packages"
MANIFEST="${TEST_ROOT}/missing.plg"
LOG="${TEST_ROOT}/plugin.log"
VERSION_FILE="${BOOT}/last-migrated-version"
LOCK="${TEST_ROOT}/run/upgrade-migration.lock"
FLAG_DIR="${TEST_ROOT}/flags"
LIVE_QUEUE="${TEST_ROOT}/live-queue"
ACTIVE_MARKER="${TEST_ROOT}/run/zfs_autosnapshot.active"
MOCKBIN="${TEST_ROOT}/mockbin"
INSTALLED_VERSION="2026.11.13.t01"

mkdir -p "$BOOT" "$PLUGIN/php" "$SBIN" "$PKGDB" "$FLAG_DIR" "$LIVE_QUEUE/jobs" "$TEST_ROOT/run" "$MOCKBIN"

cat >"${MOCKBIN}/rm" <<'EOF'
#!/bin/bash
set -euo pipefail
flag_dir="${ZFSAS_TEST_FLAG_DIR:-}"
for arg in "$@"; do
  case "$arg" in
    */ops_queue | */ops_queue/)
      if [[ -n "$flag_dir" && -f "${flag_dir}/fail-ops-queue" ]]; then
        echo "mock rm refusing ${arg}" >&2
        exit 1
      fi
      if [[ -n "$flag_dir" && -f "${flag_dir}/delay-ops-queue" ]]; then
        sleep "$(tr -d '[:space:]' <"${flag_dir}/delay-ops-queue")"
      fi
      ;;
  esac
done
exec /bin/rm "$@"
EOF
cat >"${MOCKBIN}/zfs" <<'EOF'
#!/bin/bash
flag_dir="${ZFSAS_TEST_FLAG_DIR:-}"
if [[ -n "$flag_dir" ]]; then
  printf '%s\n' "$*" >>"${flag_dir}/zfs-called"
fi
exit 99
EOF
chmod +x "${MOCKBIN}/rm" "${MOCKBIN}/zfs"

invoke() {
  env -u ZFSAS_INSTALLED_VERSION \
    ZFSAS_BOOT_PLUGIN_DIR="$BOOT" \
    ZFSAS_PLUGIN_DIR="$PLUGIN" \
    ZFSAS_SBIN_DIR="$SBIN" \
    ZFSAS_MIGRATION_LOG_FILE="$LOG" \
    ZFSAS_MIGRATION_VERSION_FILE="$VERSION_FILE" \
    ZFSAS_MIGRATION_LOCK_FILE="$LOCK" \
    ZFSAS_PACKAGE_DB_DIR="$PKGDB" \
    ZFSAS_PLUGIN_MANIFEST="$MANIFEST" \
    ZFSAS_BOOT_PLUGIN_MANIFEST="${TEST_ROOT}/missing-boot.plg" \
    ZFSAS_TEST_FLAG_DIR="$FLAG_DIR" \
    PATH="${MOCKBIN}:${PATH}" \
    "$@" \
    "$SCRIPT"
}

reset_tree() {
  rm -rf "$BOOT" "$PLUGIN" "$SBIN" "$PKGDB" "$LIVE_QUEUE" "$FLAG_DIR" "$LOG" "$LOCK" "$ACTIVE_MARKER"
  mkdir -p \
    "$BOOT/runtime_queue" \
    "$BOOT/dataset_migrator" \
    "$PLUGIN/php" \
    "$SBIN" \
    "$PKGDB" \
    "$LIVE_QUEUE/jobs" \
    "$FLAG_DIR" \
    "$(dirname "$ACTIVE_MARKER")"
  printf '%s\n' 'DATASETS="tank/data:100G"' >"${BOOT}/zfs_autosnapshot.conf"
  printf '%s\n' 'SEND_JOBS=""' >"${BOOT}/zfs_send.conf"
  printf '%s\n' 'queued-job' >"${BOOT}/runtime_queue/delete-queue.persist"
  printf '%s\n' 'recovery=1' >"${BOOT}/dataset_migrator/recovery.env"
  printf '%s\n' 'tank/data@autosnapshot-held' >"${BOOT}/snapshot_leases.tsv"
  printf '%s\n' 'cron-marker' >"${BOOT}/schedule.marker"
  printf '%s\n' 'live-job' >"${LIVE_QUEUE}/jobs/job1"
  printf '%s\n' 'active' >"$ACTIVE_MARKER"
  printf '%s\n' '<?php echo "settings";' >"${PLUGIN}/php/settings.php"
  : >"${FLAG_DIR}/zfs-called"
  rm -f "$LOG"
}

assert_user_state_unchanged() {
  [[ "$(cat "${BOOT}/zfs_autosnapshot.conf")" == 'DATASETS="tank/data:100G"' ]] || fail "snapshot config changed"
  [[ "$(cat "${BOOT}/zfs_send.conf")" == 'SEND_JOBS=""' ]] || fail "send config changed"
  [[ "$(cat "${BOOT}/runtime_queue/delete-queue.persist")" == "queued-job" ]] || fail "queued job changed"
  [[ "$(cat "${BOOT}/dataset_migrator/recovery.env")" == "recovery=1" ]] || fail "migrator recovery state changed"
  [[ "$(cat "${BOOT}/snapshot_leases.tsv")" == "tank/data@autosnapshot-held" ]] || fail "snapshot lease changed"
  [[ "$(cat "${BOOT}/schedule.marker")" == "cron-marker" ]] || fail "schedule marker changed"
  [[ "$(cat "${LIVE_QUEUE}/jobs/job1")" == "live-job" ]] || fail "live queue job changed"
  [[ "$(cat "$ACTIVE_MARKER")" == "active" ]] || fail "active marker changed"
  [[ -f "${PLUGIN}/php/settings.php" ]] || fail "plugin settings file was removed"
  if [[ -s "${FLAG_DIR}/zfs-called" ]]; then
    echo "zfs was invoked:" >&2
    cat "${FLAG_DIR}/zfs-called" >&2
    fail "upgrade cleanup invoked zfs"
  fi
}

assert_hooks() {
  assert_file_contains "$SNAPSHOT" "zfsas_run_upgrade_migration"
  assert_file_contains "$KICKER" "zfsas_run_upgrade_migration"
  assert_file_contains "$DISKS_MOUNTED" "zfsas_run_upgrade_migration"
  assert_file_contains "$POST_INSTALL" "zfsas_migration_remove_legacy_ops_queue"
  assert_file_contains "$POST_INSTALL" "zfsas_migration_remove_stale_recovery_files"
  assert_file_contains "$POST_INSTALL" "zfsas_migration_remove_appledouble"
  assert_file_contains "$POST_INSTALL" 'stop_running_jobs'
  assert_file_contains "$POST_INSTALL" 'sync-cron.sh'
  assert_file_contains "$POST_INSTALL" 'rm -rf "$TMP_OPS_QUEUE_DIR"'
  assert_file_contains "$POST_INSTALL" 'rm -f /usr/local/emhttp/plugins/zfs.autosnapshot/php/recovery-tools.php'
  assert_file_contains "$POST_INSTALL" 'kill -9 "$pid"'
  assert_file_contains "$PRE_REMOVE" 'kill -9 "$pid"'
  if grep -Eq 'kill -9|zfs destroy|/tmp/zfs-autosnapshot-ops|TMP_OPS_QUEUE_DIR' "$SCRIPT"; then
    fail "upgrade cleanup script contains a live-state or process-stop action"
  fi
}

assert_hooks
echo "PASS: upgrade cleanup is hooked and leaves post-install in place"

reset_tree
printf '%s\n' "$INSTALLED_VERSION" >"$VERSION_FILE"
mkdir -p "${BOOT}/ops_queue/april"
printf '%s\n' 'old-queue-file' >"${BOOT}/ops_queue/april/job"
before="$(cksum "$VERSION_FILE")"
invoke ZFSAS_INSTALLED_VERSION="$INSTALLED_VERSION"
status=$?
[[ "$status" -eq 0 ]] || fail "unchanged version exited ${status}"
[[ -f "${BOOT}/ops_queue/april/job" ]] || fail "unchanged version removed legacy residue"
[[ "$(cksum "$VERSION_FILE")" == "$before" ]] || fail "unchanged version rewrote the version file"
[[ ! -s "$LOG" ]] || fail "unchanged version wrote a cleanup log"
assert_user_state_unchanged
echo "PASS: unchanged version is a no-op"

reset_tree
mkdir -p "${BOOT}/ops_queue/april"
printf '%s\n' 'old-queue-file' >"${BOOT}/ops_queue/april/job"
printf '%s\n' 'also-old' >"${BOOT}/ops_queue/plain"
ln -s "${BOOT}/zfs_autosnapshot.conf" "${BOOT}/ops_queue/conf-link"
printf '%s\n' 'apple' >"${PLUGIN}/._settings.php"
printf '%s\n' 'store' >"${PLUGIN}/php/.DS_Store"
printf '%s\n' '<?php echo "stale";' >"${PLUGIN}/php/recovery-tools.php"
printf '%s\n' '<?php echo "stale";' >"${PLUGIN}/php/recovery-status.php"
printf '%s\n' '<?php echo "stale";' >"${PLUGIN}/php/recovery-action.php"
printf '%s\n' '<?php echo "stale";' >"${PLUGIN}/php/recovery-helpers.php"
printf '%s\n' '#!/bin/bash' >"${SBIN}/zfs_autosnapshot_recovery_scan"
printf '%s\n' 'keep-me' >"${SBIN}/zfs_autosnapshot"
invoke ZFSAS_INSTALLED_VERSION="$INSTALLED_VERSION"
[[ "$(tr -d '[:space:]' <"$VERSION_FILE")" == "$INSTALLED_VERSION" ]] || fail "version was not recorded after cleanup"
[[ ! -e "${BOOT}/ops_queue" ]] || fail "legacy ops_queue directory survived"
[[ ! -e "${PLUGIN}/._settings.php" ]] || fail "AppleDouble file survived"
[[ ! -e "${PLUGIN}/php/.DS_Store" ]] || fail "DS_Store file survived"
[[ ! -e "${PLUGIN}/php/recovery-tools.php" ]] || fail "stale recovery tool survived"
[[ ! -e "${PLUGIN}/php/recovery-status.php" ]] || fail "stale recovery status survived"
[[ ! -e "${PLUGIN}/php/recovery-action.php" ]] || fail "stale recovery action survived"
[[ ! -e "${PLUGIN}/php/recovery-helpers.php" ]] || fail "stale recovery helper survived"
[[ ! -e "${SBIN}/zfs_autosnapshot_recovery_scan" ]] || fail "stale recovery command survived"
[[ "$(cat "${SBIN}/zfs_autosnapshot")" == "keep-me" ]] || fail "unrelated sbin file changed"
assert_file_contains "$LOG" "Removed legacy flash ops_queue directory (4 entries)"
assert_file_contains "$LOG" "Removed AppleDouble metadata:"
assert_file_contains "$LOG" "Removed stale Recovery/Repair tool file:"
assert_file_contains "$LOG" "Recorded upgrade cleanup version ${INSTALLED_VERSION}."
assert_user_state_unchanged
echo "PASS: version change with residue cleans and records the version"

reset_tree
invoke ZFSAS_INSTALLED_VERSION="$INSTALLED_VERSION"
[[ "$(tr -d '[:space:]' <"$VERSION_FILE")" == "$INSTALLED_VERSION" ]] || fail "version was not recorded when nothing was left"
assert_file_contains "$LOG" "Legacy flash ops_queue: not present."
assert_file_contains "$LOG" "AppleDouble metadata: none"
assert_file_contains "$LOG" "Stale Recovery/Repair tool files: none."
assert_file_contains "$LOG" "Recorded upgrade cleanup version ${INSTALLED_VERSION}."
assert_user_state_unchanged
echo "PASS: version change without residue only records the version"

reset_tree
mkdir -p "${BOOT}/ops_queue"
printf '%s\n' 'stuck' >"${BOOT}/ops_queue/stuck"
: >"${FLAG_DIR}/fail-ops-queue"
set +e
invoke ZFSAS_INSTALLED_VERSION="$INSTALLED_VERSION" >"${TEST_ROOT}/fail.out" 2>"${TEST_ROOT}/fail.err"
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "failed cleanup exited 0"
[[ ! -f "$VERSION_FILE" ]] || fail "failed cleanup recorded the version"
[[ -f "${BOOT}/ops_queue/stuck" ]] || fail "failed cleanup removed the leftover"
assert_file_contains "$LOG" "ERROR: could not remove legacy flash ops_queue directory"
assert_file_contains "$LOG" "Version was not recorded. It will retry on the next run."
rm -f "${FLAG_DIR}/fail-ops-queue" "$LOG"
invoke ZFSAS_INSTALLED_VERSION="$INSTALLED_VERSION"
[[ ! -e "${BOOT}/ops_queue" ]] || fail "retry left the legacy ops_queue directory"
[[ "$(tr -d '[:space:]' <"$VERSION_FILE")" == "$INSTALLED_VERSION" ]] || fail "retry did not record the version"
assert_file_contains "$LOG" "Recorded upgrade cleanup version ${INSTALLED_VERSION}."
assert_user_state_unchanged
echo "PASS: failed cleanup is not recorded and the next run retries"

reset_tree
mkdir -p "${BOOT}/ops_queue"
printf '%s\n' 'slow' >"${BOOT}/ops_queue/slow"
printf '%s\n' '1' >"${FLAG_DIR}/delay-ops-queue"
invoke ZFSAS_INSTALLED_VERSION="$INSTALLED_VERSION" >"${TEST_ROOT}/concurrent-a.out" 2>"${TEST_ROOT}/concurrent-a.err" &
pid_a=$!
sleep 0.2
invoke ZFSAS_INSTALLED_VERSION="$INSTALLED_VERSION" >"${TEST_ROOT}/concurrent-b.out" 2>"${TEST_ROOT}/concurrent-b.err" &
pid_b=$!
set +e
wait "$pid_a"
status_a=$?
wait "$pid_b"
status_b=$?
set -e
[[ "$status_a" -eq 0 && "$status_b" -eq 0 ]] || fail "concurrent runs exited ${status_a} and ${status_b}"
[[ ! -e "${BOOT}/ops_queue" ]] || fail "concurrent runs left the legacy ops_queue directory"
[[ "$(tr -d '[:space:]' <"$VERSION_FILE")" == "$INSTALLED_VERSION" ]] || fail "concurrent runs did not record one version"
removed_count="$(grep -c 'Removed legacy flash ops_queue directory' "$LOG" || true)"
[[ "$removed_count" == "1" ]] || fail "concurrent runs removed the legacy directory ${removed_count} times"
assert_file_not_contains "$LOG" "did not finish"
assert_user_state_unchanged
rm -f "${FLAG_DIR}/delay-ops-queue"
echo "PASS: concurrent runs clean once and record the version"

reset_tree
mkdir -p "${BOOT}/ops_queue"
printf '%s\n' 'helper-only' >"${BOOT}/ops_queue/helper"
env \
  ZFSAS_BOOT_PLUGIN_DIR="$BOOT" \
  ZFSAS_PLUGIN_DIR="$PLUGIN" \
  ZFSAS_SBIN_DIR="$SBIN" \
  ZFSAS_MIGRATION_LOG_FILE="$LOG" \
  ZFSAS_MIGRATION_VERSION_FILE="$VERSION_FILE" \
  ZFSAS_MIGRATION_LOCK_FILE="$LOCK" \
  ZFSAS_PACKAGE_DB_DIR="$PKGDB" \
  ZFSAS_PLUGIN_MANIFEST="$MANIFEST" \
  ZFSAS_BOOT_PLUGIN_MANIFEST="${TEST_ROOT}/missing-boot.plg" \
  ZFSAS_TEST_FLAG_DIR="$FLAG_DIR" \
  PATH="${MOCKBIN}:${PATH}" \
  bash -c 'source "$1" && zfsas_migration_remove_legacy_ops_queue' bash "$SCRIPT"
[[ ! -e "${BOOT}/ops_queue" ]] || fail "shared helper left the legacy directory"
[[ ! -f "$VERSION_FILE" ]] || fail "shared helper recorded the version"
assert_user_state_unchanged
echo "PASS: shared helper cleans without marking the version done"

reset_tree
: >"${PKGDB}/zfs-autosnapshot-2026.11.13.t01-noarch-1"
cat >"$MANIFEST" <<'EOF'
<PLUGIN name="zfs.autosnapshot" version="2026.11.12.t01">
EOF
invoke
[[ "$(tr -d '[:space:]' <"$VERSION_FILE")" == "2026.11.13.t01" ]] || fail "package version did not win over the plg"
rm -rf "$PKGDB" "$VERSION_FILE" "$LOG"
mkdir -p "$PKGDB"
cat >"$MANIFEST" <<'EOF'
<PLUGIN name="zfs.autosnapshot" version="2026.11.12.t01">
EOF
invoke
[[ "$(tr -d '[:space:]' <"$VERSION_FILE")" == "2026.11.12.t01" ]] || fail "plg version was not used when the package db was empty"
echo "PASS: installed version comes from the package, then the plg"

reset_tree
mkdir -p "${TEST_ROOT}/unsafe-boot/ops_queue"
printf '%s\n' 'sentinel' >"${TEST_ROOT}/unsafe-boot/ops_queue/sentinel"
set +e
env \
  ZFSAS_BOOT_PLUGIN_DIR="${TEST_ROOT}/unsafe-boot" \
  ZFSAS_PLUGIN_DIR="$PLUGIN" \
  ZFSAS_SBIN_DIR="$SBIN" \
  ZFSAS_MIGRATION_LOG_FILE="$LOG" \
  ZFSAS_MIGRATION_VERSION_FILE="${TEST_ROOT}/unsafe-version" \
  ZFSAS_MIGRATION_LOCK_FILE="$LOCK" \
  ZFSAS_PACKAGE_DB_DIR="$PKGDB" \
  ZFSAS_PLUGIN_MANIFEST="$MANIFEST" \
  ZFSAS_BOOT_PLUGIN_MANIFEST="${TEST_ROOT}/missing-boot.plg" \
  ZFSAS_INSTALLED_VERSION="$INSTALLED_VERSION" \
  ZFSAS_TEST_FLAG_DIR="$FLAG_DIR" \
  PATH="${MOCKBIN}:${PATH}" \
  "$SCRIPT" >"${TEST_ROOT}/unsafe.out" 2>"${TEST_ROOT}/unsafe.err"
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "unsafe flash directory was accepted"
[[ -f "${TEST_ROOT}/unsafe-boot/ops_queue/sentinel" ]] || fail "unsafe path guard deleted a directory"
[[ ! -f "${TEST_ROOT}/unsafe-version" ]] || fail "unsafe path guard recorded a version"
assert_file_contains "$LOG" "refusing to touch an unsafe flash plugin directory"
echo "PASS: cleanup refuses a flash directory that is not the plugin config"

echo "All upgrade migration checks passed."
