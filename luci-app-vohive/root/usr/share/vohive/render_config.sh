#!/bin/sh

set -eu

CONFIG_DIR="/etc/vohive/config"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
TMP_LOG_DIR="/tmp/vohive/logs"

uci_get() {
	local key="$1"
	local default="$2"
	local value

	value="$(uci -q get "vohive.main.$key" 2>/dev/null || true)"
	[ -n "$value" ] && printf '%s' "$value" || printf '%s' "$default"
}

fail() {
	printf '%s\n' "$*" >&2
	exit 1
}

yaml_quote() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/'
}

preserve_unmanaged_config() {
	local file="$1"

	[ -s "$file" ] || return 0

	awk '
		function top_key(line) {
			if (line ~ /^[^[:space:]#][^:]*:/) {
				key = line
				sub(/:.*/, "", key)
				return key
			}
			return ""
		}
		{
			key = top_key($0)
			if (key != "") {
				keep = (key != "server" && key != "web" && key != "data" && key != "log")
			}
			if (keep)
				print
		}
	' "$file"
}

host="$(uci_get host '0.0.0.0')"
port="$(uci_get port '7575')"
username="$(uci_get username 'admin')"
password="$(uci_get password 'admin')"
log_level="$(uci_get log_level 'info')"
data_path="$(uci_get data_path '/etc/vohive/data')"

case "$port" in
	''|*[!0-9]*) fail "Invalid port: $port" ;;
esac
[ "$port" -ge 1 ] && [ "$port" -le 65535 ] || fail "Invalid port: $port"

[ -n "$username" ] || fail "Username must not be empty"
[ -n "$password" ] || fail "Password must not be empty"

case "$data_path" in
	/*) ;;
	*) fail "Data path must be absolute: $data_path" ;;
esac

case "$log_level" in
	debug|info|warn|error) ;;
	*) fail "Invalid log level: $log_level" ;;
esac

mkdir -p "$CONFIG_DIR" "$data_path" "$TMP_LOG_DIR"

tmp="$CONFIG_FILE.tmp.$$"
{
	printf 'server:\n'
	printf '  host: %s\n' "$(yaml_quote "$host")"
	printf '  port: %s\n' "$port"
	printf '\n'
	printf 'web:\n'
	printf '  username: %s\n' "$(yaml_quote "$username")"
	printf '  password: %s\n' "$(yaml_quote "$password")"
	printf '\n'
	printf 'data:\n'
	printf '  path: %s\n' "$(yaml_quote "$data_path")"
	printf '\n'
	printf 'log:\n'
	printf '  level: %s\n' "$(yaml_quote "$log_level")"
	printf '  path: %s\n' "$(yaml_quote "$TMP_LOG_DIR")"
	preserved="$(preserve_unmanaged_config "$CONFIG_FILE")"
	if [ -n "$preserved" ]; then
		printf '\n'
		printf '%s\n' "$preserved"
	fi
} > "$tmp"

mv "$tmp" "$CONFIG_FILE"
