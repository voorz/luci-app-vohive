#!/bin/sh
# recover_qmi.sh — Recover QMI communication after modem service disruption
#
# Handles two scenarios:
# 1. QMI device (cdc-wdm*) exists but QMI service is not responding
# 2. QMI device doesn't exist (all interfaces claimed by option driver)
#
# Recovery steps:
#   a. Check QMI health via VoHive API (skip if service not running)
#   b. Find an AT port and reset the modem (AT+CFUN=1,1)
#   c. Wait for modem to restart
#   d. Find the QMI-capable interface and bind it to qmi_wwan
#   e. Restart VoHive service (if running)
#   f. Verify QMI health
#
# Usage: recover_qmi.sh
# Output: JSON {"ok":true/false,"message":"..."}

set -e

. /usr/share/vohive/lib.sh

json_escape_local() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\r//g; :a; N; $!ba; s/\n/\\n/g'
}

result_ok() {
	printf '{"ok":true,"message":"%s"}\n' "$(json_escape_local "$1")"
	exit 0
}

result_fail() {
	printf '{"ok":false,"message":"%s"}\n' "$(json_escape_local "$1")"
	exit 1
}

# Try an AT command on a serial port, return response
send_at() {
	local port="$1" cmd="$2"

	if command -v socat >/dev/null 2>&1; then
		printf '%s\r' "$cmd" | timeout 5 socat - "$port,cr" 2>/dev/null || true
	else
		stty -F "$port" 9600 raw -echo 2>/dev/null || true
		printf '%s\r' "$cmd" > "$port" 2>/dev/null || true
		timeout 3 cat "$port" 2>/dev/null || true
	fi
}

# Find an AT-capable serial port by probing each ttyUSB device
find_at_port() {
	local port response

	for port in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2 /dev/ttyUSB3 /dev/ttyUSB4; do
		[ -c "$port" ] || continue
		response="$(send_at "$port" 'AT')" || true
		case "$response" in
			*OK*) printf '%s' "$port"; return 0 ;;
		esac
	done
	return 1
}

# Find the QMI-capable interface: highest-numbered ff/ff/ff interface
# that is not already bound to qmi_wwan.
# Prints: "<iface> <vid> <pid>"  e.g. "1-1:1.4 2ca3 4006"
find_qmi_interface() {
	local dev vid pid iface_path cls subcls proto num num_dec
	local max_num=-1 best_iface="" best_vid="" best_pid=""

	for dev_path in /sys/bus/usb/devices/*/; do
		dev="$(basename "$dev_path")"
		# Skip interface-level dirs (contain ':') and hubs
		echo "$dev" | grep -q ':' && continue
		[ ! -f "${dev_path}idVendor" ] && continue

		vid="$(cat "${dev_path}idVendor" 2>/dev/null || true)"
		pid="$(cat "${dev_path}idProduct" 2>/dev/null || true)"
		[ "$vid" = "1d6b" ] && continue

		for iface_path in /sys/bus/usb/devices/${dev}:*/; do
			[ ! -d "$iface_path" ] && continue
			cls="$(cat "${iface_path}bInterfaceClass" 2>/dev/null || true)"
			subcls="$(cat "${iface_path}bInterfaceSubClass" 2>/dev/null || true)"
			proto="$(cat "${iface_path}bInterfaceProtocol" 2>/dev/null || true)"
			num="$(cat "${iface_path}bInterfaceNumber" 2>/dev/null || true)"

			if [ "$cls" = "ff" ] && [ "$subcls" = "ff" ] && [ "$proto" = "ff" ]; then
				num_dec="$(printf '%d' "0x${num}" 2>/dev/null || echo 0)"
				if [ "${num_dec:-0}" -gt "$max_num" ] 2>/dev/null; then
					max_num="$num_dec"
					best_iface="$(basename "${iface_path%/}")"
					best_vid="$vid"
					best_pid="$pid"
				fi
			fi
		done
	done

	[ -n "$best_iface" ] || return 1
	printf '%s %s %s' "$best_iface" "$best_vid" "$best_pid"
}

# Check QMI health via VoHive API
check_qmi_health() {
	local username password port token device_running

	/etc/init.d/vohive running >/dev/null 2>&1 || return 1

	username="$(uci_get username 'admin')"
	password="$(uci_get password 'admin')"
	port="$(uci_get port '7575')"

	token="$(curl -s --connect-timeout 5 -X POST "http://127.0.0.1:${port}/api/auth/login" \
		-H 'Content-Type: application/json' \
		-d "{\"username\":\"$username\",\"password\":\"$password\"}" 2>/dev/null \
		| jsonfilter -e '@.token' 2>/dev/null)" || true

	[ -n "$token" ] || return 1

	device_running="$(curl -s --connect-timeout 5 "http://127.0.0.1:${port}/api/devices" \
		-H "Authorization: Bearer $token" 2>/dev/null \
		| jsonfilter -e '@.devices[0].running' 2>/dev/null)" || true

	[ "$device_running" = "true" ]
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Step 0 — quick health check; bail out if QMI is already fine
if check_qmi_health 2>/dev/null; then
	result_ok "QMI 通信正常，无需恢复"
fi

# Step 1 — find an AT port
at_port="$(find_at_port)" || result_fail "未找到可用的 AT 串口，无法重置模组"

# Step 2 — reset the modem
send_at "$at_port" 'AT+CFUN=1,1' >/dev/null 2>&1 || result_fail "AT 重置命令发送失败"

# Step 3 — wait for the modem to re-enumerate
sleep 15

# Step 4 — ensure a QMI interface exists
if ! ls /dev/cdc-wdm* >/dev/null 2>&1; then
	qmi_info="$(find_qmi_interface)" || result_fail "模组重启后未找到 QMI 候选接口"
	qmi_iface="$(printf '%s' "$qmi_info" | awk '{print $1}')"
	qmi_vid="$(printf '%s' "$qmi_info" | awk '{print $2}')"
	qmi_pid="$(printf '%s' "$qmi_info" | awk '{print $3}')"

	/usr/share/vohive/driver_bind.sh bind_qmi "$qmi_iface" "$qmi_vid" "$qmi_pid" >/dev/null 2>&1 \
		|| result_fail "QMI 接口绑定失败 ($qmi_iface)"
	sleep 2
fi

# Step 5 — restart VoHive so it picks up the fresh cdc-wdm fd
if /etc/init.d/vohive running >/dev/null 2>&1; then
	/etc/init.d/vohive restart 2>/dev/null || true
	sleep 10
fi

# Step 6 — verify
if check_qmi_health 2>/dev/null; then
	result_ok "QMI 通信已恢复"
else
	result_fail "QMI 恢复后仍无法正常通信，请检查模组状态"
fi
