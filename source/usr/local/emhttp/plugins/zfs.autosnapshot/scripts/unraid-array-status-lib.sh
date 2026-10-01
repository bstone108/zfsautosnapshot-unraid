#!/bin/bash
# Shared Unraid array-status lookup for the queue kicker and dataset migrator.
# Cron's PATH often omits /usr/local/sbin, and on Unraid 7.3 /proc/mdcmd can be
# readable while cat fails with "Input/output error".

find_mdcmd() {
  # Cron's PATH is often just /bin:/usr/bin. Unraid installs mdcmd in
  # /usr/local/sbin, so a PATH lookup alone misses it.
  local explicit_path="${ZFSAS_MDCMD_EXPLICIT_PATH:-/usr/local/sbin/mdcmd}"
  local root_path="${ZFSAS_MDCMD_ROOT_PATH:-/root/mdcmd}"

  if command -v mdcmd >/dev/null 2>&1; then
    command -v mdcmd
    return 0
  fi
  if [[ -x "$explicit_path" ]]; then
    printf '%s\n' "$explicit_path"
    return 0
  fi
  [[ -x "$root_path" ]] || return 1
  printf '%s\n' "$root_path"
}

get_unraid_array_status() {
  local mdcmd_bin proc_path var_ini_path mdcmd_status proc_status
  proc_path="${ZFSAS_PROC_MDCMD_PATH:-/proc/mdcmd}"
  # ZFSAS_UNRAID_VAR_INI is the dataset migrator's existing test override.
  var_ini_path="${ZFSAS_VAR_INI_PATH:-${ZFSAS_UNRAID_VAR_INI:-/var/local/emhttp/var.ini}}"

  if mdcmd_bin="$(find_mdcmd 2>/dev/null)"; then
    if mdcmd_status="$("$mdcmd_bin" status 2>/dev/null)" && [[ -n "$mdcmd_status" ]]; then
      printf '%s\n' "$mdcmd_status"
      return 0
    fi
  fi

  # /proc/mdcmd can be readable and still fail with "Input/output error" on
  # Unraid 7.3. An empty or failed read must not count as status, or the
  # var.ini fallback below never runs.
  if [[ -r "$proc_path" ]]; then
    if proc_status="$(cat "$proc_path" 2>/dev/null)" && [[ -n "$proc_status" ]]; then
      printf '%s\n' "$proc_status"
      return 0
    fi
  fi

  if [[ -r "$var_ini_path" ]]; then
    cat "$var_ini_path"
    return 0
  fi
  return 1
}
