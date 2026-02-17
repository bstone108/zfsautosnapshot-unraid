#!/bin/bash
set -euo pipefail

PLUGIN_NAME="zfs.autosnapshot"
CONFIG_DIR="/boot/config/plugins/${PLUGIN_NAME}"
CONFIG_FILE="${CONFIG_DIR}/zfs_autosnapshot.conf"
CRON_FILE="/etc/cron.d/zfs_autosnapshot"
RUN_CMD="/usr/local/sbin/zfs_autosnapshot"

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

require_int_in_range() {
  local name="$1"
  local value="$2"
  local min="$3"
  local max="$4"

  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "Invalid $name '$value' (must be an integer)." >&2
    return 1
  fi

  if (( value < min || value > max )); then
    echo "Invalid $name '$value' (allowed range: $min-$max)." >&2
    return 1
  fi

  echo "$value"
}

normalize_weekday() {
  local value
  value="$(echo "$1" | tr '[:upper:]' '[:lower:]')"

  case "$value" in
    0|7|sun|sunday) echo 0 ;;
    1|mon|monday) echo 1 ;;
    2|tue|tues|tuesday) echo 2 ;;
    3|wed|wednesday) echo 3 ;;
    4|thu|thur|thurs|thursday) echo 4 ;;
    5|fri|friday) echo 5 ;;
    6|sat|saturday) echo 6 ;;
    *)
      echo "Invalid SCHEDULE_WEEKLY_DAY '$1' (use 0-6 or weekday name)." >&2
      return 1
      ;;
  esac
}

validate_cron_5_fields() {
  local cron="$1"
  local count
  count="$(awk '{print NF}' <<< "$cron")"
  [[ "$count" == "5" ]]
}

build_cron_schedule() {
  local mode
  mode="$(echo "${SCHEDULE_MODE:-}" | tr '[:upper:]' '[:lower:]')"

  if [[ -z "$mode" ]]; then
    # Backward compatibility with older config files.
    if [[ -n "${CRON_SCHEDULE:-}" ]]; then
      echo "$(trim "$CRON_SCHEDULE")"
      return 0
    fi
    mode="disabled"
  fi

  case "$mode" in
    disabled)
      echo ""
      ;;

    minutes)
      local interval
      interval="$(require_int_in_range "SCHEDULE_EVERY_MINUTES" "${SCHEDULE_EVERY_MINUTES:-15}" 1 59)" || return 1
      if (( interval == 1 )); then
        echo "* * * * *"
      else
        echo "*/${interval} * * * *"
      fi
      ;;

    hourly)
      local interval
      interval="$(require_int_in_range "SCHEDULE_EVERY_HOURS" "${SCHEDULE_EVERY_HOURS:-1}" 1 24)" || return 1
      if (( interval == 1 )); then
        echo "0 * * * *"
      else
        echo "0 */${interval} * * *"
      fi
      ;;

    daily)
      local hour minute
      hour="$(require_int_in_range "SCHEDULE_DAILY_HOUR" "${SCHEDULE_DAILY_HOUR:-3}" 0 23)" || return 1
      minute="$(require_int_in_range "SCHEDULE_DAILY_MINUTE" "${SCHEDULE_DAILY_MINUTE:-0}" 0 59)" || return 1
      echo "${minute} ${hour} * * *"
      ;;

    weekly)
      local weekday hour minute
      weekday="$(normalize_weekday "${SCHEDULE_WEEKLY_DAY:-0}")" || return 1
      hour="$(require_int_in_range "SCHEDULE_WEEKLY_HOUR" "${SCHEDULE_WEEKLY_HOUR:-3}" 0 23)" || return 1
      minute="$(require_int_in_range "SCHEDULE_WEEKLY_MINUTE" "${SCHEDULE_WEEKLY_MINUTE:-0}" 0 59)" || return 1
      echo "${minute} ${hour} * * ${weekday}"
      ;;

    custom)
      local cron
      cron="$(trim "${CUSTOM_CRON_SCHEDULE:-${CRON_SCHEDULE:-}}")"
      if [[ -z "$cron" ]]; then
        echo "SCHEDULE_MODE=custom requires CUSTOM_CRON_SCHEDULE." >&2
        return 1
      fi
      if ! validate_cron_5_fields "$cron"; then
        echo "Invalid CUSTOM_CRON_SCHEDULE '$cron' (expected exactly 5 fields)." >&2
        return 1
      fi
      echo "$cron"
      ;;

    *)
      echo "Invalid SCHEDULE_MODE '$mode' (use disabled, minutes, hourly, daily, weekly, custom)." >&2
      return 1
      ;;
  esac
}

mkdir -p "$CONFIG_DIR"

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

CRON_SCHEDULE_EFFECTIVE="$(build_cron_schedule)" || exit 1

if [[ -z "$CRON_SCHEDULE_EFFECTIVE" ]]; then
  rm -f "$CRON_FILE"
  command -v update_cron >/dev/null 2>&1 && update_cron
  echo "Cron schedule disabled."
  exit 0
fi

if ! validate_cron_5_fields "$CRON_SCHEDULE_EFFECTIVE"; then
  echo "Invalid cron schedule '$CRON_SCHEDULE_EFFECTIVE' (expected 5 fields)." >&2
  exit 1
fi

{
  echo "# Managed by ${PLUGIN_NAME}; edit ${CONFIG_FILE}"
  # Unraid uses BusyBox crond format in /etc/cron.d: no username column.
  echo "${CRON_SCHEDULE_EFFECTIVE} ${RUN_CMD} >> /var/log/zfs_autosnapshot.log 2>&1"
} > "$CRON_FILE"

chmod 0644 "$CRON_FILE"
command -v update_cron >/dev/null 2>&1 && update_cron

echo "Cron schedule applied: $CRON_SCHEDULE_EFFECTIVE"
