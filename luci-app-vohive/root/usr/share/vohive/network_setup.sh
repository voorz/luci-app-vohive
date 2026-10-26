#!/bin/sh
# network_setup.sh — VoHive network management actions
#
# Usage:
#   network_setup.sh setup     Create network.vohive + add to wan zone
#   network_setup.sh restore   Remove network.vohive + firewall config
#   network_setup.sh set_metric <value>  Set route metric for other WAN interfaces
#
# This script only manages the OpenWrt configuration layer (UCI network /
# firewall). It never logs into the VoHive core API and never toggles the
# modem's data connection; that is the core's own state to manage.

set -eu

. /usr/share/vohive/lib.sh

ACTION="${1:-}"

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
# Router config helpers
# ---------------------------------------------------------------------------
get_wwan_iface() {
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

# route_exists <routes-text> <dev> <gateway> <metric>
# Succeeds when the given default-route list already contains a route
# with exactly this device, gateway (empty for gateway-less routes) and
# metric (a route printed without a metric field has metric 0).
route_exists() {
	printf '%s\n' "$1" | awk -v want_dev="$2" -v want_gw="$3" -v want_metric="$4" '
		{
			dev = ""; gw = ""; metric = "0"
			for (i = 1; i <= NF; i++) {
				if ($i == "dev") dev = $(i + 1)
				else if ($i == "via") gw = $(i + 1)
				else if ($i == "metric") metric = $(i + 1)
			}
			if (dev == want_dev && gw == want_gw && metric == want_metric) found = 1
		}
		END { exit(found ? 0 : 1) }'
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
	local wwan_iface wan_idx

	wwan_iface="$(get_wwan_iface)" || result_fail "未找到网络接口（wwan*），请确认模组已接入"
	wan_idx="$(find_wan_zone_idx)" || result_fail "未找到防火墙 wan 区域"

	uci set network.vohive=interface
	uci set network.vohive.proto='none'
	uci set network.vohive.device="$wwan_iface"
	uci commit network

	if ! in_zone_networks "$wan_idx"; then
		uci add_list firewall.@zone[$wan_idx].network=vohive
		uci commit firewall
	fi

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

	if [ -n "$wan_idx" ]; then
		if in_zone_networks "$wan_idx"; then
			uci del_list firewall.@zone[$wan_idx].network=vohive 2>/dev/null || true
			uci commit firewall
		fi
	fi

	if uci -q get network.vohive >/dev/null 2>&1; then
		uci delete network.vohive
		uci commit network
	fi

	/etc/init.d/network reload 2>/dev/null || true
	/etc/init.d/firewall reload 2>/dev/null || true

	result_ok "已撤销配置（已移除网络接口和防火墙配置，恢复原始状态）"
}

# ---------------------------------------------------------------------------
# Set route priority: adjust other WAN interfaces' metric relative to cellular
#
# The cellular route metric (5000) is set by the QMI library and cannot be
# changed via UCI.  Instead we toggle the metric of OTHER WAN interfaces:
#   primary: set other WAN metric > 5000  → cellular wins
#   backup:  set other WAN metric = 0     → other WAN wins
#   custom:  set other WAN metric = <value>
# ---------------------------------------------------------------------------
do_set_metric() {
	local mode="${1:-}"

	uci -q get network.vohive >/dev/null 2>&1 || result_fail "network.vohive 接口未创建，请先一键配置"

	local other_metric=""
	case "$mode" in
		primary) other_metric="5001" ;;
		backup)  other_metric="0" ;;
		*[!0-9]*|'') result_fail "无效的模式: $mode（可用: primary | backup | 0-65535）" ;;
		*) [ "$mode" -ge 0 ] && [ "$mode" -le 65535 ] || result_fail "metric 范围: 0-65535"; other_metric="$mode" ;;
	esac

	# Find all networks in the wan firewall zone except vohive
	local wan_idx wan_networks net changed=0
	wan_idx="$(find_wan_zone_idx 2>/dev/null || true)"
	[ -n "$wan_idx" ] || result_fail "未找到防火墙 wan 区域"

	wan_networks="$(uci -q get "firewall.@zone[$wan_idx].network" 2>/dev/null || true)"
	[ -n "$wan_networks" ] || result_fail "wan 区域中没有网络接口"

	for net in $wan_networks; do
		[ "$net" = "vohive" ] && continue
		uci -q get "network.$net" >/dev/null 2>&1 || continue
		uci set "network.$net.metric=$other_metric"
		changed=1
	done

	[ "$changed" = "1" ] || result_fail "未找到可调整的 WAN 接口"

	uci commit network

	# Apply the new metric to the live default routes of the other WANs.
	# A full "network reload" would also bounce the wwan interfaces and
	# drop the core's data session.  A route's metric is part of its key,
	# so changing it means adding the route with the new metric first and
	# then deleting the old one (add-then-delete leaves no gap without a
	# default route).  If the new-metric route already exists (leftover
	# from an interrupted run), just delete the old one.  Routes that do
	# not exist right now need no live change: the committed UCI metric
	# applies when the interface next comes up.
	local routes_snapshot route_line route_dev route_gw route_metric
	routes_snapshot="$(ip route show default 2>/dev/null || true)"
	while IFS= read -r route_line; do
		route_dev="$(printf '%s' "$route_line" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')"
		case "$route_dev" in
			wwan*|qmimux*|'') continue ;;
		esac
		route_metric="$(printf '%s' "$route_line" | awk '{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')"
		[ -n "$route_metric" ] || route_metric="0"
		[ "$route_metric" = "$other_metric" ] && continue
		route_gw="$(printf '%s' "$route_line" | sed -n 's/.*via \([0-9.]*\).*/\1/p')"
		if route_exists "$routes_snapshot" "$route_dev" "$route_gw" "$other_metric"; then
			:
		elif [ -n "$route_gw" ]; then
			ip route add default via "$route_gw" dev "$route_dev" metric "$other_metric" 2>/dev/null || continue
		else
			ip route add default dev "$route_dev" metric "$other_metric" 2>/dev/null || continue
		fi
		if [ -n "$route_gw" ]; then
			ip route del default via "$route_gw" dev "$route_dev" metric "$route_metric" 2>/dev/null || true
		else
			ip route del default dev "$route_dev" metric "$route_metric" 2>/dev/null || true
		fi
	done <<EOF
$routes_snapshot
EOF

	case "$mode" in
		primary) result_ok "路由优先级已设为主力（4G/5G 优先，其他 WAN metric=$other_metric）" ;;
		backup)  result_ok "路由优先级已设为备用（其他 WAN 优先，metric=0）" ;;
		*)       result_ok "其他 WAN 接口 metric 已设为 $other_metric" ;;
	esac
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
	set_metric)
		do_set_metric "${2:-}"
		;;
	*)
		result_fail "用法: network_setup.sh <setup|restore|set_metric> [value]"
		;;
esac
