#!/bin/sh
# network_status.sh — Query VoHive network integration status
#
# Outputs JSON for the LuCI "网络管理" tab, combining:
#   - VoHive API device status (data_connected, interface, IP, signal)
#   - OpenWrt netifd config (network.vohive exists? in wan zone?)
#   - Kernel interface state (wwan operstate, carrier, IP, routes)
#
# Usage: network_status.sh

set -eu

. /usr/share/vohive/lib.sh

PORT="$(uci_get port '7575')"
USERNAME="$(uci_get username 'admin')"
PASSWORD="$(uci_get password 'admin')"

# ---------------------------------------------------------------------------
# VoHive API device status
# ---------------------------------------------------------------------------
api_data=""
api_token=""
if /etc/init.d/vohive running >/dev/null 2>&1; then
	api_token="$(curl -s --connect-timeout 3 "http://127.0.0.1:${PORT}/api/auth/login" \
		-X POST -H 'Content-Type: application/json' \
		-d '{"username":"'"$USERNAME"'","password":"'"$PASSWORD"'"}' \
		2>/dev/null | jsonfilter -e '@.token' 2>/dev/null || true)"
	if [ -n "$api_token" ]; then
		api_data="$(curl -s --connect-timeout 3 "http://127.0.0.1:${PORT}/api/devices" \
			-H "Authorization: Bearer $api_token" 2>/dev/null || true)"
	fi
fi

api_field() {
	local field="$1"
	[ -n "$api_data" ] || return 0
	printf '%s' "$api_data" | jsonfilter -e "@.devices[0].${field}" 2>/dev/null || true
}

data_connected="false"
network_enabled="false"
network_connected="false"
vohive_iface=""
public_ip=""
signal_dbm=""
operator_name=""
network_mode=""

if [ -n "$api_data" ]; then
	data_connected="$(api_field data_connected)"
	network_enabled="$(api_field network_enabled)"
	network_connected="$(api_field network_connected)"
	vohive_iface="$(api_field interface)"
	public_ip="$(api_field public_ip)"
	signal_dbm="$(api_field 'modem.signal_dbm')"
	operator_name="$(api_field 'modem.operator')"
	network_mode="$(api_field 'modem.network_mode')"
fi

[ "$data_connected" = "true" ] || data_connected="false"
[ "$network_enabled" = "true" ] || network_enabled="false"
[ "$network_connected" = "true" ] || network_connected="false"

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
# Find the wan zone by name
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
# Kernel interface state
# ---------------------------------------------------------------------------
# Use the interface name from VoHive API, or fall back to scanning wwan*
wwan_iface="$vohive_iface"
wwan_operstate=""
wwan_carrier=""
wwan_ipv4=""
wwan_ipv6=""

if [ -z "$wwan_iface" ]; then
	for net in /sys/class/net/wwan*/; do
		[ -d "$net" ] || continue
		wwan_iface="$(basename "$net")"
		break
	done
fi

if [ -n "$wwan_iface" ] && [ -d "/sys/class/net/$wwan_iface" ]; then
	wwan_operstate="$(cat "/sys/class/net/$wwan_iface/operstate" 2>/dev/null || true)"
	wwan_carrier="$(cat "/sys/class/net/$wwan_iface/carrier" 2>/dev/null || true)"
	wwan_ipv4="$(ip -4 addr show "$wwan_iface" 2>/dev/null | awk '/inet / {gsub(/^[[:space:]]*inet /,""); print $1; exit}' || true)"
	wwan_ipv6="$(ip -6 addr show "$wwan_iface" 2>/dev/null | awk '/inet6 .* scope global/ {gsub(/^[[:space:]]*inet6 /,""); print $1; exit}' || true)"
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
	# Extract gateway (via x.x.x.x)
	gw="$(printf '%s' "$line" | sed -n 's/.*via \([0-9.]*\).*/\1/p')"
	[ -n "$metric" ] || metric="0"
	default_routes="${default_routes}{\"dev\":\"$(json_escape "$dev")\",\"metric\":$metric,\"gateway\":\"$(json_escape "$gw")\"}"
	route_count=$((route_count + 1))
done <<EOF
$(ip route show default 2>/dev/null || true)
EOF

# Determine routing priority
# If wwan_iface route has the lowest metric, it's primary
is_primary="false"
if [ -n "$wwan_iface" ] && [ "$route_count" -gt 0 ]; then
	wwan_metric=""
	other_min_metric=999999
	while IFS= read -r line; do
		dev="$(printf '%s' "$line" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')"
		metric_str="$(printf '%s' "$line" | awk '{for(i=1;i<=NF;i++) if($i=="metric") print $(i+1)}')"
		[ -n "$metric_str" ] || metric_str="0"
		metric_val="${metric_str}"
		if [ "$dev" = "$wwan_iface" ]; then
			wwan_metric="$metric_val"
		else
			[ "$metric_val" -lt "$other_min_metric" ] 2>/dev/null && other_min_metric="$metric_val"
		fi
	done <<EOF
$(ip route show default 2>/dev/null || true)
EOF
	if [ -n "$wwan_metric" ]; then
		[ "$wwan_metric" -le "$other_min_metric" ] 2>/dev/null && is_primary="true"
	fi
fi

# ---------------------------------------------------------------------------
# Geolocation (cached 10 minutes)
# ---------------------------------------------------------------------------
geo_country=""
geo_city=""
geo_isp=""

if [ -n "$public_ip" ]; then
	_geo_now="$(date +%s)"
	_geo_last=0
	[ -f /tmp/vohive/geo_ts ] && _geo_last="$(cat /tmp/vohive/geo_ts 2>/dev/null || echo 0)"
	_geo_elapsed=$((_geo_now - _geo_last))

	if [ "$_geo_elapsed" -ge 600 ] || [ ! -f /tmp/vohive/geo_cache ]; then
		# Cache expired — query ip-api.com
		printf '%s' "$_geo_now" > /tmp/vohive/geo_ts 2>/dev/null || true
		_geo_result="$(curl -s --connect-timeout 5 "http://ip-api.com/json/${public_ip}" 2>/dev/null || true)"
		if [ -n "$_geo_result" ]; then
			printf '%s' "$_geo_result" > /tmp/vohive/geo_cache 2>/dev/null || true
		fi
	fi

	if [ -f /tmp/vohive/geo_cache ]; then
		_cached="$(cat /tmp/vohive/geo_cache 2>/dev/null || true)"
		geo_country="$(printf '%s' "$_cached" | jsonfilter -e '@.country' 2>/dev/null || true)"
		geo_city="$(printf '%s' "$_cached" | jsonfilter -e '@.city' 2>/dev/null || true)"
		geo_isp="$(printf '%s' "$_cached" | jsonfilter -e '@.isp' 2>/dev/null || true)"
	fi
fi

# ---------------------------------------------------------------------------
# Output JSON
# ---------------------------------------------------------------------------
printf '{'
printf '"vohive_running":%s,' "$(/etc/init.d/vohive running >/dev/null 2>&1 && printf true || printf false)"
printf '"data_connected":%s,' "$data_connected"
printf '"network_enabled":%s,' "$network_enabled"
printf '"network_connected":%s,' "$network_connected"
printf '"interface":"%s",' "$(json_escape "$vohive_iface")"
printf '"public_ip":"%s",' "$(json_escape "$public_ip")"
printf '"geo_country":"%s",' "$(json_escape "$geo_country")"
printf '"geo_city":"%s",' "$(json_escape "$geo_city")"
printf '"geo_isp":"%s",' "$(json_escape "$geo_isp")"
printf '"signal_dbm":"%s",' "$(json_escape "$signal_dbm")"
printf '"operator":"%s",' "$(json_escape "$operator_name")"
printf '"network_mode":"%s",' "$(json_escape "$network_mode")"
printf '"netifd_configured":%s,' "$netifd_configured"
printf '"netifd_device":"%s",' "$(json_escape "$netifd_device")"
printf '"firewall_configured":%s,' "$firewall_configured"
printf '"wwan_iface":"%s",' "$(json_escape "$wwan_iface")"
printf '"wwan_operstate":"%s",' "$(json_escape "$wwan_operstate")"
printf '"wwan_carrier":"%s",' "$(json_escape "$wwan_carrier")"
printf '"wwan_ipv4":"%s",' "$(json_escape "$wwan_ipv4")"
printf '"wwan_ipv6":"%s",' "$(json_escape "$wwan_ipv6")"
printf '"is_primary":%s,' "$is_primary"
printf '"default_routes":[%s]' "$default_routes"
printf '}\n'
