#!/bin/bash
# Behavioral checks for Unraid array-state detection used by the queue kicker.
# Cron on Unraid 7.3 has a minimal PATH, so mdcmd at /usr/local/sbin/mdcmd is
# invisible to `command -v`. /proc/mdcmd can also be readable and still fail
# with "Input/output error". Either case must still reach var.ini.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OPS_LIB="${ROOT_DIR}/source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/ops-queue-lib.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/zfsas-array-status.XXXXXX")"

cleanup() {
  rm -rf "$WORK"
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
    printf 'Expected: %q\nActual:   %q\n' "$expected" "$actual" >&2
    fail "$message"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$message (missing: $needle; text: $haystack)"
}

lib_text="$(/bin/cat "$OPS_LIB")"
assert_contains "$lib_text" 'ZFSAS_MDCMD_EXPLICIT_PATH:-/usr/local/sbin/mdcmd' \
  "find_mdcmd must check /usr/local/sbin/mdcmd when it is not on PATH"
assert_contains "$lib_text" 'ZFSAS_PROC_MDCMD_PATH:-/proc/mdcmd' \
  "get_unraid_array_status must read /proc/mdcmd only as a fallback"
assert_contains "$lib_text" 'ZFSAS_VAR_INI_PATH:-/var/local/emhttp/var.ini' \
  "get_unraid_array_status must fall back to /var/local/emhttp/var.ini"

# shellcheck source=/dev/null
source "$OPS_LIB"

BIN_DIR="${WORK}/bin"
SBIN_DIR="${WORK}/usr/local/sbin"
ROOT_BIN_DIR="${WORK}/root"
PROC_DIR="${WORK}/proc"
VAR_DIR="${WORK}/var/local/emhttp"
mkdir -p "$BIN_DIR" "$SBIN_DIR" "$ROOT_BIN_DIR" "$PROC_DIR" "$VAR_DIR"

EXPLICIT_MDCMD="${SBIN_DIR}/mdcmd"
ROOT_MDCMD="${ROOT_BIN_DIR}/mdcmd"
PATH_MDCMD="${BIN_DIR}/mdcmd"
PROC_MDCMD="${PROC_DIR}/mdcmd"
VAR_INI="${VAR_DIR}/var.ini"
CAT_BIN="${BIN_DIR}/cat"
CAT_LOG="${WORK}/cat.log"

export ZFSAS_MDCMD_EXPLICIT_PATH="$EXPLICIT_MDCMD"
export ZFSAS_MDCMD_ROOT_PATH="$ROOT_MDCMD"
export ZFSAS_PROC_MDCMD_PATH="$PROC_MDCMD"
export ZFSAS_VAR_INI_PATH="$VAR_INI"

write_mdcmd() {
  local path="$1"
  local body="$2"
  /bin/cat > "$path" <<EOF
#!/bin/bash
${body}
EOF
  chmod +x "$path"
}

install_real_cat() {
  /bin/cat > "$CAT_BIN" <<EOF
#!/bin/bash
exec /bin/cat "\$@"
EOF
  chmod +x "$CAT_BIN"
}

install_failing_cat() {
  /bin/cat > "$CAT_BIN" <<EOF
#!/bin/bash
printf 'cat-invoked %s\n' "\$1" >> ${CAT_LOG@Q}
if [[ "\${1:-}" == ${PROC_MDCMD@Q} ]]; then
  printf 'partial mdState=STOPPED\n'
  echo "cat: \$1: Input/output error" >&2
  exit 1
fi
exec /bin/cat "\$@"
EOF
  chmod +x "$CAT_BIN"
}

reset_sources() {
  rm -f "$EXPLICIT_MDCMD" "$ROOT_MDCMD" "$PATH_MDCMD" "$PROC_MDCMD" "$VAR_INI" "$CAT_LOG"
  install_real_cat
  export PATH="${BIN_DIR}:/usr/bin:/bin"
}

cron_path() {
  # Minimal cron PATH: mdcmd is not visible via command -v.
  export PATH="/usr/bin:/bin"
}

status_text() {
  get_unraid_array_status 2>/dev/null || true
}

reset_sources

write_mdcmd "$EXPLICIT_MDCMD" 'printf "mdState=STARTED\n"'
printf 'mdState="STOPPED"\n' > "$VAR_INI"
cron_path
assert_eq "$(status_text)" "mdState=STARTED" \
  "cron PATH must use /usr/local/sbin/mdcmd instead of var.ini"
if ! unraid_array_actionable; then
  fail "explicit mdcmd STARTED must be an actionable array"
fi
assert_contains "$(unraid_array_action_message)" "mdState=started" \
  "explicit mdcmd status must supply the array state message"

reset_sources
write_mdcmd "$PATH_MDCMD" 'printf "mdState=STARTED\n"'
write_mdcmd "$EXPLICIT_MDCMD" 'printf "mdState=STOPPED\n"'
export PATH="${BIN_DIR}:/usr/bin:/bin"
assert_eq "$(status_text)" "mdState=STARTED" \
  "mdcmd already on PATH must still win over the explicit path"

reset_sources
cron_path
printf 'mdState=STARTED\n' > "$PROC_MDCMD"
printf 'mdState="STOPPED"\n' > "$VAR_INI"
assert_eq "$(status_text)" "mdState=STARTED" \
  "a successful /proc/mdcmd read must be used before var.ini"

reset_sources
cron_path
: > "$PROC_MDCMD"
printf 'mdState="STARTED"\n' > "$VAR_INI"
assert_eq "$(status_text)" 'mdState="STARTED"' \
  "an empty /proc/mdcmd read must fall back to var.ini"
if ! unraid_array_actionable; then
  fail "var.ini mdState=STARTED must be actionable after an empty proc read"
fi
message="$(unraid_array_action_message)"
assert_contains "$message" "mdState=started" \
  "var.ini fallback must not report that the array state is missing"
if [[ "$message" == "Waiting for Unraid to report an actionable array state" ]]; then
  fail "empty /proc/mdcmd must not leave the queue kicker waiting forever"
fi

reset_sources
install_failing_cat
# Fake cat is on PATH so the proc read fails. mdcmd is not, so the explicit
# /usr/local/sbin lookup and the var.ini fallback are what the kicker uses.
export PATH="${BIN_DIR}:/usr/bin:/bin"
printf 'unread\n' > "$PROC_MDCMD"
printf 'mdState="STARTED"\n' > "$VAR_INI"
# The queue kicker runs with set -e. A failed /proc/mdcmd read must not abort
# before var.ini is consulted.
(
  set -euo pipefail
  status="$(get_unraid_array_status)"
  printf '%s\n' "$status" > "${WORK}/failed-proc.status"
  if ! unraid_array_actionable; then
    echo "not-actionable" > "${WORK}/failed-proc.action"
  fi
)
assert_eq "$(/bin/cat "${WORK}/failed-proc.status")" 'mdState="STARTED"' \
  "a failed /proc/mdcmd read must fall back to var.ini under set -e"
if [[ -f "${WORK}/failed-proc.action" ]]; then
  fail "var.ini mdState=STARTED must stay actionable when /proc/mdcmd returns an I/O error"
fi
assert_contains "$(/bin/cat "$CAT_LOG")" "$PROC_MDCMD" \
  "the failed proc path must actually attempt to read /proc/mdcmd"
message="$(unraid_array_action_message)"
if [[ "$message" == "Waiting for Unraid to report an actionable array state" ]]; then
  fail "I/O error from /proc/mdcmd must not leave the queue kicker waiting forever"
fi

reset_sources
install_failing_cat
export PATH="${BIN_DIR}:/usr/bin:/bin"
printf 'unread\n' > "$PROC_MDCMD"
rm -f "$VAR_INI"
set +e
get_unraid_array_status >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  fail "failed /proc/mdcmd without var.ini must not look like a successful status read"
fi

reset_sources
cron_path
write_mdcmd "$EXPLICIT_MDCMD" 'echo "mdcmd: status failed" >&2; exit 1'
printf 'mdState="STARTED"\n' > "$VAR_INI"
rm -f "$PROC_MDCMD"
assert_eq "$(status_text)" 'mdState="STARTED"' \
  "a failing explicit mdcmd must still fall through to var.ini"
if ! unraid_array_actionable; then
  fail "var.ini must be actionable when the explicit mdcmd command fails"
fi

echo "PASS: unraid array status checks"
