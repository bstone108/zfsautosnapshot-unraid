#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${ROOT_DIR}/source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/ops-queue-lib.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zfsas-array-status.XXXXXX")"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"
  if [[ "$actual" != "$expected" ]]; then
    printf 'Expected: %s\nActual: %s\n' "$expected" "$actual" >&2
    fail "$message"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'Missing %s in:\n%s\n' "$needle" "$haystack" >&2
    fail "$message"
  fi
}

write_executable() {
  local path="$1"
  local body="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$body" > "$path"
  chmod 755 "$path"
}

write_status_file() {
  local path="$1"
  local body="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$body" > "$path"
}

# Run the library the way cron does: minimal PATH, set -e, and no inherited state.
# Extra env assignments are passed as KEY=VALUE arguments before the script body.
run_lib() {
  local path="$1"
  local script="$2"
  shift 2
  env -i \
    HOME="${TEST_ROOT}" \
    PATH="$path" \
    "$@" \
    bash -c "$script" bash "$LIB"
}

STARTED_STATUS=$'mdState=STARTED\nfsState=Started\nsbState=STARTED\nstarted=yes'

test_path_extension_and_static_contract() {
  local path_line script
  path_line="$(run_lib /usr/bin:/bin 'source "$1"; printf "%s\n" "$PATH"' )"
  case ":${path_line}:" in
    *:/usr/local/sbin:/usr/local/bin:/usr/sbin:/sbin:) ;;
    *) fail "library did not extend a cron PATH: ${path_line}" ;;
  esac

  path_line="$(run_lib "/usr/bin:/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/sbin" 'source "$1"; printf "%s\n" "$PATH"' )"
  if [[ "$(printf '%s\n' "$path_line" | awk -F: '{print NF}')" -ne 6 ]]; then
    fail "library duplicated PATH entries: ${path_line}"
  fi

  for script in \
    "${ROOT_DIR}/source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/ops-queue-lib.sh" \
    "${ROOT_DIR}/source/usr/local/sbin/zfs_autosnapshot_queue_kicker" \
    "${ROOT_DIR}/source/usr/local/sbin/zfs_autosnapshot_queue_handler" \
    "${ROOT_DIR}/source/usr/local/sbin/zfs_autosnapshot_send_worker" \
    "${ROOT_DIR}/source/usr/local/sbin/zfs_autosnapshot_delete_worker"
  do
    if ! grep -Fq "Keep Unraid sbin tools visible when cron PATH is /usr/bin:/bin." "$script"; then
      fail "missing cron PATH extension in ${script}"
    fi
  done

  if ! grep -Fq "/usr/local/sbin/mdcmd:/usr/sbin/mdcmd:/root/mdcmd" "$LIB"; then
    fail "find_mdcmd must check absolute mdcmd paths"
  fi
  if ! grep -Fq 'log_paused_for_unraid_array "Queue workers remain paused until the array is actionable."' \
    "${ROOT_DIR}/source/usr/local/sbin/zfs_autosnapshot_queue_kicker"; then
    fail "queue kicker must rate-limit an unreadable array state through the shared logger"
  fi
  if ! grep -Fq 'log_paused_for_unraid_array "Queue handler is pausing until the next kick."' \
    "${ROOT_DIR}/source/usr/local/sbin/zfs_autosnapshot_queue_handler"; then
    fail "queue handler must use the shared array-pause logger"
  fi
}

test_normal_mdcmd_output() {
  local bin="${TEST_ROOT}/normal/bin"
  local proc="${TEST_ROOT}/normal/proc-mdcmd"
  local var_ini="${TEST_ROOT}/normal/var.ini"
  local output
  write_executable "${bin}/mdcmd" $'#!/bin/bash\nprintf "%s\\n" "mdState=STARTED" "fsState=Started" "sbState=STARTED" "started=yes" "mdCmdSource=path"\n'
  write_status_file "$proc" 'mdState=STOPPED'
  write_status_file "$var_ini" 'mdState="STOPPED"'
  output="$(run_lib "${bin}:/usr/bin:/bin" '
    set -Eeuo pipefail
    source "$1"
    if unraid_array_actionable; then
      printf "actionable=0\n"
    else
      printf "actionable=1\n"
    fi
    get_unraid_array_status
  ' \
    ZFSAS_PROC_MDCMD="$proc" \
    ZFSAS_UNRAID_VAR_INI="$var_ini" \
    ZFSAS_MDCMD_CANDIDATES="${TEST_ROOT}/normal/missing-mdcmd")"
  assert_contains "$output" "actionable=0" "mdcmd on PATH should report a started array as actionable"
  assert_contains "$output" "mdCmdSource=path" "mdcmd on PATH should be the accepted status source"
  if [[ "$output" == *'mdState="STOPPED"'* || "$output" == *$'mdState=STOPPED'* ]]; then
    fail "a working mdcmd must not fall through to stopped fixtures"
  fi
}

test_mdcmd_missing_from_path_uses_absolute_path() {
  local sbin="${TEST_ROOT}/absolute/usr/local/sbin"
  local proc="${TEST_ROOT}/absolute/proc-mdcmd"
  local var_ini="${TEST_ROOT}/absolute/var.ini"
  local output
  write_executable "${sbin}/mdcmd" $'#!/bin/bash\nprintf "%s\\n" "mdState=STARTED" "fsState=Started" "mdCmdSource=absolute"\n'
  write_status_file "$proc" 'mdState=STOPPED'
  write_status_file "$var_ini" 'mdState="STOPPED"'
  output="$(run_lib /usr/bin:/bin '
    set -Eeuo pipefail
    source "$1"
    if command -v mdcmd >/dev/null 2>&1; then
      printf "command_v=yes\n"
    else
      printf "command_v=no\n"
    fi
    if unraid_array_actionable; then
      printf "actionable=0\n"
    else
      printf "actionable=1\n"
    fi
    get_unraid_array_status
  ' \
    ZFSAS_PROC_MDCMD="$proc" \
    ZFSAS_UNRAID_VAR_INI="$var_ini" \
    ZFSAS_MDCMD_CANDIDATES="${sbin}/mdcmd")"
  assert_contains "$output" "command_v=no" "absolute mdcmd lookup must not depend on PATH"
  assert_contains "$output" "actionable=0" "absolute mdcmd status should make a started array actionable"
  assert_contains "$output" "mdCmdSource=absolute" "absolute mdcmd should win over later status files"
}

test_proc_mdcmd_io_error_falls_through_to_var_ini() {
  local bin="${TEST_ROOT}/ioerr/bin"
  local proc="${TEST_ROOT}/ioerr/proc-mdcmd"
  local var_ini="${TEST_ROOT}/ioerr/var.ini"
  local output
  write_status_file "$proc" 'mdState=STARTED'
  write_status_file "$var_ini" $'mdState="STARTED"\nfsState="Started"\nmdNumDisks="0"'
  write_executable "${bin}/cat" '#!/bin/bash
if [[ "${1:-}" == "$ZFSAS_PROC_MDCMD" ]]; then
  echo "cat: $1: Input/output error" >&2
  exit 1
fi
exec /bin/cat "$@"
'
  [[ -r "$proc" ]] || fail "proc fixture must be readable so -r would have accepted it"
  if ZFSAS_PROC_MDCMD="$proc" "${bin}/cat" "$proc" >/dev/null 2>&1; then
    fail "proc fixture cat must fail with an I/O error"
  fi
  output="$(run_lib "${bin}:/usr/bin:/bin" '
    set -Eeuo pipefail
    source "$1"
    if unraid_array_actionable; then
      printf "actionable=0\n"
    else
      printf "actionable=1\n"
    fi
    get_unraid_array_status
  ' \
    ZFSAS_PROC_MDCMD="$proc" \
    ZFSAS_UNRAID_VAR_INI="$var_ini" \
    ZFSAS_MDCMD_CANDIDATES="${TEST_ROOT}/ioerr/missing-mdcmd")"
  assert_contains "$output" "actionable=0" "an unreadable /proc/mdcmd must fall through to a started var.ini"
  assert_contains "$output" 'mdState="STARTED"' "var.ini must be the accepted source after a /proc/mdcmd I/O error"
  assert_contains "$output" 'mdNumDisks="0"' "var.ini fallback should keep the rest of the status file"
}

test_rejected_mdcmd_output_falls_through_to_var_ini() {
  local bin="${TEST_ROOT}/reject/bin"
  local proc="${TEST_ROOT}/reject/missing-proc-mdcmd"
  local var_ini="${TEST_ROOT}/reject/var.ini"
  local output
  write_executable "${bin}/mdcmd" '#!/bin/bash
case "${ZFSAS_MDCMD_MODE:-empty}" in
  exit1)
    printf "%s\n" "mdState=STOPPED"
    exit 1
    ;;
  nokey)
    printf "%s\n" "status unavailable"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
'
  write_status_file "$var_ini" 'mdState="STARTED"'
  for mode in empty exit1 nokey; do
    output="$(run_lib "${bin}:/usr/bin:/bin" '
      set -Eeuo pipefail
      source "$1"
      if unraid_array_actionable; then
        printf "actionable=0\n"
      else
        printf "actionable=1\n"
      fi
      get_unraid_array_status
    ' \
      ZFSAS_MDCMD_MODE="$mode" \
      ZFSAS_PROC_MDCMD="$proc" \
      ZFSAS_UNRAID_VAR_INI="$var_ini" \
      ZFSAS_MDCMD_CANDIDATES="${TEST_ROOT}/reject/missing-mdcmd")"
    assert_contains "$output" "actionable=0" "mdcmd mode ${mode} must fall through to started var.ini"
    assert_contains "$output" 'mdState="STARTED"' "mdcmd mode ${mode} must not hide var.ini"
    if [[ "$output" == *$'mdState=STOPPED'* ]]; then
      fail "mdcmd mode ${mode} accepted a failed or unusable mdcmd status"
    fi
  done
}

test_var_ini_only_fallback() {
  local proc="${TEST_ROOT}/varonly/missing-proc-mdcmd"
  local var_ini="${TEST_ROOT}/varonly/var.ini"
  local output
  write_status_file "$var_ini" $'mdState="STARTED"\nfsState="Started"'
  output="$(run_lib /usr/bin:/bin '
    set -Eeuo pipefail
    source "$1"
    if unraid_array_actionable; then
      printf "actionable=0\n"
    else
      printf "actionable=1\n"
    fi
    get_unraid_array_status
  ' \
    ZFSAS_PROC_MDCMD="$proc" \
    ZFSAS_UNRAID_VAR_INI="$var_ini" \
    ZFSAS_MDCMD_CANDIDATES="${TEST_ROOT}/varonly/missing-mdcmd")"
  assert_contains "$output" "actionable=0" "var.ini alone should make a started array actionable"
  assert_contains "$output" 'fsState="Started"' "var.ini-only fallback should return the file contents"
}

test_all_sources_empty() {
  local proc="${TEST_ROOT}/empty/proc-mdcmd"
  local var_ini="${TEST_ROOT}/empty/var.ini"
  local output message
  mkdir -p "${TEST_ROOT}/empty"
  : > "$proc"
  : > "$var_ini"
  output="$(run_lib /usr/bin:/bin '
    set -Eeuo pipefail
    source "$1"
    if unraid_array_actionable; then
      printf "actionable=0\n"
    else
      printf "actionable=1\n"
    fi
    printf "message=%s\n" "$(unraid_array_action_message)"
  ' \
    ZFSAS_PROC_MDCMD="$proc" \
    ZFSAS_UNRAID_VAR_INI="$var_ini" \
    ZFSAS_MDCMD_CANDIDATES="${TEST_ROOT}/empty/missing-mdcmd")"
  assert_contains "$output" "actionable=1" "empty status sources must keep queue workers paused"
  message="${output#*message=}"
  assert_eq "$message" "Could not read Unraid array state from mdcmd, /proc/mdcmd or var.ini" \
    "empty status sources must say the state could not be read"

  output="$(run_lib /usr/bin:/bin '
    set -Eeuo pipefail
    source "$1"
    if unraid_array_actionable; then
      printf "actionable=0\n"
    else
      printf "actionable=1\n"
    fi
    printf "message=%s\n" "$(unraid_array_action_message)"
  ' \
    ZFSAS_PROC_MDCMD="${TEST_ROOT}/empty/missing-proc-mdcmd" \
    ZFSAS_UNRAID_VAR_INI="${TEST_ROOT}/empty/missing-var.ini" \
    ZFSAS_MDCMD_CANDIDATES="${TEST_ROOT}/empty/missing-mdcmd")"
  assert_contains "$output" "actionable=1" "missing status sources must keep queue workers paused"
  message="${output#*message=}"
  assert_eq "$message" "Could not read Unraid array state from mdcmd, /proc/mdcmd or var.ini" \
    "missing status sources must say the state could not be read"
}

test_explicit_non_actionable_states_stay_paused() {
  local var_ini="${TEST_ROOT}/stopped/var.ini"
  local output state
  for state in STOPPED STARTING STOPPING; do
    write_status_file "$var_ini" "mdState=\"${state}\""
    output="$(run_lib /usr/bin:/bin '
      set -Eeuo pipefail
      source "$1"
      if unraid_array_actionable; then
        printf "actionable=0\n"
      else
        printf "actionable=1\n"
      fi
      printf "message=%s\n" "$(unraid_array_action_message)"
    ' \
      ZFSAS_PROC_MDCMD="${TEST_ROOT}/stopped/missing-proc-mdcmd" \
      ZFSAS_UNRAID_VAR_INI="$var_ini" \
      ZFSAS_MDCMD_CANDIDATES="${TEST_ROOT}/stopped/missing-mdcmd")"
    assert_contains "$output" "actionable=1" "mdState=${state} must keep queue workers paused"
    assert_contains "$output" "message=Waiting for Unraid array to become actionable (mdState=${state,,})" \
      "explicit ${state} state must keep the waiting message"
    if [[ "$output" == *"Could not read Unraid array state"* ]]; then
      fail "explicit ${state} state was reported as unreadable"
    fi
  done
}

test_unreadable_status_log_is_rate_limited() {
  local stamp="${TEST_ROOT}/rate/unreadable.stamp"
  local log_file="${TEST_ROOT}/rate/log.txt"
  local count
  mkdir -p "${TEST_ROOT}/rate"
  run_lib /usr/bin:/bin '
    set -Eeuo pipefail
    source "$1"
    log() { printf "%s\n" "$*" >> "$ZFSAS_TEST_LOG"; }
    log_paused_for_unraid_array "Queue workers remain paused until the array is actionable."
    log_paused_for_unraid_array "Queue workers remain paused until the array is actionable."
  ' \
    ZFSAS_PROC_MDCMD="${TEST_ROOT}/rate/missing-proc-mdcmd" \
    ZFSAS_UNRAID_VAR_INI="${TEST_ROOT}/rate/missing-var.ini" \
    ZFSAS_MDCMD_CANDIDATES="${TEST_ROOT}/rate/missing-mdcmd" \
    ZFSAS_UNRAID_STATUS_UNREADABLE_STAMP="$stamp" \
    ZFSAS_UNRAID_STATUS_UNREADABLE_LOG_INTERVAL=3600 \
    ZFSAS_TEST_LOG="$log_file"
  count="$(wc -l < "$log_file" | tr -d "[:space:]")"
  assert_eq "$count" "1" "unreadable array state must not be logged on every minute"
  assert_contains "$(cat "$log_file")" \
    "Could not read Unraid array state from mdcmd, /proc/mdcmd or var.ini. Queue workers remain paused until the array is actionable." \
    "the rate-limited line must name the failed status sources"
  printf '1\n' > "$stamp"
  run_lib /usr/bin:/bin '
    set -Eeuo pipefail
    source "$1"
    log() { printf "%s\n" "$*" >> "$ZFSAS_TEST_LOG"; }
    log_paused_for_unraid_array "Queue workers remain paused until the array is actionable."
  ' \
    ZFSAS_PROC_MDCMD="${TEST_ROOT}/rate/missing-proc-mdcmd" \
    ZFSAS_UNRAID_VAR_INI="${TEST_ROOT}/rate/missing-var.ini" \
    ZFSAS_MDCMD_CANDIDATES="${TEST_ROOT}/rate/missing-mdcmd" \
    ZFSAS_UNRAID_STATUS_UNREADABLE_STAMP="$stamp" \
    ZFSAS_UNRAID_STATUS_UNREADABLE_LOG_INTERVAL=3600 \
    ZFSAS_TEST_LOG="$log_file"
  count="$(wc -l < "$log_file" | tr -d "[:space:]")"
  assert_eq "$count" "2" "an old unreadable-state stamp should allow another log line"

  local stopped_log="${TEST_ROOT}/rate/stopped.log"
  local stopped_stamp="${TEST_ROOT}/rate/stopped.stamp"
  write_status_file "${TEST_ROOT}/rate/var.ini" 'mdState="STOPPED"'
  run_lib /usr/bin:/bin '
    set -Eeuo pipefail
    source "$1"
    log() { printf "%s\n" "$*" >> "$ZFSAS_TEST_LOG"; }
    log_paused_for_unraid_array "Queue workers remain paused until the array is actionable."
    log_paused_for_unraid_array "Queue workers remain paused until the array is actionable."
  ' \
    ZFSAS_PROC_MDCMD="${TEST_ROOT}/rate/missing-proc-mdcmd" \
    ZFSAS_UNRAID_VAR_INI="${TEST_ROOT}/rate/var.ini" \
    ZFSAS_MDCMD_CANDIDATES="${TEST_ROOT}/rate/missing-mdcmd" \
    ZFSAS_UNRAID_STATUS_UNREADABLE_STAMP="$stopped_stamp" \
    ZFSAS_UNRAID_STATUS_UNREADABLE_LOG_INTERVAL=3600 \
    ZFSAS_TEST_LOG="$stopped_log"
  count="$(wc -l < "$stopped_log" | tr -d "[:space:]")"
  assert_eq "$count" "2" "an explicit stopped array must still log every pause"
  assert_contains "$(cat "$stopped_log")" "Waiting for Unraid array to become actionable (mdState=stopped)." \
    "stopped pauses must keep the existing waiting message"
  if [[ -e "$stopped_stamp" ]]; then
    fail "explicit stopped pauses must not use the unreadable-state rate limit"
  fi
}

test_path_extension_and_static_contract
echo "PASS: cron PATH extension"

test_normal_mdcmd_output
echo "PASS: normal mdcmd output"

test_mdcmd_missing_from_path_uses_absolute_path
echo "PASS: mdcmd missing from PATH"

test_proc_mdcmd_io_error_falls_through_to_var_ini
echo "PASS: /proc/mdcmd I/O error falls through to var.ini"

test_rejected_mdcmd_output_falls_through_to_var_ini
echo "PASS: empty or failed mdcmd output falls through"

test_var_ini_only_fallback
echo "PASS: var.ini-only fallback"

test_all_sources_empty
echo "PASS: all array status sources empty"

test_explicit_non_actionable_states_stay_paused
echo "PASS: explicit non-actionable array states stay paused"

test_unreadable_status_log_is_rate_limited
echo "PASS: unreadable array state log is rate-limited"
