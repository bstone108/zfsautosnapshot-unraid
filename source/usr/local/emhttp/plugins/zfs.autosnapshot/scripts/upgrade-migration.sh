#!/bin/bash
# Janitorial upgrade sweep. This is not the plugin install script.
#
# post-install.sh still stops workers, refreshes cron, and removes residue
# during a normal install. This script is the second pass: when the installed
# version changed since the last successful sweep, remove the same leftover
# files if they are still present. An install that skipped post-install
# (manual installpkg, an interrupted update) is covered the next time a
# snapshot run, the queue kicker, or the disks_mounted hook starts.
#
# Each step acts only when that leftover exists. Nothing here reads or writes
# user settings, cron, schedules, datasets, or snapshots, and nothing here
# removes live queue files, locks, or active markers.
set -euo pipefail

zfsas_migration_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

zfsas_migration_sanitize() {
  printf '%s' "$1" | tr '\r\n' '  '
}

zfsas_migration_boot_dir() {
  printf '%s\n' "${ZFSAS_BOOT_PLUGIN_DIR:-/boot/config/plugins/zfs.autosnapshot}"
}

zfsas_migration_plugin_dir() {
  printf '%s\n' "${ZFSAS_PLUGIN_DIR:-/usr/local/emhttp/plugins/zfs.autosnapshot}"
}

zfsas_migration_sbin_dir() {
  printf '%s\n' "${ZFSAS_SBIN_DIR:-/usr/local/sbin}"
}

zfsas_migration_version_file() {
  if [[ -n "${ZFSAS_MIGRATION_VERSION_FILE:-}" ]]; then
    printf '%s\n' "$ZFSAS_MIGRATION_VERSION_FILE"
    return 0
  fi
  printf '%s\n' "$(zfsas_migration_boot_dir)/last-migrated-version"
}

zfsas_migration_log_file() {
  printf '%s\n' "${ZFSAS_MIGRATION_LOG_FILE:-/var/log/zfs_autosnapshot.log}"
}

zfsas_migration_lock_file() {
  printf '%s\n' "${ZFSAS_MIGRATION_LOCK_FILE:-/var/run/zfs-autosnapshot/upgrade-migration.lock}"
}

zfsas_migration_same_file() {
  local left="$1"
  local right="$2"
  local left_real right_real
  [[ -n "$left" && -n "$right" ]] || return 1
  if command -v readlink >/dev/null 2>&1; then
    left_real="$(readlink -f "$left" 2>/dev/null || true)"
    right_real="$(readlink -f "$right" 2>/dev/null || true)"
    [[ -n "$left_real" && "$left_real" == "$right_real" ]]
    return
  fi
  [[ "$left" == "$right" ]]
}

zfsas_migration_log() {
  local line log_file log_dir stdout_target=""
  line="$(date +'%Y-%m-%d %H:%M:%S %Z') Upgrade cleanup: $(zfsas_migration_sanitize "$*")"
  printf '%s\n' "$line"
  log_file="$(zfsas_migration_log_file)"
  # Snapshot cron already appends stdout to the plugin log. Append a second
  # copy only when this process is not already writing there. An explicit
  # log path (tests, or a caller whose stdout is a different log) is always
  # written so the plugin log still receives the line.
  if [[ -z "${ZFSAS_MIGRATION_LOG_FILE:-}" && -e /proc/self/fd/1 ]]; then
    stdout_target="$(readlink -f /proc/self/fd/1 2>/dev/null || true)"
    if zfsas_migration_same_file "$stdout_target" "$log_file"; then
      return 0
    fi
  fi
  log_dir="$(dirname "$log_file")"
  if [[ -n "$log_dir" && "$log_dir" != "." ]]; then
    mkdir -p "$log_dir" 2>/dev/null || true
  fi
  printf '%s\n' "$line" >>"$log_file" 2>/dev/null || true
}

zfsas_migration_log_absent() {
  [[ "${ZFSAS_MIGRATION_LOG_ABSENT:-0}" == "1" ]]
}

zfsas_migration_version_is_safe() {
  local version="$1"
  [[ -n "$version" ]] || return 1
  [[ "$version" != "unknown" ]] || return 1
  [[ "$version" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
}

zfsas_migration_version_from_plg() {
  local manifest="$1"
  local version=""
  [[ -r "$manifest" ]] || return 1
  version="$(sed -n 's/.*<PLUGIN[^>]*version="\([^"]\+\)".*/\1/p' "$manifest" | head -n 1)"
  version="$(zfsas_migration_trim "$version")"
  zfsas_migration_version_is_safe "$version" || return 1
  printf '%s\n' "$version"
}

zfsas_migration_version_from_package_db() {
  local pkg_dir="$1"
  local entry base version
  [[ -d "$pkg_dir" ]] || return 1
  version=""
  for entry in "$pkg_dir"/zfs-autosnapshot-*; do
    [[ -e "$entry" ]] || continue
    base="$(basename "$entry")"
    if [[ "$base" =~ ^zfs-autosnapshot-(.+)-noarch-[0-9]+$ ]]; then
      version="${BASH_REMATCH[1]}"
      break
    fi
  done
  zfsas_migration_version_is_safe "$version" || return 1
  printf '%s\n' "$version"
}

# Installed version is the package on disk when that record exists, because a
# manual installpkg updates the package without rewriting the plg. The plg
# version is the fallback. An empty result is a failure so the sweep retries.
zfsas_migration_installed_version() {
  local version="" manifest pkg_dir
  if [[ -n "${ZFSAS_INSTALLED_VERSION:-}" ]]; then
    version="$(zfsas_migration_trim "$ZFSAS_INSTALLED_VERSION")"
    zfsas_migration_version_is_safe "$version" || return 1
    printf '%s\n' "$version"
    return 0
  fi

  pkg_dir="${ZFSAS_PACKAGE_DB_DIR:-/var/log/packages}"
  if version="$(zfsas_migration_version_from_package_db "$pkg_dir" 2>/dev/null)"; then
    printf '%s\n' "$version"
    return 0
  fi

  if [[ -n "${ZFSAS_PLUGIN_MANIFEST:-}" || -n "${ZFSAS_BOOT_PLUGIN_MANIFEST:-}" ]]; then
    for manifest in "${ZFSAS_PLUGIN_MANIFEST:-}" "${ZFSAS_BOOT_PLUGIN_MANIFEST:-}"; do
      [[ -n "$manifest" ]] || continue
      if version="$(zfsas_migration_version_from_plg "$manifest" 2>/dev/null)"; then
        printf '%s\n' "$version"
        return 0
      fi
    done
    return 1
  fi

  for manifest in "/var/log/plugins/zfs.autosnapshot.plg" "/boot/config/plugins/zfs.autosnapshot.plg"; do
    if version="$(zfsas_migration_version_from_plg "$manifest" 2>/dev/null)"; then
      printf '%s\n' "$version"
      return 0
    fi
  done
  return 1
}

zfsas_migration_recorded_version() {
  local dest line
  dest="$(zfsas_migration_version_file)"
  [[ -f "$dest" && ! -L "$dest" ]] || return 0
  line="$(head -n 1 "$dest" 2>/dev/null || true)"
  line="$(zfsas_migration_trim "$line")"
  printf '%s\n' "$line"
}

zfsas_migration_record_version() {
  local version="$1"
  local dest dir tmp
  zfsas_migration_version_is_safe "$version" || return 1
  dest="$(zfsas_migration_version_file)"
  dir="$(dirname "$dest")"
  case "$dest" in
    */ops_queue | */ops_queue/*) return 1 ;;
  esac
  mkdir -p "$dir" || return 1
  tmp="$(mktemp "${dest}.tmp.XXXXXX")" || return 1
  if ! printf '%s\n' "$version" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$dest"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 0644 "$dest" 2>/dev/null || true
}

zfsas_migration_dir_basename_ok() {
  local path="$1"
  local base
  [[ -n "$path" && "$path" != "/" ]] || return 1
  base="$(basename "$path")"
  [[ "$base" == "zfs.autosnapshot" ]] || return 1
  case "$path" in
    / | /boot | /boot/config | /boot/config/plugins | /usr | /usr/local | /usr/local/emhttp | /usr/local/emhttp/plugins)
      return 1
      ;;
  esac
}

zfsas_migration_acquire_lock() {
  local lock_file dir waited holder lock_dir
  if ((${ZFSAS_MIGRATION_LOCK_DEPTH:-0} > 0)); then
    ZFSAS_MIGRATION_LOCK_DEPTH=$((ZFSAS_MIGRATION_LOCK_DEPTH + 1))
    return 0
  fi

  lock_file="$(zfsas_migration_lock_file)"
  dir="$(dirname "$lock_file")"
  mkdir -p "$dir" || return 1

  if command -v flock >/dev/null 2>&1; then
    exec {ZFSAS_MIGRATION_LOCK_FD}>"$lock_file" || return 1
    waited=0
    while ((waited < 60)); do
      if flock -n "$ZFSAS_MIGRATION_LOCK_FD"; then
        ZFSAS_MIGRATION_LOCK_DEPTH=1
        return 0
      fi
      sleep 1
      waited=$((waited + 1))
    done
    eval "exec ${ZFSAS_MIGRATION_LOCK_FD}>&-" || true
    ZFSAS_MIGRATION_LOCK_FD=""
    return 1
  fi

  lock_dir="${lock_file}.d"
  case "$lock_dir" in
    *.d) ;;
    *) return 1 ;;
  esac
  waited=0
  while ((waited < 60)); do
    if mkdir "$lock_dir" 2>/dev/null; then
      printf '%s\n' "$$" >"${lock_dir}/pid" || true
      ZFSAS_MIGRATION_LOCK_DIR="$lock_dir"
      ZFSAS_MIGRATION_LOCK_DEPTH=1
      return 0
    fi
    holder=""
    if [[ -r "${lock_dir}/pid" ]]; then
      holder="$(head -n 1 "${lock_dir}/pid" 2>/dev/null || true)"
    fi
    if [[ "$holder" =~ ^[0-9]+$ ]] && [[ ! -d "/proc/${holder}" ]]; then
      rm -rf "$lock_dir" 2>/dev/null || true
      continue
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

zfsas_migration_release_lock() {
  local lock_dir
  if ((${ZFSAS_MIGRATION_LOCK_DEPTH:-0} > 1)); then
    ZFSAS_MIGRATION_LOCK_DEPTH=$((ZFSAS_MIGRATION_LOCK_DEPTH - 1))
    return 0
  fi
  ZFSAS_MIGRATION_LOCK_DEPTH=0
  if [[ -n "${ZFSAS_MIGRATION_LOCK_FD:-}" ]]; then
    flock -u "$ZFSAS_MIGRATION_LOCK_FD" 2>/dev/null || true
    eval "exec ${ZFSAS_MIGRATION_LOCK_FD}>&-" || true
    ZFSAS_MIGRATION_LOCK_FD=""
  fi
  lock_dir="${ZFSAS_MIGRATION_LOCK_DIR:-}"
  if [[ -n "$lock_dir" ]]; then
    case "$lock_dir" in
      *.d) rm -rf "$lock_dir" 2>/dev/null || true ;;
    esac
    ZFSAS_MIGRATION_LOCK_DIR=""
  fi
}

zfsas_migration_call_locked() {
  local fn="$1"
  local rc=0
  if zfsas_migration_acquire_lock; then
    "$fn" || rc=$?
    zfsas_migration_release_lock || true
    return "$rc"
  fi
  zfsas_migration_log "ERROR: upgrade cleanup lock was not acquired. Continuing this cleanup without the lock."
  "$fn"
}

zfsas_migration_remove_appledouble_unlocked() {
  local root file found=0 list
  root="$(zfsas_migration_plugin_dir)"
  if ! zfsas_migration_dir_basename_ok "$root"; then
    zfsas_migration_log "ERROR: refusing to scan an unsafe plugin directory for metadata: ${root}"
    return 1
  fi
  if [[ ! -d "$root" ]]; then
    if zfsas_migration_log_absent; then
      zfsas_migration_log "AppleDouble metadata: plugin directory is not present."
    fi
    return 0
  fi

  list="$(mktemp)" || return 1
  if ! find "$root" -type f \( -name '._*' -o -name '.DS_Store' \) -print0 >"$list"; then
    rm -f "$list"
    zfsas_migration_log "ERROR: could not scan ${root} for AppleDouble metadata."
    return 1
  fi
  while IFS= read -r -d '' file; do
    [[ -n "$file" ]] || continue
    found=1
    if ! rm -f "$file"; then
      rm -f "$list"
      zfsas_migration_log "ERROR: could not remove AppleDouble metadata: ${file}"
      return 1
    fi
    zfsas_migration_log "Removed AppleDouble metadata: ${file}"
  done <"$list"
  rm -f "$list"

  if ((found == 0)) && zfsas_migration_log_absent; then
    zfsas_migration_log "AppleDouble metadata: none in ${root}"
  fi
}

zfsas_migration_remove_appledouble() {
  zfsas_migration_call_locked zfsas_migration_remove_appledouble_unlocked
}

zfsas_migration_remove_legacy_ops_queue_unlocked() {
  local boot path count noun
  boot="$(zfsas_migration_boot_dir)"
  if ! zfsas_migration_dir_basename_ok "$boot"; then
    zfsas_migration_log "ERROR: refusing to touch an unsafe flash plugin directory: ${boot}"
    return 1
  fi
  path="${boot%/}/ops_queue"
  case "$path" in
    */zfs.autosnapshot/ops_queue) ;;
    *)
      zfsas_migration_log "ERROR: refusing to remove unexpected legacy ops_queue path: ${path}"
      return 1
      ;;
  esac

  if [[ -L "$path" ]]; then
    if rm -f "$path"; then
      zfsas_migration_log "Removed legacy flash ops_queue symlink without following it: ${path}"
      return 0
    fi
    zfsas_migration_log "ERROR: could not remove legacy flash ops_queue symlink: ${path}"
    return 1
  fi

  if [[ ! -e "$path" ]]; then
    if zfsas_migration_log_absent; then
      zfsas_migration_log "Legacy flash ops_queue: not present."
    fi
    return 0
  fi

  if [[ -d "$path" ]]; then
    count="$(find "$path" -mindepth 1 -print 2>/dev/null | wc -l | tr -d '[:space:]')" || {
      zfsas_migration_log "ERROR: could not read legacy flash ops_queue directory: ${path}"
      return 1
    }
    noun="entries"
    if [[ "${count:-0}" == "1" ]]; then
      noun="entry"
    fi
    if rm -rf "$path"; then
      zfsas_migration_log "Removed legacy flash ops_queue directory (${count:-0} ${noun}): ${path}"
      return 0
    fi
    zfsas_migration_log "ERROR: could not remove legacy flash ops_queue directory: ${path}"
    return 1
  fi

  if rm -f "$path"; then
    zfsas_migration_log "Removed legacy flash ops_queue file: ${path}"
    return 0
  fi
  zfsas_migration_log "ERROR: could not remove legacy flash ops_queue file: ${path}"
  return 1
}

zfsas_migration_remove_legacy_ops_queue() {
  zfsas_migration_call_locked zfsas_migration_remove_legacy_ops_queue_unlocked
}

zfsas_migration_remove_one_file() {
  local path="$1"
  local label="$2"
  if [[ -L "$path" || -f "$path" ]]; then
    if rm -f "$path"; then
      zfsas_migration_log "Removed ${label}: ${path}"
      return 0
    fi
    zfsas_migration_log "ERROR: could not remove ${label}: ${path}"
    return 1
  fi
  if [[ -e "$path" ]]; then
    zfsas_migration_log "ERROR: ${label} is not a file and was left in place: ${path}"
    return 1
  fi
  return 0
}

zfsas_migration_remove_stale_recovery_files_unlocked() {
  local plugin sbin path removed=0
  local -a paths=()
  plugin="$(zfsas_migration_plugin_dir)"
  sbin="$(zfsas_migration_sbin_dir)"
  if ! zfsas_migration_dir_basename_ok "$plugin"; then
    zfsas_migration_log "ERROR: refusing to scan an unsafe plugin directory for stale tools: ${plugin}"
    return 1
  fi
  case "$sbin" in
    "" | / | /usr | /usr/local | /bin | /usr/bin)
      zfsas_migration_log "ERROR: refusing to scan an unsafe sbin directory for stale tools: ${sbin}"
      return 1
      ;;
  esac

  paths=(
    "${plugin}/php/recovery-tools.php"
    "${plugin}/php/recovery-status.php"
    "${plugin}/php/recovery-action.php"
    "${plugin}/php/recovery-helpers.php"
    "${sbin}/zfs_autosnapshot_recovery_scan"
  )
  for path in "${paths[@]}"; do
    case "$path" in
      */recovery-tools.php | */recovery-status.php | */recovery-action.php | */recovery-helpers.php | */zfs_autosnapshot_recovery_scan) ;;
      *)
        zfsas_migration_log "ERROR: refusing to remove unexpected stale-tool path: ${path}"
        return 1
        ;;
    esac
    if [[ -e "$path" || -L "$path" ]]; then
      zfsas_migration_remove_one_file "$path" "stale Recovery/Repair tool file" || return 1
      removed=1
    fi
  done
  if ((removed == 0)) && zfsas_migration_log_absent; then
    zfsas_migration_log "Stale Recovery/Repair tool files: none."
  fi
}

zfsas_migration_remove_stale_recovery_files() {
  zfsas_migration_call_locked zfsas_migration_remove_stale_recovery_files_unlocked
}

# Runs every residue step. A later failure does not skip the remaining steps,
# and any failure leaves the version unrecorded so the next run retries.
zfsas_migration_clean_residue_unlocked() {
  local failed=0
  zfsas_migration_remove_appledouble_unlocked || failed=1
  zfsas_migration_remove_legacy_ops_queue_unlocked || failed=1
  zfsas_migration_remove_stale_recovery_files_unlocked || failed=1
  return "$failed"
}

zfsas_run_upgrade_migration() {
  local installed="" recorded="" failed=0
  if ! installed="$(zfsas_migration_installed_version)"; then
    zfsas_migration_log "ERROR: installed version could not be read. Upgrade cleanup will retry on the next run."
    return 1
  fi
  recorded="$(zfsas_migration_recorded_version)"
  if [[ "$recorded" == "$installed" ]]; then
    return 0
  fi

  if ! zfsas_migration_acquire_lock; then
    zfsas_migration_log "ERROR: upgrade cleanup lock was busy for ${installed}. Version was not recorded. It will retry on the next run."
    return 1
  fi

  recorded="$(zfsas_migration_recorded_version)"
  if [[ "$recorded" == "$installed" ]]; then
    zfsas_migration_release_lock || true
    return 0
  fi

  ZFSAS_MIGRATION_LOG_ABSENT=1
  zfsas_migration_log "Installed version ${installed} differs from last cleaned version '${recorded:-none}'. Checking for leftover upgrade residue."
  zfsas_migration_clean_residue_unlocked || failed=1
  if ((failed != 0)); then
    zfsas_migration_log "ERROR: upgrade cleanup for ${installed} did not finish. Version was not recorded. It will retry on the next run."
    zfsas_migration_release_lock || true
    return 1
  fi
  if ! zfsas_migration_record_version "$installed"; then
    zfsas_migration_log "ERROR: upgrade cleanup for ${installed} finished but the version could not be recorded. It will retry on the next run."
    zfsas_migration_release_lock || true
    return 1
  fi
  zfsas_migration_log "Recorded upgrade cleanup version ${installed}."
  zfsas_migration_release_lock || true
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  zfsas_run_upgrade_migration
fi
