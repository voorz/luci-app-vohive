#!/bin/sh
# network_status.sh — Query VoHive network integration status
#
# Outputs JSON for the LuCI "网络配置" tab, covering only the OpenWrt
# configuration layer:
#   - OpenWrt netifd config (network.vohive exists? in wan zone?)
#   - Kernel interface state and default routes (for route priority)
#
# The plugin does not query the VoHive core API here: whether the
# modem is connected is the core's own state, not this layer's.
#
# Usage: network_status.sh

set -eu

. /usr/share/vohive/lib.sh

# ---------------------------------------------------------------------------
# OpenWrt netifd config
# ---------------------------------------------------------------------------
netifd_configured="false"
netifd_device=""
if uci -q get network.vohive >/dev/null 2>&1; then
	netifd_configured="true"
	netifd_device="$(uci -q get network.vohive.device 2>/dev/null || true)"
fi

# ---------------------------------------------------------------------------
# Firewall zone
# ---------------------------------------------------------------------------
firewall_configured="false"
wan_zone_networks=""
wan_zone_idx=""
i=0
while true; do
	zone_name="$(uci -q get "firewall.@zone[$i].name" 2>/dev/null || true)"
	[ -n "$zone_name" ] || break
	if [ "$zone_name" = "wan" ]; then
		wan_zone_idx="$i"
		wan_zone_networks="$(uci -q get "firewall.@zone[$i].network" 2>/dev/null || true)"
		break
	fi
	i=$((i + 1))
done

if [ -n "$wan_zone_networks" ]; then
	for net in $wan_zone_networks; do
		if [ "$net" = "vohive" ]; then
			firewall_configured="true"
			break
		fi
	done
fi

# ---------------------------------------------------------------------------
# Kernel interface: the configured device, or the first wwan* interface
# ---------------------------------------------------------------------------
wwan_iface="$netifd_device"
if [ -z "$wwan_iface" ]; then
	for net in /sys/class/net/wwan*/; do
		[ -d "$net" ] || continue
		wwan_iface="$(basename "$net")"
		break
	done
fi

# ---------------------------------------------------------------------------
# Default routes
# ---------------------------------------------------------------------------
default_routes=""
route_count=0
while IFS= read -r line; do
	[ -n "$line" ] || continue
	[ "$route_count" -gt 0 ] && default_routes="${default_routes},"
	dev="$(printf '%s' "$line" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')"
	metric="$(printf '%s' "$line" | awk '{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')"
	gw="$(printf '%s' "$line" | sed -n 's/.*via \([0-9.]*\).*/\1/p')"
	[ -n "$metric" ] || metric="0"
	default_routes="${default_routes}{\"dev\":\"$(json_escape "$dev")\",\"metric\":$metric,\"gateway\":\"$(json_escape "$gw")\"}"
	route_count=$((route_count + 1))
done <<EOF
$(ip route show default 2>/dev/null || true)
EOF

# Determine routing priority
# A default route counts as cellular when its device is a modem netdev:
# wwan* (the UCI-bound device) or qmimux* (the QMI mux interface the core
# actually routes through when a data session is up).  Matching only the
# UCI device name misses the live cellular route entirely and poisons the
# "other WAN" minimum with the cellular metric itself.
# If the cellular route has the lowest metric, it's primary.
# When cellular has no route, infer from other WAN metric:
#   other WAN metric > 5000 (cellular metric) => cellular will be primary
is_cellular_dev() {
	case "$1" in
		wwan*|qmimux*) return 0 ;;
		*) return 1 ;;
	esac
}

is_primary="false"
cellular_metric=5000
if [ "$route_count" -gt 0 ]; then
	cell_metric=""
	other_min_metric=999999
	while IFS= read -r line; do
		dev="$(printf '%s' "$line" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')"
		metric_str="$(printf '%s' "$line" | awk '{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')"
		[ -n "$metric_str" ] || metric_str="0"
		metric_val="${metric_str}"
		if is_cellular_dev "$dev"; then
			if [ -z "$cell_metric" ] || [ "$metric_val" -lt "$cell_metric" ] 2>/dev/null; then
				cell_metric="$metric_val"
			fi
		else
			[ "$metric_val" -lt "$other_min_metric" ] 2>/dev/null && other_min_metric="$metric_val"
		fi
	done <<EOF
$(ip route show default 2>/dev/null || true)
EOF
	if [ -n "$cell_metric" ]; then
		cellular_metric="$cell_metric"
		[ "$cell_metric" -le "$other_min_metric" ] 2>/dev/null && is_primary="true"
	else
		[ "$other_min_metric" -gt "$cellular_metric" ] 2>/dev/null && is_primary="true"
	fi
fi

# ---------------------------------------------------------------------------
# Output JSON
# ---------------------------------------------------------------------------
printf '{'
printf '"netifd_configured":%s,' "$netifd_configured"
printf '"netifd_device":"%s",' "$(json_escape "$netifd_device")"
printf '"firewall_configured":%s,' "$firewall_configured"
printf '"wwan_iface":"%s",' "$(json_escape "$wwan_iface")"
printf '"is_primary":%s,' "$is_primary"
printf '"cellular_metric":%s,' "$cellular_metric"
printf '"default_routes":[%s]' "$default_routes"
printf '}\n'
