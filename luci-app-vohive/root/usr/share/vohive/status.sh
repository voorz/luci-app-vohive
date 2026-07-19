#!/bin/sh

. /usr/share/vohive/lib.sh

BIN="/etc/vohive/bin/vohive"
VERSION_FILE="/etc/vohive/bin/version"
ARCH_FILE="/etc/vohive/bin/arch"
METRICS_STATE="/tmp/vohive/status.metrics"

json_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g'
}

uci_get() {
	local key="$1"
	local default="$2"
	local value

	value="$(uci -q get "vohive.main.$key" 2>/dev/null || true)"
	[ -n "$value" ] && printf '%s' "$value" || printf '%s' "$default"
}

resolve_asset_arch() {
	local configured="$1"
	local machine

	case "$configured" in
		'')
			machine="$(uname -m)"
			case "$machine" in
				aarch64|arm64) printf 'arm64' ;;
				x86_64|amd64) printf 'amd64' ;;
				armv7l|armv7) printf 'armv7' ;;
				*) printf 'unknown' ;;
			esac
			;;
		arm64|amd64|armv7)
			printf '%s' "$configured"
			;;
		*)
			printf 'unknown'
			;;
	esac
}

total_jiffies() {
	awk '/^cpu / { total=0; for (i=2; i<=NF; i++) total += $i; print total; exit }' /proc/stat 2>/dev/null
}

vohive_pids() {
	local pid cmd

	for pid in /proc/[0-9]*; do
		pid="${pid#/proc/}"
		cmd="$({ tr '\0' ' ' < "/proc/$pid/cmdline"; } 2>/dev/null || true)"
		case "$cmd" in
			*"/etc/vohive/bin/vohive"*) printf '%s\n' "$pid" ;;
		esac
	done
}

process_jiffies() {
	local total=0 stat utime stime

	for pid in "$@"; do
		stat="$(cat "/proc/$pid/stat" 2>/dev/null || true)"
		[ -n "$stat" ] || continue
		utime="$(printf '%s\n' "$stat" | awk '{print $14}')"
		stime="$(printf '%s\n' "$stat" | awk '{print $15}')"
		total=$((total + ${utime:-0} + ${stime:-0}))
	done

	printf '%s\n' "$total"
}

process_rss_kb() {
	local total=0 rss

	for pid in "$@"; do
		rss="$(awk '/^VmRSS:/ {print $2; exit}' "/proc/$pid/status" 2>/dev/null || true)"
		total=$((total + ${rss:-0}))
	done

	printf '%s\n' "$total"
}

mem_total_kb() {
	awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null
}

collect_process_metrics() {
	local pids pid_count mem_total mem_used mem_percent cpu_percent cpu_percent_x100
	local proc_now total_now prev_proc prev_total proc_delta total_delta

	pids="$(vohive_pids)"
	if [ -z "$pids" ]; then
		mkdir -p "${METRICS_STATE%/*}"
		printf '0 %s\n' "$(total_jiffies || printf 0)" > "$METRICS_STATE"
		printf '"process_count":0,'
		printf '"cpu_percent":0,'
		printf '"cpu_percent_x100":0,'
		printf '"memory_used_kb":0,'
		printf '"memory_total_kb":%s,' "$(mem_total_kb || printf 0)"
		printf '"memory_percent":0,'
		return
	fi

	# shellcheck disable=SC2086
	set -- $pids
	pid_count="$#"
	mem_total="$(mem_total_kb || printf 0)"
	mem_used="$(process_rss_kb "$@")"
	if [ "${mem_total:-0}" -gt 0 ]; then
		mem_percent=$((mem_used * 100 / mem_total))
	else
		mem_percent=0
	fi

	proc_now="$(process_jiffies "$@")"
	total_now="$(total_jiffies || printf 0)"
	if [ -s "$METRICS_STATE" ]; then
		read -r prev_proc prev_total < "$METRICS_STATE" || {
			prev_proc="$proc_now"
			prev_total="$total_now"
		}
	else
		prev_proc="$proc_now"
		prev_total="$total_now"
	fi
	case "$prev_proc" in *[!0-9]*|'') prev_proc="$proc_now" ;; esac
	case "$prev_total" in *[!0-9]*|'') prev_total="$total_now" ;; esac
	case "$proc_now" in *[!0-9]*|'') proc_now=0 ;; esac
	case "$total_now" in *[!0-9]*|'') total_now=0 ;; esac

	mkdir -p "${METRICS_STATE%/*}"
	printf '%s %s\n' "$proc_now" "$total_now" > "$METRICS_STATE"

	proc_delta=$((proc_now - prev_proc))
	total_delta=$((total_now - prev_total))
	if [ "$total_delta" -gt 0 ] && [ "$proc_delta" -ge 0 ]; then
		cpu_percent_x100=$((proc_delta * 10000 / total_delta))
		cpu_percent=$((cpu_percent_x100 / 100))
	else
		cpu_percent=0
		cpu_percent_x100=0
	fi

	printf '"process_count":%s,' "$pid_count"
	printf '"cpu_percent":%s,' "$cpu_percent"
	printf '"cpu_percent_x100":%s,' "$cpu_percent_x100"
	printf '"memory_used_kb":%s,' "$mem_used"
	printf '"memory_total_kb":%s,' "${mem_total:-0}"
	printf '"memory_percent":%s,' "$mem_percent"
}

is_running=0
/etc/init.d/vohive running >/dev/null 2>&1 && is_running=1

enabled="$(uci_get enabled '0')"
host="$(uci_get host '0.0.0.0')"
port="$(uci_get port '7575')"
data_path="$(uci_get data_path '/etc/vohive/data')"
core_arch_config="$(uci_get core_arch '')"
core_arch_effective="$(resolve_asset_arch "$core_arch_config")"

core_installed=0
core_version="--"
core_arch=""
data_connected="false"
if [ -x "$BIN" ]; then
	core_installed=1
	core_arch="$(cat "$ARCH_FILE" 2>/dev/null || true)"
	[ -n "$core_arch" ] || core_arch="$core_arch_effective"

	# 先读版本文件作为兜底
	_file_version="$(cat "$VERSION_FILE" 2>/dev/null || true)"
	[ -n "$_file_version" ] && [ "$_file_version" != "--" ] && core_version="$_file_version"

	# 核心运行时每分钟从 API 获取一次版本号
	if [ "$is_running" = "1" ]; then
		_now="$(date +%s)"
		_last_query=0
		[ -f /tmp/vohive/version_api_ts ] && _last_query="$(cat /tmp/vohive/version_api_ts 2>/dev/null || echo 0)"
		_elapsed=$((_now - _last_query))
		if [ "$_elapsed" -ge 60 ]; then
			printf '%s' "$_now" > /tmp/vohive/version_api_ts 2>/dev/null || true
			_api_port="$(uci_get port '7575')"
			_api_token="$(curl -s --connect-timeout 3 "http://127.0.0.1:${_api_port}/api/auth/login" \
				-X POST -H 'Content-Type: application/json' \
				-d '{"username":"'"$(uci_get username 'admin')"'","password":"'"$(uci_get password 'admin')"'"}' \
				2>/dev/null | jsonfilter -e '@.token' 2>/dev/null || true)"
			if [ -n "$_api_token" ]; then
				_api_version="$(curl -s --connect-timeout 3 "http://127.0.0.1:${_api_port}/api/system/info" \
					-H "Authorization: Bearer $_api_token" \
					2>/dev/null | jsonfilter -e '@.version' 2>/dev/null || true)"
				if [ -n "$_api_version" ]; then
					core_version="$_api_version"
					printf '%s\n' "$_api_version" > "$VERSION_FILE"
				fi
			fi
		fi
	fi
fi

# Query data_connected using cached token (30s cache to avoid API rate limiting)
if [ "$is_running" = "1" ]; then
	_dc_port="$(uci_get port '7575')"
	_dc_now="$(date +%s)"
	_dc_last=0
	[ -f /tmp/vohive/token_ts ] && _dc_last="$(cat /tmp/vohive/token_ts 2>/dev/null || echo 0)"
	_dc_elapsed=$((_dc_now - _dc_last))

	# Refresh token at most every 30 seconds
	if [ "$_dc_elapsed" -ge 30 ] || [ ! -f /tmp/vohive/token_cache ]; then
		printf '%s' "$_dc_now" > /tmp/vohive/token_ts 2>/dev/null || true
		_dc_token="$(curl -s --connect-timeout 3 "http://127.0.0.1:${_dc_port}/api/auth/login" \
			-X POST -H 'Content-Type: application/json' \
			-d '{"username":"'"$(uci_get username 'admin')"'","password":"'"$(uci_get password 'admin')"'"}' \
			2>/dev/null | jsonfilter -e '@.token' 2>/dev/null || true)"
		[ -n "$_dc_token" ] && printf '%s' "$_dc_token" > /tmp/vohive/token_cache 2>/dev/null || true
	else
		_dc_token="$(cat /tmp/vohive/token_cache 2>/dev/null || true)"
	fi

	if [ -n "$_dc_token" ]; then
		_dc_result="$(curl -s --connect-timeout 3 "http://127.0.0.1:${_dc_port}/api/devices" \
			-H "Authorization: Bearer $_dc_token" \
			2>/dev/null | jsonfilter -e '@.devices[0].data_connected' 2>/dev/null || true)"
		[ "$_dc_result" = "true" ] && data_connected="true"
	fi
fi

default_password=0
[ "$(uci_get username 'admin')" = "admin" ] && [ "$(uci_get password 'admin')" = "admin" ] && default_password=1

plugin_version="$(pkg_installed_version luci-app-vohive 2>/dev/null || cat /usr/share/vohive/plugin_version 2>/dev/null || true)"
plugin_version="${plugin_version#v}"
plugin_version="${plugin_version%-r*}"
plugin_version="${plugin_version%-[0-9]*}"

port_status="unknown"
if command -v ss >/dev/null 2>&1; then
	if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$port$"; then
		port_status="listening"
	else
		port_status="free"
	fi
elif command -v netstat >/dev/null 2>&1; then
	if netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$port$"; then
		port_status="listening"
	else
		port_status="free"
	fi
fi

df_json_fields() {
	local prefix="$1"
	local path="$2"
	local line total used avail percent mount

	line="$(df -kP "$path" 2>/dev/null | awk 'NR==2 {print $2 " " $3 " " $4 " " $5 " " $6}' || true)"
	if [ -n "$line" ]; then
		set -- $line
		total="$1"
		used="$2"
		avail="$3"
		percent="${4%%%}"
		mount="$5"
	else
		total=0
		used=0
		avail=0
		percent=0
		mount=""
	fi

	printf '"%s_total_kb":%s,' "$prefix" "$total"
	printf '"%s_used_kb":%s,' "$prefix" "$used"
	printf '"%s_avail_kb":%s,' "$prefix" "$avail"
	printf '"%s_percent":%s,' "$prefix" "$percent"
	printf '"%s_mount":"%s",' "$prefix" "$(json_escape "$mount")"
}

printf '{'
printf '"running":%s,' "$is_running"
printf '"enabled":%s,' "$enabled"
printf '"core_installed":%s,' "$core_installed"
printf '"core_version":"%s",' "$(json_escape "$core_version")"
printf '"plugin_version":"%s",' "$(json_escape "$plugin_version")"
printf '"core_arch":"%s",' "$(json_escape "$core_arch")"
printf '"core_arch_config":"%s",' "$(json_escape "$core_arch_config")"
printf '"core_arch_effective":"%s",' "$(json_escape "$core_arch_effective")"
printf '"data_connected":%s,' "$data_connected"
printf '"host":"%s",' "$(json_escape "$host")"
printf '"port":"%s",' "$(json_escape "$port")"
printf '"data_path":"%s",' "$(json_escape "$data_path")"
printf '"default_password":%s,' "$default_password"
printf '"port_status":"%s",' "$port_status"
collect_process_metrics
df_json_fields root /
df_json_fields data "$data_path"
printf '"root_space":"%s",' "$(json_escape "${root_avail_kb:-}")"
printf '"data_space":"%s"' "$(json_escape "${data_avail_kb:-}")"
printf '}\n'
