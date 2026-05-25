#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OPS_LIB="${ROOT_DIR}/source/usr/local/emhttp/plugins/zfs.autosnapshot/scripts/ops-queue-lib.sh"

# shellcheck source=/dev/null
source "$OPS_LIB"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  [[ "$haystack" == *"$needle"* ]] || fail "$message (missing: $needle; command: $haystack)"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  [[ "$haystack" != *"$needle"* ]] || fail "$message (unexpected: $needle; command: $haystack)"
}

SEND_SSH_HOST="backup.example.test"
SEND_SSH_PORT="2222"
SEND_SSH_USER="replicator"
SEND_SSH_KEY_PATH=""
command=""

if ! build_ssh_receive_command "backup/root" command; then
  fail "SSH receive command should support preconfigured/agent auth when no key path is stored"
fi

assert_contains "$command" "ssh" "SSH receive command must use ssh"
assert_contains "$command" "BatchMode=yes" "SSH receive command must remain non-interactive"
assert_contains "$command" "PasswordAuthentication=no" "SSH receive command must not fall back to password prompts"
assert_contains "$command" "-p 2222" "SSH receive command must include configured port"
assert_contains "$command" "replicator@backup.example.test" "SSH receive command must target configured user and host"
assert_contains "$command" "zfs\\ receive" "SSH receive command must carry remote zfs receive command"
assert_contains "$command" "backup/root" "SSH receive command must include destination dataset"
assert_not_contains "$command" " -i " "SSH receive command must not include an empty identity-file argument"

SEND_SSH_KEY_PATH="relative/key"
if build_ssh_receive_command "backup/root" command; then
  fail "SSH receive command must reject an invalid relative key path when one is provided"
fi

SEND_SSH_KEY_PATH="/boot/config/plugins/zfs.autosnapshot/ssh/id_ed25519"
if ! build_ssh_receive_command "backup/root" command; then
  fail "SSH receive command should accept an absolute key path"
fi
assert_contains "$command" "-i /boot/config/plugins/zfs.autosnapshot/ssh/id_ed25519" "SSH receive command must include valid configured identity file"

SEND_SPIPED_REMOTE_HOST="receiver.example.test"
SEND_SPIPED_REMOTE_PORT="8023"
SEND_SPIPED_KEY_PATH="/boot/config/plugins/zfs.autosnapshot/spiped/key.bin"
spipe_command=""
if ! build_spipe_send_command spipe_command; then
  fail "spiped sender command should accept an absolute key path"
fi
assert_contains "$spipe_command" "spipe -t receiver.example.test:8023" "spiped sender command must target configured receiver"
assert_contains "$spipe_command" "-k /boot/config/plugins/zfs.autosnapshot/spiped/key.bin" "spiped sender command must include valid configured key file"

command=""
if ! build_spipe_send_command command; then
  fail "spiped sender command should support a caller result variable named command"
fi
assert_contains "$command" "spipe -t receiver.example.test:8023" "spiped sender command must populate a caller variable named command"

command=""
if ! build_spiped_receive_command "backup/root" command; then
  fail "spiped receiver command should support a caller result variable named command"
fi
assert_contains "$command" "spiped -d" "spiped receiver command must populate a caller variable named command"
assert_contains "$command" "zfs receive" "spiped receiver command must pipe to zfs receive"

# Transport-aware latest-common protection: SSH schedules must discover the
# destination inventory over SSH.  The remote destination often will not exist
# locally on the sender, so falling back to local destination probes can make
# source cleanup forget the newest common checkpoint and delete the only
# incremental base for an SSH schedule.
tmp_bin="$(mktemp -d)"
cleanup_transport_check() {
  rm -rf "$tmp_bin"
}
trap cleanup_transport_check EXIT

cat >"${tmp_bin}/ssh" <<'SSH_FAKE'
#!/bin/bash
remote_command="${*: -1}"
case "$remote_command" in
  *"zfs list -H -o name -- backup/data"*)
    printf '%s\n' "backup/data"
    exit 0
    ;;
  *"zfs list -H -p -s creation -t snapshot -o name,creation -d 1 -- backup/data"*)
    printf '%s\t%s\n' "backup/data@zfs-send-feedfacecafe-old" "100"
    exit 0
    ;;
esac
exit 1
SSH_FAKE
chmod +x "${tmp_bin}/ssh"
PATH="${tmp_bin}:$PATH"

zfs() {
  if [[ "$1" == "list" ]]; then
    local args=" $* "
    if [[ "$args" == *" -o name "* && "$args" == *" source/data "* ]]; then
      printf '%s\n' "source/data"
      return 0
    fi
    if [[ "$args" == *" -t snapshot "* && "$args" == *" source/data "* ]]; then
      printf '%s\t%s\n' \
        "source/data@zfs-send-feedfacecafe-old" "100" \
        "source/data@zfs-send-feedfacecafe-new" "200"
      return 0
    fi
    if [[ "$args" == *" backup/data "* ]]; then
      return 1
    fi
  fi
  return 1
}

SCHEDULE_SOURCE_ROOT[feedfacecafe]="source/data"
SCHEDULE_DEST_ROOT[feedfacecafe]="backup/data"
SCHEDULE_INCLUDE_CHILDREN[feedfacecafe]="0"
SCHEDULE_TRANSPORT[feedfacecafe]="ssh"
SCHEDULE_PREFIX[feedfacecafe]="zfs-send-feedfacecafe-"
SEND_SSH_HOST="backup.example.test"
SEND_SSH_PORT="2222"
SEND_SSH_USER="replicator"
SEND_SSH_KEY_PATH=""

declare -A common_checkpoints=()
collect_latest_common_checkpoint_basenames_for_schedule "feedfacecafe" common_checkpoints || true
[[ -n "${common_checkpoints[zfs-send-feedfacecafe-old]:-}" ]] || fail "SSH schedules must protect latest common checkpoints discovered from the remote destination inventory"
[[ -z "${common_checkpoints[zfs-send-feedfacecafe-new]:-}" ]] || fail "SSH latest-common protection must not mark source-only checkpoints common"

printf '%s\n' "PASS: send transport command checks"
