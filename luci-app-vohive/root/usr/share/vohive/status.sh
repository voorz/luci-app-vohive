#!/bin/sh

BIN="/etc/vohive/bin/vohive"
VERSION_FILE="/etc/vohive/bin/version"
ARCH_FILE="/etc/vohive/bin/arch"
BACKUP_VERSION_FILE="/etc/vohive/bin/version.bak"
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
core_version=""
core_arch=""
backup_version=""
if [ -x "$BIN" ]; then
	core_installed=1
	core_version="$(cat "$VERSION_FILE" 2>/dev/null || true)"
	[ -n "$core_version" ] || core_version="已安装，版本未知"
	core_arch="$(cat "$ARCH_FILE" 2>/dev/null || true)"
	[ -n "$core_arch" ] || core_arch="$core_arch_effective"
fi
if [ -s "$BACKUP_VERSION_FILE" ]; then
	backup_version="$(cat "$BACKUP_VERSION_FILE" 2>/dev/null || true)"
fi

default_password=0
[ "$(uci_get username 'admin')" = "admin" ] && [ "$(uci_get password 'admin')" = "admin" ] && default_password=1

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
printf '"backup_version":"%s",' "$(json_escape "$backup_version")"
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
