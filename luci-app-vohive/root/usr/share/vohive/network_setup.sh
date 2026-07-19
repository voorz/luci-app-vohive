#!/bin/sh
# network_setup.sh — VoHive network management actions
#
# Usage:
#   network_setup.sh setup     Create network.vohive + add to wan zone (router config only)
#   network_setup.sh restore   Remove network.vohive + firewall config (router config only)
#   network_setup.sh enable    Enable VoHive network via API only (no router config changes)
#   network_setup.sh disable   Disable VoHive network via API only (no router config changes)
#
# setup/restore: manage OpenWrt router-side config (interface + firewall zone)
# enable/disable: manage VoHive data connection via API
# These are independent — users can configure the router without enabling the network,
# and enable/disable the network without touching router config.

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
# VoHive API helpers
# ---------------------------------------------------------------------------
vohive_token() {
	if ! /etc/init.d/vohive running >/dev/null 2>&1; then
		return 1
	fi
	curl -s --connect-timeout 3 "http://127.0.0.1:${PORT}/api/auth/login" \
		-X POST -H 'Content-Type: application/json' \
		-d '{"username":"'"$USERNAME"'","password":"'"$PASSWORD"'"}' \
		2>/dev/null | jsonfilter -e '@.token' 2>/dev/null || true
}

vohive_device_info() {
	local token data dev_id iface

	token="$(vohive_token)" || return 1
	[ -n "$token" ] || return 1

	data="$(curl -s --connect-timeout 3 "http://127.0.0.1:${PORT}/api/devices" \
		-H "Authorization: Bearer $token" 2>/dev/null || true)"

	dev_id="$(printf '%s' "$data" | jsonfilter -e '@.devices[0].id' 2>/dev/null || true)"
	iface="$(printf '%s' "$data" | jsonfilter -e '@.devices[0].interface' 2>/dev/null || true)"

	printf '%s %s' "$dev_id" "$iface"
}

vohive_network_control() {
	local dev_id="$1"
	local enabled="$2"
	local token

	token="$(vohive_token)" || return 1
	[ -n "$token" ] || return 1

	curl -s --connect-timeout 5 "http://127.0.0.1:${PORT}/api/devices/${dev_id}/network" \
		-X PATCH -H 'Content-Type: application/json' \
		-H "Authorization: Bearer $token" \
		-d '{"enabled":'"$enabled"'}' \
		2>/dev/null | jsonfilter -e '@.status' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Router config helpers
# ---------------------------------------------------------------------------
get_wwan_iface() {
	local info dev_id iface

	info="$(vohive_device_info)" || {
		for net in /sys/class/net/wwan*/; do
			[ -d "$net" ] || continue
			printf '%s' "$(basename "$net")"
			return 0
		done
		return 1
	}

	dev_id="${info%% *}"
	iface="${info#* }"
	[ -n "$iface" ] && [ "$iface" != "$dev_id" ] && { printf '%s' "$iface"; return 0; }

	for net in /sys/class/net/wwan*/; do
		[ -d "$net" ] || continue
		printf '%s' "$(basename "$net")"
		return 0
	done
	return 1
}

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

in_zone_networks() {
	local idx="$1"
	local current_networks net

	current_networks="$(uci -q get "firewall.@zone[$idx].network" 2>/dev/null || true)"
	for net in $current_networks; do
		[ "$net" = "vohive" ] && return 0
	done
	return 1
}

# ---------------------------------------------------------------------------
# Setup: create network.vohive + add to wan zone (router config only)
# ---------------------------------------------------------------------------
do_setup() {
	local info dev_id wwan_iface wan_idx

	info="$(vohive_device_info 2>/dev/null || true)"
	dev_id="${info%% *}"
	wwan_iface="${info#* }"
	[ -n "$wwan_iface" ] && [ "$wwan_iface" != "$dev_id" ] || wwan_iface=""
	[ -n "$wwan_iface" ] || wwan_iface="$(get_wwan_iface)" || result_fail "未找到 VoHive 管理的网络接口（wwan*）"
	wan_idx="$(find_wan_zone_idx)" || result_fail "未找到防火墙 wan 区域"

	# Step 1: Create network interface (proto=none, no interference with VoHive)
	uci set network.vohive=interface
	uci set network.vohive.proto='none'
	uci set network.vohive.device="$wwan_iface"
	uci commit network

	# Step 2: Add vohive to wan firewall zone (idempotent)
	if ! in_zone_networks "$wan_idx"; then
		uci add_list firewall.@zone[$wan_idx].network=vohive
		uci commit firewall
	fi

	# Step 3: Reload services
	/etc/init.d/network reload 2>/dev/null || true
	/etc/init.d/firewall reload 2>/dev/null || true

	result_ok "路由器配置已完成（接口 $wwan_iface 已加入防火墙 wan 域）"
}

# ---------------------------------------------------------------------------
# Restore: remove network.vohive + firewall config (router config only)
# ---------------------------------------------------------------------------
do_restore() {
	local wan_idx

	wan_idx="$(find_wan_zone_idx 2>/dev/null || true)"

	# Step 1: Remove vohive from wan zone network list
	if [ -n "$wan_idx" ]; then
		if in_zone_networks "$wan_idx"; then
			uci del_list firewall.@zone[$wan_idx].network=vohive 2>/dev/null || true
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

	result_ok "已撤销配置（已移除网络接口和防火墙配置，恢复原始状态）"
}

# ---------------------------------------------------------------------------
# Enable: enable VoHive network via API only
# ---------------------------------------------------------------------------
do_enable() {
	local info dev_id

	info="$(vohive_device_info 2>/dev/null || true)"
	dev_id="${info%% *}"

	if [ -n "$dev_id" ] && [ "$dev_id" != "" ]; then
		vohive_network_control "$dev_id" true >/dev/null 2>&1 || true
		sleep 3
		result_ok "已启用网络"
	else
		result_fail "无法获取 VoHive 设备信息"
	fi
}

# ---------------------------------------------------------------------------
# Disable: disable VoHive network via API only
# ---------------------------------------------------------------------------
do_disable() {
	local info dev_id

	info="$(vohive_device_info 2>/dev/null || true)"
	dev_id="${info%% *}"

	if [ -n "$dev_id" ] && [ "$dev_id" != "" ]; then
		vohive_network_control "$dev_id" false >/dev/null 2>&1 || true
		sleep 1
		result_ok "已禁用网络"
	else
		result_fail "无法获取 VoHive 设备信息"
	fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "$ACTION" in
	setup)
		do_setup
		;;
	restore)
		do_restore
		;;
	enable)
		do_enable
		;;
	disable)
		do_disable
		;;
	*)
		result_fail "用法: network_setup.sh <setup|restore|enable|disable>"
		;;
esac
