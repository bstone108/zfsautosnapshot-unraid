#!/usr/bin/env bash
# Container mount matching for the dataset migrator.
# A mount touches a migrating folder when either path is the same, a parent,
# or a child of the other, after /mnt/user, /mnt/user0, pool, and disk aliases
# and symlink canonicalization. This is not limited to appdata or cache.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKER="${ROOT_DIR}/source/usr/local/sbin/zfs_autosnapshot_migrate_datasets"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_indexes() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  local got want
  got="$(printf '%s\n' "$actual" | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//')"
  want="$(printf '%s\n' "$expected" | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//')"
  if [[ "$got" != "$want" ]]; then
    fail "${label}: expected indexes [${want}] but got [${got}]"
  fi
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zfsas-mount-match.XXXXXX")"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

MNT="${TMP_ROOT}/mnt"
PLUGIN="${TMP_ROOT}/plugin"
FAKEBIN="${TMP_ROOT}/fakebin"
mkdir -p \
  "$MNT/cache/appdata/file-sync-engine/logs" \
  "$MNT/cache/appdata/other" \
  "$MNT/cache/app" \
  "$MNT/cache/media/movies" \
  "$MNT/disk1/appdata/file-sync-engine" \
  "$MNT/disk1/photos/vacation" \
  "$MNT/nvme/appdata/file-sync-engine" \
  "$MNT/user/appdata/file-sync-engine" \
  "$MNT/user0/appdata/file-sync-engine" \
  "$PLUGIN" \
  "$FAKEBIN"
ln -s file-sync-engine "$MNT/cache/appdata/fse-link"
ln -s "$MNT/cache/appdata/file-sync-engine" "$TMP_ROOT/outside-link"

export ZFSAS_MIGRATOR_PLUGIN_ROOT="$PLUGIN"
export ZFSAS_MIGRATOR_MNT_ROOT="$MNT"
export ZFSAS_MIGRATOR_LOG_FILE="${TMP_ROOT}/worker.log"
export ZFSAS_MIGRATOR_LOG_ARCHIVE_FILE="${TMP_ROOT}/worker.archive.log"
export ZFSAS_MIGRATOR_LOCK_FILE="${TMP_ROOT}/migrator.lock"
# shellcheck disable=SC1090
source "$WORKER"

FOLDER_NAMES=(file-sync-engine other app movies)
FOLDER_SOURCE_PATHS=(
  "$MNT/cache/appdata/file-sync-engine"
  "$MNT/cache/appdata/other"
  "$MNT/cache/app"
  "$MNT/cache/media/movies"
)
FOLDER_TARGET_DATASETS=(tank/cache/file-sync-engine tank/cache/other tank/cache/app tank/cache/movies)
FOLDER_SIZE_BYTES=(0 0 0 0)
FOLDER_STATES=(queued queued queued queued)
FOLDER_PROGRESS=(0 0 0 0)
FOLDER_MESSAGES=(queued queued queued queued)
FOLDER_CONTAINER_INDEXES=("" "" "" "")
FOLDER_INDEX_BY_NAME=()
FOLDER_INDEX_BY_NAME[file-sync-engine]=0
FOLDER_INDEX_BY_NAME[other]=1
FOLDER_INDEX_BY_NAME[app]=2
FOLDER_INDEX_BY_NAME[movies]=3

assert_indexes "user share exact" "$(folder_indexes_for_mount_source "$MNT/user/appdata/file-sync-engine")" "0"
assert_indexes "user0 share exact" "$(folder_indexes_for_mount_source "$MNT/user0/appdata/file-sync-engine")" "0"
assert_indexes "cache pool exact" "$(folder_indexes_for_mount_source "$MNT/cache/appdata/file-sync-engine")" "0"
assert_indexes "disk path" "$(folder_indexes_for_mount_source "$MNT/disk1/appdata/file-sync-engine")" "0"
assert_indexes "non-cache pool" "$(folder_indexes_for_mount_source "$MNT/nvme/appdata/file-sync-engine")" "0"
assert_indexes "parent user share" "$(folder_indexes_for_mount_source "$MNT/user/appdata")" $'0\n1'
assert_indexes "parent pool dataset" "$(folder_indexes_for_mount_source "$MNT/cache/appdata")" $'0\n1'
assert_indexes "child user path" "$(folder_indexes_for_mount_source "$MNT/user/appdata/file-sync-engine/logs/fse.jsonl")" "0"
assert_indexes "child disk path" "$(folder_indexes_for_mount_source "$MNT/disk1/appdata/file-sync-engine/logs")" "0"
assert_indexes "movies via user share" "$(folder_indexes_for_mount_source "$MNT/user/media/movies")" "3"
assert_indexes "movies via other disk" "$(folder_indexes_for_mount_source "$MNT/disk2/media/movies/4k")" "3"
assert_indexes "unrelated share" "$(folder_indexes_for_mount_source "$MNT/disk1/photos/vacation")" ""
assert_indexes "prefix app is not appdata" "$(folder_indexes_for_mount_source "$MNT/user/app")" "2"
assert_indexes "app child is not appdata" "$(folder_indexes_for_mount_source "$MNT/user/app/child")" "2"
assert_indexes "symlink inside pool" "$(folder_indexes_for_mount_source "$MNT/cache/appdata/fse-link")" "0"
assert_indexes "symlink outside mnt" "$(folder_indexes_for_mount_source "$TMP_ROOT/outside-link")" "0"

cat > "${FAKEBIN}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
shift || true
case "$cmd" in
  info)
    exit 0
    ;;
  ps)
    printf '%s\n' "cid-writer" "cid-child"
    exit 0
    ;;
  inspect)
    fmt=""
    if [[ "${1:-}" == "-f" ]]; then
      shift
      fmt="${1:-}"
      shift
    fi
    cid="${1:-}"
    if [[ "$fmt" == *".Mounts"* ]]; then
      if [[ "$cid" == "cid-writer" ]]; then
        printf '%s\n' "${ZFSAS_TEST_WRITER_MOUNT}"
      fi
      exit 0
    fi
    if [[ "$fmt" == *".State.Running"* ]]; then
      printf 'true\n'
      exit 0
    fi
    case "$cid" in
      cid-writer)
        printf '%s\n' "cid-writer|file-sync-engine|no|0|default||"
        ;;
      cid-child)
        printf '%s\n' "cid-child|file-sync-child|always|0|container:file-sync-engine||"
        ;;
      *)
        printf '\n'
        ;;
    esac
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "${FAKEBIN}/docker"

export PATH="${FAKEBIN}:${PATH}"
export ZFSAS_TEST_WRITER_MOUNT="${MNT}/user/appdata/file-sync-engine"
CONTAINER_IDS=()
CONTAINER_NAMES=()
CONTAINER_RESTART_NAMES=()
CONTAINER_RESTART_MAXS=()
CONTAINER_NETWORK_MODES=()
CONTAINER_FOLDER_INDEXES=()
CONTAINER_DEPENDENCY_REFS=()
CONTAINER_DEPENDENCY_INDEXES=()
CONTAINER_WAS_RUNNING=()
CONTAINER_CURRENTLY_RUNNING=()
CONTAINER_POLICY_DISABLED=()
CONTAINER_START_STATES=()
CONTAINER_LAST_ERRORS=()
CONTAINER_INDEX_BY_NAME=()
CONTAINER_INDEX_BY_ID=()
FOLDER_CONTAINER_INDEXES=("" "" "" "")

record_running_containers

writer_index="${CONTAINER_INDEX_BY_NAME[file-sync-engine]}"
child_index="${CONTAINER_INDEX_BY_NAME[file-sync-child]}"
[[ -n "$writer_index" && -n "$child_index" ]] || fail "writer and dependent containers were not recorded"
assert_indexes "folder container indexes" "${FOLDER_CONTAINER_INDEXES[0]}" "${writer_index}"$'\n'"${child_index}"
if ! list_has_word "${CONTAINER_DEPENDENCY_INDEXES[$child_index]}" "$writer_index"; then
  fail "dependent container was not linked to the writer through network container:"
fi

echo "PASS: dataset migrator mount matching"
