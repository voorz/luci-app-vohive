#!/bin/sh
# network_setup.sh — Enable / disable / restore VoHive network integration
#
# Usage:
#   network_setup.sh enable        Create network.vohive (proto=none) and add to wan zone
#   network_setup.sh disable       Remove network.vohive and remove from wan zone
#   network_setup.sh restore       Same as disable — restores original config
#
# After enable, the script reloads network/firewall and waits for VoHive
# to re-establish the QMI data connection (network reload briefly disrupts it).

set -eu

. /usr/share/vohive/lib.sh

ACTION="${1:-}"

PORT="$(uci_get port '7575')"
USERNAME="$(uci_get username 'admin')"
PASSWORD="$(uci_get password 'admin')"

json_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\r//g; s/	/\\t/g'
}

result_ok() {
	printf '{"ok":true,"message":"%s"}\n' "$(json_escape "$1")"
}

result_fail() {
	printf '{"ok":false,"message":"%s"}\n' "$(json_escape "$1")"
	exit 1
}

# ---------------------------------------------------------------------------
# Find the wan zone index in firewall config
# ---------------------------------------------------------------------------
find_wan_zone_idx() {
	local i=0 name
	while true; do
		name="$(uci -q get "firewall.@zone[$i].name" 2>/dev/null || true)"
		[ -n "$name" ] || break
		[ "$name" = "wan" ] && { printf '%s' "$i"; return 0; }
		i=$((i + 1))
	done
	return 1
}

# ---------------------------------------------------------------------------
# Get the wwan interface name from VoHive API or sysfs
# ---------------------------------------------------------------------------
get_wwan_iface() {
	local token data iface

	if /etc/init.d/vohive running >/dev/null 2>&1; then
		token="$(curl -s --connect-timeout 3 "http://127.0.0.1:${PORT}/api/auth/login" \
			-X POST -H 'Content-Type: application/json' \
			-d '{"username":"'"$USERNAME"'","password":"'"$PASSWORD"'"}' \
			2>/dev/null | jsonfilter -e '@.token' 2>/dev/null || true)"
		if [ -n "$token" ]; then
			data="$(curl -s --connect-timeout 3 "http://127.0.0.1:${PORT}/api/devices" \
				-H "Authorization: Bearer $token" 2>/dev/null || true)"
			iface="$(printf '%s' "$data" | jsonfilter -e '@.devices[0].interface' 2>/dev/null || true)"
			[ -n "$iface" ] && { printf '%s' "$iface"; return 0; }
		fi
	fi

	# Fallback: scan sysfs for wwan* interfaces
	for net in /sys/class/net/wwan*/; do
		[ -d "$net" ] || continue
		printf '%s' "$(basename "$net")"
		return 0
	done

	return 1
}

# ---------------------------------------------------------------------------
# Trigger VoHive to re-establish data connection after network reload
# ---------------------------------------------------------------------------
reconnect_vohive() {
	local token

	# Wait for network stack to settle
	sleep 3

	if ! /etc/init.d/vohive running >/dev/null 2>&1; then
		return 0
	fi

	# Try to toggle network off/on via VoHive API
	token="$(curl -s --connect-timeout 3 "http://127.0.0.1:${PORT}/api/auth/login" \
		-X POST -H 'Content-Type: application/json' \
		-d '{"username":"'"$USERNAME"'","password":"'"$PASSWORD"'"}' \
		2>/dev/null | jsonfilter -e '@.token' 2>/dev/null || true)"

	if [ -n "$token" ]; then
		# Try disabling and re-enabling network via API
		# If no such API exists, fall back to service restart
		curl -s --connect-timeout 5 "http://127.0.0.1:${PORT}/api/devices/actions/rescan" \
			-H "Authorization: Bearer $token" >/dev/null 2>&1 || true
	fi

	# Give VoHive time to re-establish the data connection
	sleep 5
}

# ---------------------------------------------------------------------------
# Enable: create network.vohive + add to wan zone
# ---------------------------------------------------------------------------
do_enable() {
	local wwan_iface wan_idx

	wwan_iface="$(get_wwan_iface)" || result_fail "未找到 VoHive 管理的网络接口（wwan*）"
	wan_idx="$(find_wan_zone_idx)" || result_fail "未找到防火墙 wan 区域"

	# Step 1: Create network interface (proto=none, no interference with VoHive)
	uci set network.vohive=interface
	uci set network.vohive.proto='none'
	uci set network.vohive.device="$wwan_iface"
	uci commit network

	# Step 2: Add vohive to wan firewall zone (idempotent — check first)
	local current_networks existing
	current_networks="$(uci -q get "firewall.@zone[$wan_idx].network" 2>/dev/null || true)"
	existing="false"
	for net in $current_networks; do
		[ "$net" = "vohive" ] && { existing="true"; break; }
	done
	if [ "$existing" = "false" ]; then
		uci add_list "firewall.@zone[$wan_idx].network='vohive'"
		uci commit firewall
	fi

	# Step 3: Reload services
	/etc/init.d/network reload 2>/dev/null || true
	/etc/init.d/firewall reload 2>/dev/null || true

	# Step 4: Re-establish VoHive data connection (network reload may disrupt it)
	reconnect_vohive

	result_ok "已启用 4G 网络（接口 $wwan_iface 已加入防火墙 wan 域）"
}

# ---------------------------------------------------------------------------
# Disable / Restore: remove network.vohive + remove from wan zone
# ---------------------------------------------------------------------------
do_disable() {
	local wan_idx

	wan_idx="$(find_wan_zone_idx 2>/dev/null || true)"

	# Step 1: Remove vohive from wan zone network list
	if [ -n "$wan_idx" ]; then
		local current_networks
		current_networks="$(uci -q get "firewall.@zone[$wan_idx].network" 2>/dev/null || true)"
		# Check if vohive is in the network list
		local found="false"
		for net in $current_networks; do
			[ "$net" = "vohive" ] && { found="true"; break; }
		done
		if [ "$found" = "true" ]; then
			uci del_list "firewall.@zone[$wan_idx].network='vohive'" 2>/dev/null || true
			uci commit firewall
		fi
	fi

	# Step 2: Delete network.vohive interface
	if uci -q get network.vohive >/dev/null 2>&1; then
		uci delete network.vohive
		uci commit network
	fi

	# Step 3: Reload services
	/etc/init.d/network reload 2>/dev/null || true
	/etc/init.d/firewall reload 2>/dev/null || true

	result_ok "已禁用 4G 网络（已移除网络接口和防火墙配置）"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "$ACTION" in
	enable)
		do_enable
		;;
	disable|restore)
		do_disable
		;;
	*)
		result_fail "用法: network_setup.sh <enable|disable|restore>"
		;;
esac
