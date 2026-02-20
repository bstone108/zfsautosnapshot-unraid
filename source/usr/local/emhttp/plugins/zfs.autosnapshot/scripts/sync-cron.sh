#!/bin/bash
set -euo pipefail

PLUGIN_NAME="zfs.autosnapshot"
CONFIG_DIR="/boot/config/plugins/${PLUGIN_NAME}"
CONFIG_FILE="${CONFIG_DIR}/zfs_autosnapshot.conf"
CRON_FILE="/etc/cron.d/zfs_autosnapshot"
RUN_CMD="/usr/local/sbin/zfs_autosnapshot"

SCHEDULE_MODE="disabled"
SCHEDULE_EVERY_MINUTES="15"
SCHEDULE_EVERY_HOURS="1"
SCHEDULE_DAILY_HOUR="3"
SCHEDULE_DAILY_MINUTE="0"
SCHEDULE_WEEKLY_DAY="0"
SCHEDULE_WEEKLY_HOUR="3"
SCHEDULE_WEEKLY_MINUTE="0"
CUSTOM_CRON_SCHEDULE=""
CRON_SCHEDULE=""

trim() {
	local s="$1"
	s="${s#"${s%%[![:space:]]*}"}"
	s="${s%"${s##*[![:space:]]}"}"
	printf '%s' "$s"
}

parse_config_value() {
	local raw="$1"
	local value

	value="$(trim "$raw")"
	[[ -n "$value" ]] || {
		printf ''
		return 0
	}

	if [[ "$value" == \"*\" && "$value" == *\" && ${#value} -ge 2 ]]; then
		value="${value:1:${#value}-2}"
		value="${value//\\\\/\\}"
		value="${value//\\\"/\"}"
		printf '%s' "$value"
		return 0
	fi

	if [[ "$value" == \'*\' && "$value" == *\' && ${#value} -ge 2 ]]; then
		value="${value:1:${#value}-2}"
		printf '%s' "$value"
		return 0
	fi

	value="${value%%#*}"
	value="$(trim "$value")"
	printf '%s' "$value"
}

apply_config_key() {
	local key="$1"
	local value="$2"

	case "$key" in
	SCHEDULE_MODE | SCHEDULE_EVERY_MINUTES | SCHEDULE_EVERY_HOURS | SCHEDULE_DAILY_HOUR | SCHEDULE_DAILY_MINUTE | SCHEDULE_WEEKLY_DAY | SCHEDULE_WEEKLY_HOUR | SCHEDULE_WEEKLY_MINUTE | CUSTOM_CRON_SCHEDULE | CRON_SCHEDULE)
		if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
			return 0
		fi
		printf -v "$key" '%s' "$value"
		;;
	esac
}

load_config_file() {
	local path="$1"
	local line key raw value

	[[ -f "$path" ]] || return 0

	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ "$line" =~ ^[[:space:]]*# ]] && continue
		[[ "$line" =~ ^[[:space:]]*$ ]] && continue

		if [[ "$line" =~ ^[[:space:]]*([A-Z0-9_]+)[[:space:]]*=(.*)$ ]]; then
			key="${BASH_REMATCH[1]}"
			raw="${BASH_REMATCH[2]}"
			value="$(parse_config_value "$raw")"
			apply_config_key "$key" "$value"
		fi
	done <"$path"
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

	if ((value < min || value > max)); then
		echo "Invalid $name '$value' (allowed range: $min-$max)." >&2
		return 1
	fi

	echo "$value"
}

normalize_weekday() {
	local value
	value="$(echo "$1" | tr '[:upper:]' '[:lower:]')"

	case "$value" in
	0 | 7 | sun | sunday) echo 0 ;;
	1 | mon | monday) echo 1 ;;
	2 | tue | tues | tuesday) echo 2 ;;
	3 | wed | wednesday) echo 3 ;;
	4 | thu | thur | thurs | thursday) echo 4 ;;
	5 | fri | friday) echo 5 ;;
	6 | sat | saturday) echo 6 ;;
	*)
		echo "Invalid SCHEDULE_WEEKLY_DAY '$1' (use 0-6 or weekday name)." >&2
		return 1
		;;
	esac
}

validate_cron_5_fields() {
	local cron="$1"
	local count
	count="$(awk '{print NF}' <<<"$cron")"
	[[ "$count" == "5" ]]
}

validate_cron_safe_chars() {
	local cron="$1"
	[[ "$cron" =~ ^[A-Za-z0-9*/,\ -]+$ ]]
}

refresh_cron_runtime() {
	local reloaded=0

	if command -v update_cron >/dev/null 2>&1; then
		update_cron
		reloaded=1
	fi

	if [[ -x /etc/rc.d/rc.crond ]]; then
		/etc/rc.d/rc.crond restart >/dev/null 2>&1 || true
		reloaded=1
	fi

	if ((reloaded)); then
		echo "Cron runtime refreshed."
	else
		echo "Cron runtime refresh skipped (update_cron/rc.crond not found)." >&2
	fi
}

build_cron_schedule() {
	local mode
	mode="$(echo "${SCHEDULE_MODE:-}" | tr '[:upper:]' '[:lower:]')"

	if [[ -z "$mode" ]]; then
		# Backward compatibility with older config files.
		if [[ -n "${CRON_SCHEDULE:-}" ]]; then
			local fallback
			fallback="$(trim "$CRON_SCHEDULE")"
			if ! validate_cron_5_fields "$fallback"; then
				echo "Invalid CRON_SCHEDULE '$fallback' (expected exactly 5 fields)." >&2
				return 1
			fi
			if ! validate_cron_safe_chars "$fallback"; then
				echo "Invalid CRON_SCHEDULE '$fallback' (contains unsupported characters)." >&2
				return 1
			fi
			echo "$fallback"
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
		if ((interval == 1)); then
			echo "* * * * *"
		else
			echo "*/${interval} * * * *"
		fi
		;;

	hourly)
		local interval
		interval="$(require_int_in_range "SCHEDULE_EVERY_HOURS" "${SCHEDULE_EVERY_HOURS:-1}" 1 24)" || return 1
		if ((interval == 1)); then
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
		if ! validate_cron_safe_chars "$cron"; then
			echo "Invalid CUSTOM_CRON_SCHEDULE '$cron' (contains unsupported characters)." >&2
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

load_config_file "$CONFIG_FILE"

CRON_SCHEDULE_EFFECTIVE="$(build_cron_schedule)" || exit 1

if [[ -z "$CRON_SCHEDULE_EFFECTIVE" ]]; then
	rm -f "$CRON_FILE"
	refresh_cron_runtime
	echo "Cron schedule disabled."
	exit 0
fi

if ! validate_cron_5_fields "$CRON_SCHEDULE_EFFECTIVE"; then
	echo "Invalid cron schedule '$CRON_SCHEDULE_EFFECTIVE' (expected 5 fields)." >&2
	exit 1
fi

if ! validate_cron_safe_chars "$CRON_SCHEDULE_EFFECTIVE"; then
	echo "Invalid cron schedule '$CRON_SCHEDULE_EFFECTIVE' (contains unsupported characters)." >&2
	exit 1
fi

{
	echo "# Managed by ${PLUGIN_NAME}; edit ${CONFIG_FILE}"
	# Unraid uses BusyBox crond format in /etc/cron.d: no username column.
	echo "${CRON_SCHEDULE_EFFECTIVE} ${RUN_CMD} >> /var/log/zfs_autosnapshot.log 2>&1"
} >"$CRON_FILE"

chmod 0644 "$CRON_FILE"
refresh_cron_runtime

echo "Cron schedule applied: $CRON_SCHEDULE_EFFECTIVE"
