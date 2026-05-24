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

printf '%s\n' "PASS: send transport command checks"
