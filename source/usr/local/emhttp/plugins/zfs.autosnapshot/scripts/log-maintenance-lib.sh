#!/bin/bash

zfsas_log_apply_owner() {
  local path="$1"
  chown nobody "$path" >/dev/null 2>&1 || true
  chgrp users "$path" >/dev/null 2>&1 || true
}

zfsas_log_dir_is_plugin_owned() {
  local dir="$1"

  case "$dir" in
    /var/log/zfs_autosnapshot*|/var/run/zfs-autosnapshot*|/tmp/zfs-autosnapshot*|/boot/config/plugins/zfs.autosnapshot/*)
      return 0
      ;;
  esac

  return 1
}

zfsas_log_repair_system_dir_if_needed() {
  local dir="$1"

  [[ "$dir" == "/var/log" ]] || return 0
  chmod 0755 "$dir" >/dev/null 2>&1 || true
  chown root "$dir" >/dev/null 2>&1 || true
  chgrp root "$dir" >/dev/null 2>&1 || true
}

zfsas_log_ensure_file() {
  local path="$1"
  local mode="${2:-0640}"
  local dir

  dir="$(dirname "$path")"
  mkdir -p "$dir" >/dev/null 2>&1 || return 1
  if zfsas_log_dir_is_plugin_owned "$dir"; then
    chmod 0775 "$dir" >/dev/null 2>&1 || true
    zfsas_log_apply_owner "$dir"
  else
    zfsas_log_repair_system_dir_if_needed "$dir"
  fi

  touch "$path" >/dev/null 2>&1 || return 1
  chmod "$mode" "$path" >/dev/null 2>&1 || true
  zfsas_log_apply_owner "$path"
}

zfsas_log_archive_path() {
  local path="$1"
  if [[ "$path" == *.log ]]; then
    printf '%s.archive.log' "${path%.log}"
    return 0
  fi

  printf '%s.archive' "$path"
}

zfsas_log_sanitize_text() {
  local value="$1"

  printf '%s' "$value" | sed -E \
    -e 's/([Aa]uthorization:[[:space:]]*Bearer[[:space:]]+)[^[:space:]]+/\1<redacted>/g' \
    -e 's/((api[_-]?key|token|secret|password|passwd|passphrase|credential)[[:space:]]*[:=][[:space:]]*)(\"[^\"]*\"|'\''[^'\'']*'\''|[^[:space:]]+)/\1<redacted>/Ig'
}

zfsas_log_compact_segment() {
  local input_path="$1"
  local output_path="$2"
  local context_lines="$3"
  local interesting_re="$4"
  local boundary_re="$5"

  awk \
    -v context="$context_lines" \
    -v interesting_re="$interesting_re" \
    -v boundary_re="$boundary_re" '
      {
        lines[NR] = $0
        lower = tolower($0)
        interesting = (interesting_re != "" && lower ~ interesting_re)
        boundary = (boundary_re != "" && lower ~ boundary_re)

        if (interesting || boundary) {
          start = NR - context
          if (start < 1) {
            start = 1
          }
          stop = NR + context
          for (i = start; i <= stop; i++) {
            keep[i] = 1
          }
        }
      }
      END {
        if (NR > 0) {
          keep[1] = 1
          keep[NR] = 1
        }

        omitted = 0
        for (i = 1; i <= NR; i++) {
          if (keep[i]) {
            if (omitted > 0) {
              printf "[... omitted %d routine lines ...]\n", omitted
              omitted = 0
            }
            print lines[i]
          } else {
            omitted++
          }
        }

        if (omitted > 0) {
          printf "[... omitted %d routine lines ...]\n", omitted
        }
      }
    ' "$input_path" > "$output_path"
}

zfsas_log_trim_archive() {
  local archive_path="$1"
  local max_bytes="$2"
  local size tmp

  [[ -f "$archive_path" ]] || return 0
  [[ "$max_bytes" =~ ^[0-9]+$ ]] || return 0
  (( max_bytes > 0 )) || return 0

  size="$(wc -c < "$archive_path" 2>/dev/null | tr -d '[:space:]')"
  [[ "$size" =~ ^[0-9]+$ ]] || return 0
  (( size > max_bytes )) || return 0

  tmp="$(mktemp "${archive_path}.trim.XXXXXX")" || return 0
  {
    printf '[... older archived log entries were trimmed to stay within the RAM log budget ...]\n'
    tail -c "$max_bytes" "$archive_path" 2>/dev/null || true
  } > "$tmp"

  cat "$tmp" > "$archive_path" 2>/dev/null || true
  rm -f "$tmp" >/dev/null 2>&1 || true
  chmod 0640 "$archive_path" >/dev/null 2>&1 || true
  zfsas_log_apply_owner "$archive_path"
}

zfsas_log_compaction_lock_token() {
  local path="$1"
  local token
  token="$(printf '%s' "$path" | tr '/:' '__' | tr -c 'A-Za-z0-9._-' '_')"
  printf '%s' "$token"
}

zfsas_log_prepare_for_append() {
  local log_path="$1"
  local archive_path="${2:-}"
  local max_bytes="${3:-524288}"
  local recent_lines="${4:-400}"
  local context_lines="${5:-20}"
  local archive_max_bytes="${6:-1048576}"
  local interesting_re="${7:-error|warning|warn|fatal|failed|failure|timed out|timeout|retry|denied|refused|unreadable|stopped unexpectedly|invalid|missing|conflict|purged|no common|delayed because}"
  local boundary_re="${8:-\\[run_start\\]|result:|starting|finished|completed|queue kicker|send worker|delete daemon|snapshot manager|recovery readability scan|dataset migration}"
  local size lock_dir lock_file lock_fd=-1 tmp_old tmp_recent tmp_segment older_line_count total_lines
  local lock_token

  [[ -n "$log_path" ]] || return 0
  [[ "$max_bytes" =~ ^[0-9]+$ ]] || return 0
  (( max_bytes > 0 )) || return 0

  [[ -n "$archive_path" ]] || archive_path="$(zfsas_log_archive_path "$log_path")"

  zfsas_log_ensure_file "$log_path" 0640 || return 0
  zfsas_log_ensure_file "$archive_path" 0640 || return 0

  size="$(wc -c < "$log_path" 2>/dev/null | tr -d '[:space:]')"
  [[ "$size" =~ ^[0-9]+$ ]] || return 0
  (( size > max_bytes )) || return 0

  mkdir -p /tmp/zfs-autosnapshot-log-compact >/dev/null 2>&1 || true
  lock_token="$(zfsas_log_compaction_lock_token "$log_path")"
  lock_dir="/tmp/zfs-autosnapshot-log-compact/${lock_token}.lockdir"
  lock_file="/tmp/zfs-autosnapshot-log-compact/${lock_token}.lock"
  if command -v flock >/dev/null 2>&1; then
    : > "$lock_file" 2>/dev/null || return 0
    exec {lock_fd}> "$lock_file" || return 0
    flock -n "$lock_fd" || {
      eval "exec ${lock_fd}>&-"
      return 0
    }
  else
    if ! mkdir "$lock_dir" 2>/dev/null; then
      local stale_pid=""
      stale_pid="$(sed -n '1p' "$lock_dir/pid" 2>/dev/null || true)"
      if [[ "$stale_pid" =~ ^[0-9]+$ ]] && kill -0 "$stale_pid" >/dev/null 2>&1; then
        return 0
      fi
      rm -rf "$lock_dir" >/dev/null 2>&1 || return 0
      mkdir "$lock_dir" 2>/dev/null || return 0
    fi
    printf '%s\n' "$$" > "$lock_dir/pid" 2>/dev/null || true
  fi

  total_lines="$(wc -l < "$log_path" 2>/dev/null | tr -d '[:space:]')"
  [[ "$total_lines" =~ ^[0-9]+$ ]] || total_lines=0

  if (( total_lines > recent_lines )); then
    older_line_count=$((total_lines - recent_lines))
  else
    older_line_count=0
  fi

  tmp_old="$(mktemp "${log_path}.old.XXXXXX")" || {
    if (( lock_fd >= 0 )); then
      flock -u "$lock_fd" >/dev/null 2>&1 || true
      eval "exec ${lock_fd}>&-"
    else
      rmdir "$lock_dir" >/dev/null 2>&1 || true
    fi
    return 0
  }
  tmp_recent="$(mktemp "${log_path}.recent.XXXXXX")" || {
    rm -f "$tmp_old" >/dev/null 2>&1 || true
    if (( lock_fd >= 0 )); then
      flock -u "$lock_fd" >/dev/null 2>&1 || true
      eval "exec ${lock_fd}>&-"
    else
      rmdir "$lock_dir" >/dev/null 2>&1 || true
    fi
    return 0
  }
  tmp_segment="$(mktemp "${archive_path}.segment.XXXXXX")" || {
    rm -f "$tmp_old" "$tmp_recent" >/dev/null 2>&1 || true
    if (( lock_fd >= 0 )); then
      flock -u "$lock_fd" >/dev/null 2>&1 || true
      eval "exec ${lock_fd}>&-"
    else
      rmdir "$lock_dir" >/dev/null 2>&1 || true
    fi
    return 0
  }

  if (( older_line_count > 0 )); then
    sed -n "1,${older_line_count}p" "$log_path" > "$tmp_old" 2>/dev/null || true
  else
    : > "$tmp_old"
  fi
  tail -n "$recent_lines" "$log_path" > "$tmp_recent" 2>/dev/null || true

  if [[ -s "$tmp_old" ]]; then
    zfsas_log_compact_segment "$tmp_old" "$tmp_segment" "$context_lines" "$interesting_re" "$boundary_re"
    {
      printf '===== Archived Log Segment %s =====\n' "$(date +'%Y-%m-%d %H:%M:%S %Z')"
      printf 'Source: %s\n' "$log_path"
      printf 'Archive policy: keep recent %s lines in the active log, preserve warnings/errors with %s lines of context here.\n\n' "$recent_lines" "$context_lines"
      cat "$tmp_segment"
      printf '\n\n'
    } >> "$archive_path"
  fi

  {
    printf '%s [LOG_COMPACTED] Older routine log lines were consolidated into %s to stay within the RAM log budget.\n' "$(date +'%Y-%m-%d %H:%M:%S %Z')" "$(basename "$archive_path")"
    cat "$tmp_recent"
  } > "$log_path"

  chmod 0640 "$log_path" "$archive_path" >/dev/null 2>&1 || true
  zfsas_log_apply_owner "$log_path"
  zfsas_log_apply_owner "$archive_path"
  zfsas_log_trim_archive "$archive_path" "$archive_max_bytes"

  rm -f "$tmp_old" "$tmp_recent" "$tmp_segment" >/dev/null 2>&1 || true
  if (( lock_fd >= 0 )); then
    flock -u "$lock_fd" >/dev/null 2>&1 || true
    eval "exec ${lock_fd}>&-"
  else
    rmdir "$lock_dir" >/dev/null 2>&1 || true
  fi
}
