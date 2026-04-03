#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_SCRIPT="${ROOT_DIR}/source/usr/local/sbin/zfs_autosnapshot"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zfsas-stage1-tests.XXXXXX")"
TEST_FAILED=0
TEST_BASH_BIN="${TEST_BASH_BIN:-}"

cleanup() {
  if (( TEST_FAILED )) || [[ "${KEEP_STAGE1_TEST_ROOT:-0}" == "1" ]]; then
    echo "Preserving test root: ${TEST_ROOT}" >&2
    return 0
  fi
  rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
  TEST_FAILED=1
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq "$needle" "$file"; then
    echo "Expected to find: $needle" >&2
    echo "In file: $file" >&2
    sed -n '1,240p' "$file" >&2 || true
    fail "assert_file_contains failed"
  fi
}

assert_snapshot_exists() {
  local case_dir="$1"
  local snap="$2"
  if ! awk -F '\t' -v snap="$snap" '$1 == snap { found = 1 } END { exit(found ? 0 : 1) }' "${case_dir}/state/snaps.tsv"; then
    fail "Expected snapshot to exist: ${snap}"
  fi
}

assert_snapshot_missing() {
  local case_dir="$1"
  local snap="$2"
  if awk -F '\t' -v snap="$snap" '$1 == snap { found = 1 } END { exit(found ? 0 : 1) }' "${case_dir}/state/snaps.tsv"; then
    fail "Expected snapshot to be missing: ${snap}"
  fi
}

write_test_script() {
  local case_dir="$1"
  local config_dir="${case_dir}/config"
  local runtime_dir="${case_dir}/run"
  local log_dir="${case_dir}/log"
  local lease_file="${config_dir}/snapshot_leases.tsv"

  sed \
    -e '1s|^#!/bin/bash$|#!/usr/bin/env bash|' \
    -e "s|^CONFIG_DIR=.*$|CONFIG_DIR=\"${config_dir}\"|" \
    -e "s|^RUNTIME_DIR=.*$|RUNTIME_DIR=\"${runtime_dir}\"|" \
    -e "s|^LOG_FILE=.*$|LOG_FILE=\"${log_dir}/debug.log\"|" \
    -e "s|^SUMMARY_LOG_FILE=.*$|SUMMARY_LOG_FILE=\"${log_dir}/summary.log\"|" \
    -e "s|^LEASE_STATE_FILE=.*$|LEASE_STATE_FILE=\"${lease_file}\"|" \
    "${SOURCE_SCRIPT}" > "${case_dir}/zfs_autosnapshot"

  chmod +x "${case_dir}/zfs_autosnapshot"
}

write_mock_date() {
  local case_dir="$1"

  cat > "${case_dir}/mockbin/date" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

epoch="${MOCK_NOW_EPOCH:-2000000000}"
target_epoch="$epoch"
format=""

if [[ "${1:-}" == "-d" ]]; then
  shift
  value="${1:-}"
  shift || true
  if [[ "$value" =~ ^@([0-9]+)$ ]]; then
    target_epoch="${BASH_REMATCH[1]}"
  else
    echo "Unsupported mock date -d argument: ${value}" >&2
    exit 1
  fi
fi

if [[ $# -gt 0 ]]; then
  format="$1"
else
  format="+%a %b %e %H:%M:%S %Z %Y"
fi

if [[ "$format" == "+%s" ]]; then
  printf '%s\n' "$target_epoch"
  exit 0
fi

perl -MPOSIX=strftime -e '
  my ($epoch, $format) = @ARGV;
  $format =~ s/^\+//;
  $ENV{TZ} = "UTC";
  POSIX::tzset();
  print strftime($format, gmtime($epoch)), "\n";
' "$target_epoch" "$format"
EOF

  chmod +x "${case_dir}/mockbin/date"
}

write_mock_zpool() {
  local case_dir="$1"

  cat > "${case_dir}/mockbin/zpool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${MOCK_STATE_DIR:?}"
pools_file="${state_dir}/pools.tsv"

cmd="${1:-}"
shift || true

case "$cmd" in
  version|--version)
    echo "zpool mock 1.0"
    ;;
  get)
    pool="${@: -1}"
    awk -F '\t' -v pool="$pool" '$1 == pool { print $3; found = 1 } END { exit(found ? 0 : 1) }' "$pools_file"
    ;;
  list)
    output=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -o)
          output="${2:-}"
          shift 2
          ;;
        -H|-p)
          shift
          ;;
        *)
          shift
          ;;
      esac
    done

    case "$output" in
      name)
        awk -F '\t' '{ print $1 }' "$pools_file"
        ;;
      name,size,alloc,free,capacity,health)
        awk -F '\t' '{ printf "%s\t%s\t%s\t%s\t%s\t%s\n", $1, $4, $5, $2, $6, $7 }' "$pools_file"
        ;;
      *)
        echo "Unsupported mock zpool list output: ${output}" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "Unsupported mock zpool command: ${cmd}" >&2
    exit 1
    ;;
esac
EOF

  chmod +x "${case_dir}/mockbin/zpool"
}

write_mock_zfs() {
  local case_dir="$1"

  cat > "${case_dir}/mockbin/zfs" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${MOCK_STATE_DIR:?}"
snaps_file="${state_dir}/snaps.tsv"
pools_file="${state_dir}/pools.tsv"
pending_file="${state_dir}/pending_reclaims.tsv"

pool_for_dataset() {
  local dataset="$1"
  printf '%s\n' "${dataset%%/*}"
}

snapshot_dataset() {
  local snap="$1"
  printf '%s\n' "${snap%@*}"
}

update_pool_avail() {
  local pool="$1"
  local delta="$2"
  local tmp
  tmp="$(mktemp "${pools_file}.tmp.XXXXXX")"
  awk -F '\t' -v pool="$pool" -v delta="$delta" 'BEGIN { OFS = FS }
    {
      if ($1 == pool) {
        $2 = $2 + delta
      }
      print
    }
  ' "$pools_file" > "$tmp"
  mv "$tmp" "$pools_file"
}

apply_pending_reclaims() {
  local tmp line pool delta remaining

  [[ -f "$pending_file" ]] || return 0

  tmp="$(mktemp "${pending_file}.tmp.XXXXXX")"
  while IFS=$'\t' read -r pool delta remaining; do
    [[ -n "$pool" ]] || continue

    if [[ "$remaining" =~ ^[0-9]+$ ]] && (( remaining > 0 )); then
      remaining=$((remaining - 1))
    else
      remaining=0
    fi

    if (( remaining == 0 )); then
      if [[ "$delta" =~ ^[0-9]+$ ]] && (( delta > 0 )); then
        update_pool_avail "$pool" "$delta"
      fi
      continue
    fi

    printf "%s\t%s\t%s\n" "$pool" "$delta" "$remaining" >> "$tmp"
  done < "$pending_file"

  mv "$tmp" "$pending_file"
}

cmd="${1:-}"
shift || true

case "$cmd" in
  version|--version)
    echo "zfs mock 1.0"
    ;;
  list)
    args=" $* "
    if [[ "$args" == *" -o avail "* ]]; then
      pool="${@: -1}"
      apply_pending_reclaims
      awk -F '\t' -v pool="$pool" '$1 == pool { print $2; found = 1 } END { exit(found ? 0 : 1) }' "$pools_file"
      exit 0
    fi

    if [[ "$args" == *" -o name,creation "* ]]; then
      dataset="${@: -1}"
      awk -F '\t' -v dataset="$dataset" '
        $2 == dataset || index($2, dataset "/") == 1 {
          printf "%s\t%s\n", $1, $3
        }
      ' "$snaps_file" | sort -t $'\t' -k2,2nr
      exit 0
    fi

    echo "Unsupported mock zfs list invocation: zfs list $*" >&2
    exit 1
    ;;
  get)
    dataset="${@: -1}"
    awk -F '\t' -v dataset="$dataset" '
      $2 == dataset || index($2, dataset "/") == 1 {
        printf "%s\tused\t%s\n", $1, $4
        printf "%s\twritten\t%s\n", $1, $5
        printf "%s\tuserrefs\t%s\n", $1, $6
      }
    ' "$snaps_file"
    ;;
  snapshot)
    snap="${1:?missing snapshot name}"
    dataset="$(snapshot_dataset "$snap")"
    creation="${MOCK_NOW_EPOCH:-2000000000}"
    printf "%s\t%s\t%s\t0\t0\t0\t0\n" "$snap" "$dataset" "$creation" >> "$snaps_file"
    ;;
  destroy)
    snap="${1:?missing snapshot name}"
    actual_reclaim="$(awk -F '\t' -v snap="$snap" '$1 == snap { print $7; found = 1 } END { if (!found) exit 1 }' "$snaps_file")"
    dataset="$(awk -F '\t' -v snap="$snap" '$1 == snap { print $2; found = 1 } END { if (!found) exit 1 }' "$snaps_file")"
    delay_polls="$(awk -F '\t' -v snap="$snap" '$1 == snap { print $8; found = 1 } END { if (!found) exit 1 }' "$snaps_file")"
    pool="$(pool_for_dataset "$dataset")"

    tmp="$(mktemp "${snaps_file}.tmp.XXXXXX")"
    awk -F '\t' -v snap="$snap" '$1 != snap { print }' "$snaps_file" > "$tmp"
    mv "$tmp" "$snaps_file"

    if [[ "$actual_reclaim" =~ ^[0-9]+$ ]] && (( actual_reclaim > 0 )); then
      if [[ "$delay_polls" =~ ^[0-9]+$ ]] && (( delay_polls > 0 )); then
        printf "%s\t%s\t%s\n" "$pool" "$actual_reclaim" "$delay_polls" >> "$pending_file"
      else
        update_pool_avail "$pool" "$actual_reclaim"
      fi
    fi
    ;;
  *)
    echo "Unsupported mock zfs command: ${cmd}" >&2
    exit 1
    ;;
esac
EOF

  chmod +x "${case_dir}/mockbin/zfs"
}

new_case() {
  local name="$1"
  local case_dir="${TEST_ROOT}/${name}"

  mkdir -p "${case_dir}/config" "${case_dir}/run" "${case_dir}/log" "${case_dir}/state" "${case_dir}/mockbin"
  : > "${case_dir}/state/pools.tsv"
  : > "${case_dir}/state/snaps.tsv"
  : > "${case_dir}/state/pending_reclaims.tsv"
  : > "${case_dir}/config/snapshot_leases.tsv"

  write_test_script "${case_dir}"
  write_mock_date "${case_dir}"
  write_mock_zpool "${case_dir}"
  write_mock_zfs "${case_dir}"

  printf '%s\n' "${case_dir}"
}

write_config() {
  local case_dir="$1"
  local datasets="$2"
  cat > "${case_dir}/config/zfs_autosnapshot.conf" <<EOF
DATASETS="${datasets}"
PREFIX="autosnapshot-"
DRY_RUN=0
KEEP_ALL_FOR_DAYS=14
KEEP_DAILY_UNTIL_DAYS=30
KEEP_WEEKLY_UNTIL_DAYS=183
KEEP_LOG_RUNS=2
EOF
}

run_case() {
  local case_dir="$1"
  local path_prefix="${case_dir}/mockbin"

  if [[ -n "$TEST_BASH_BIN" ]]; then
    path_prefix="$(dirname "$TEST_BASH_BIN"):${path_prefix}"
  fi

  if ! PATH="${path_prefix}:${PATH}" \
    MOCK_STATE_DIR="${case_dir}/state" \
    MOCK_NOW_EPOCH="${MOCK_NOW_EPOCH:-2000000000}" \
    POST_DELETE_RECHECK_WAIT_SECONDS="${POST_DELETE_RECHECK_WAIT_SECONDS_OVERRIDE:-2}" \
    POST_DELETE_RECHECK_INTERVAL_SECONDS="${POST_DELETE_RECHECK_INTERVAL_SECONDS_OVERRIDE:-1}" \
    TZ=UTC \
      "${case_dir}/zfs_autosnapshot" > "${case_dir}/stdout.log" 2>&1; then
    TEST_FAILED=1
    echo "Case failed: ${case_dir}" >&2
    sed -n '1,240p' "${case_dir}/stdout.log" >&2 || true
    sed -n '1,240p' "${case_dir}/log/debug.log" >&2 || true
    sed -n '1,240p' "${case_dir}/log/summary.log" >&2 || true
    fail "run_case failed"
  fi
}

test_zero_change_housekeeping() {
  local case_dir
  case_dir="$(new_case zero_change)"

  write_config "${case_dir}" "tank/data:100G"
  cat > "${case_dir}/state/pools.tsv" <<'EOF'
tank	500000000000	0	1000000000000	500000000000	50%	ONLINE
EOF
  cat > "${case_dir}/state/snaps.tsv" <<'EOF'
tank/data@autosnapshot-2026-01-03_00-00-00	tank/data	1999999980	0	0	0	0
tank/data@autosnapshot-2026-01-02_00-00-00	tank/data	1999999970	0	0	0	0
tank/data@autosnapshot-2026-01-01_00-00-00	tank/data	1999999960	50	10	0	50
EOF

  run_case "${case_dir}"

  assert_snapshot_exists "${case_dir}" "tank/data@autosnapshot-2026-01-03_00-00-00"
  assert_snapshot_missing "${case_dir}" "tank/data@autosnapshot-2026-01-02_00-00-00"
  assert_file_contains "${case_dir}/log/summary.log" "Deleted as zero-change housekeeping: 1"
}

test_held_and_leased_snapshots_survive_time_cleanup() {
  local case_dir
  case_dir="$(new_case held_and_leased)"

  write_config "${case_dir}" "tank/data:100G"
  cat > "${case_dir}/state/pools.tsv" <<'EOF'
tank	500000000000	0	1000000000000	500000000000	50%	ONLINE
EOF
  cat > "${case_dir}/state/snaps.tsv" <<'EOF'
tank/data@autosnapshot-held	tank/data	1980000000	25	10	1	25
tank/data@autosnapshot-leased	tank/data	1970000000	30	12	0	30
EOF
  printf 'tank/data@autosnapshot-leased\t2000003600\tactive\tlease\n' > "${case_dir}/config/snapshot_leases.tsv"

  run_case "${case_dir}"

  assert_snapshot_exists "${case_dir}" "tank/data@autosnapshot-held"
  assert_snapshot_exists "${case_dir}" "tank/data@autosnapshot-leased"
  assert_file_contains "${case_dir}/stdout.log" "Keeping newest autosnapshot: tank/data@autosnapshot-held"
  assert_file_contains "${case_dir}/stdout.log" "Keeping expired snapshot because it is leased by the snapshot manager: tank/data@autosnapshot-leased"
  assert_file_contains "${case_dir}/log/summary.log" "Skipped because held or leased: 1"
}

test_low_space_skips_non_reclaimable_snapshots() {
  local case_dir
  case_dir="$(new_case non_reclaimable)"

  write_config "${case_dir}" "tank/data:100G"
  cat > "${case_dir}/state/pools.tsv" <<'EOF'
tank	40000000000	0	1000000000000	40000000000	96%	ONLINE
EOF
  cat > "${case_dir}/state/snaps.tsv" <<'EOF'
tank/data@autosnapshot-a	tank/data	1999999000	0	10	0	0
tank/data@autosnapshot-b	tank/data	1999998900	0	15	0	0
EOF

  run_case "${case_dir}"

  assert_snapshot_exists "${case_dir}" "tank/data@autosnapshot-a"
  assert_snapshot_exists "${case_dir}" "tank/data@autosnapshot-b"
  assert_file_contains "${case_dir}/stdout.log" "Keeping newest autosnapshot: tank/data@autosnapshot-a"
  assert_file_contains "${case_dir}/log/summary.log" "Skipped because delete would reclaim no space: 1"
  assert_file_contains "${case_dir}/log/summary.log" "Pools left below target because reclaim is blocked: 1"
  assert_file_contains "${case_dir}/stdout.log" "Skipping snapshot create for tank/data because pool tank stayed below its free-space target and reclaim is blocked."
}

test_low_space_stops_after_no_progress_delete() {
  local case_dir
  case_dir="$(new_case no_progress)"

  write_config "${case_dir}" "tank/data:100G"
  cat > "${case_dir}/state/pools.tsv" <<'EOF'
tank	40000000000	0	1000000000000	40000000000	96%	ONLINE
EOF
  cat > "${case_dir}/state/snaps.tsv" <<'EOF'
tank/data@autosnapshot-a	tank/data	1999998800	70000000000	10	0	0
tank/data@autosnapshot-b	tank/data	1999998900	30000000000	10	0	30000000000
EOF

  run_case "${case_dir}"

  assert_snapshot_missing "${case_dir}" "tank/data@autosnapshot-a"
  assert_snapshot_exists "${case_dir}" "tank/data@autosnapshot-b"
  assert_file_contains "${case_dir}/stdout.log" "did not increase effective free space"
  assert_file_contains "${case_dir}/log/summary.log" "Pools left below target because reclaim is blocked: 1"
}

test_low_space_waits_for_delayed_reclaim_accounting() {
  local case_dir
  case_dir="$(new_case delayed_reclaim)"

  write_config "${case_dir}" "tank/data:100G"
  cat > "${case_dir}/state/pools.tsv" <<'EOF'
tank	40000000000	0	1000000000000	40000000000	96%	ONLINE
EOF
  cat > "${case_dir}/state/snaps.tsv" <<'EOF'
tank/data@autosnapshot-old	tank/data	1999998800	70000000000	10	0	70000000000	2
tank/data@autosnapshot-new	tank/data	1999999900	0	0	0	0	0
EOF

  run_case "${case_dir}"

  assert_snapshot_missing "${case_dir}" "tank/data@autosnapshot-old"
  assert_snapshot_exists "${case_dir}" "tank/data@autosnapshot-new"
  assert_file_contains "${case_dir}/stdout.log" "waiting up to 2s for free-space accounting to update after deleting tank/data@autosnapshot-old"
  assert_file_contains "${case_dir}/stdout.log" "Pool tank OK: effective_avail=110000000000 bytes (>= 107374182400)."
  assert_file_contains "${case_dir}/log/summary.log" "Pools left below target because reclaim is blocked: 0"
}

test_low_space_never_deletes_newest_snapshot() {
  local case_dir
  case_dir="$(new_case latest_protected)"

  write_config "${case_dir}" "tank/data:100G"
  cat > "${case_dir}/state/pools.tsv" <<'EOF'
tank	40000000000	0	1000000000000	40000000000	96%	ONLINE
EOF
  cat > "${case_dir}/state/snaps.tsv" <<'EOF'
tank/data@autosnapshot-old	tank/data	1999998800	30000000000	10	0	30000000000
tank/data@autosnapshot-new	tank/data	1999999900	70000000000	10	0	70000000000
EOF

  run_case "${case_dir}"

  assert_snapshot_missing "${case_dir}" "tank/data@autosnapshot-old"
  assert_snapshot_exists "${case_dir}" "tank/data@autosnapshot-new"
  assert_file_contains "${case_dir}/stdout.log" "Keeping newest autosnapshot: tank/data@autosnapshot-new"
  assert_file_contains "${case_dir}/log/summary.log" "Pools left below target because reclaim is blocked: 1"
}

main() {
  test_zero_change_housekeeping
  echo "PASS: zero-change housekeeping"

  test_held_and_leased_snapshots_survive_time_cleanup
  echo "PASS: held/leased snapshots survive time cleanup"

  test_low_space_skips_non_reclaimable_snapshots
  echo "PASS: low-space skips non-reclaimable snapshots"

  test_low_space_stops_after_no_progress_delete
  echo "PASS: low-space stops after no-progress delete"

  test_low_space_waits_for_delayed_reclaim_accounting
  echo "PASS: low-space waits for delayed reclaim accounting"

  test_low_space_never_deletes_newest_snapshot
  echo "PASS: low-space never deletes newest snapshot"

  echo "All Stage 1 tests passed."
}

main "$@"
