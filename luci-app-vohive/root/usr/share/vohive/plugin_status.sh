#!/bin/sh

set -eu

. /usr/share/vohive/lib.sh

PLUGIN_REPO="$DEFAULT_PLUGIN_REPO"
VERSION_FILE="/usr/share/vohive/plugin_version"
limit="${1:-5}"
force="${2:-}"

# Cloud version checks are manual: page loads pass 'cached' and only
# ever read the cache (never the network); the check button passes
# 'force' and is the single path that talks to GitHub.
CACHE_DIR="/tmp/vohive"
CACHE_FILE="$CACHE_DIR/plugin-releases.json"
CACHE_TS="$CACHE_DIR/plugin-releases.ts"
CACHE_TTL=86400

case "$limit" in
	''|*[!0-9]*) limit=5 ;;
esac
[ "$limit" -gt 0 ] && [ "$limit" -le 20 ] || limit=5

current="$(pkg_installed_version luci-app-vohive 2>/dev/null || true)"
[ -n "$current" ] || current="$(cat "$VERSION_FILE" 2>/dev/null || true)"
[ -n "$current" ] || current="unknown"
current_norm="$(normalize_plugin_version "$current")"

# USB serial drivers are an OS-layer precondition for the core: without
# them the modem never enumerates as ttyUSB ports. Report them here so
# the overview can show/install them independently of GitHub results.
serial_driver_installed=false
option_driver_installed=false
pkg_installed kmod-usb-serial && serial_driver_installed=true
pkg_installed kmod-usb-serial-option && option_driver_installed=true

json=""
if [ "$force" != "force" ] && [ -s "$CACHE_FILE" ] && [ -f "$CACHE_TS" ]; then
	age=$(( $(date +%s) - $(cat "$CACHE_TS" 2>/dev/null || echo 0) ))
	if [ "$age" -ge 0 ] && [ "$age" -lt "$CACHE_TTL" ]; then
		json="$(cat "$CACHE_FILE")"
	fi
fi
if [ -z "$json" ] && [ "$force" = "cached" ]; then
	if [ -s "$CACHE_FILE" ]; then
		json="$(cat "$CACHE_FILE")"
	else
		printf '{"ok":false,"message":"%s","repo":"%s","current":"%s","latest":"","has_update":false,"serial_driver_installed":%s,"option_driver_installed":%s,"versions":[]}\n' \
			"$(json_escape "Not checked yet")" \
			"$(json_escape "$PLUGIN_REPO")" \
			"$(json_escape "$current_norm")" \
			"$serial_driver_installed" \
			"$option_driver_installed"
		exit 0
	fi
fi
if [ -z "$json" ]; then
	if fetched="$(curl -fsSL --show-error --connect-timeout 8 --max-time 25 --retry 2 "https://api.github.com/repos/$PLUGIN_REPO/releases?per_page=$limit" 2>/tmp/vohive-plugin-releases.err)"; then
		json="$fetched"
		mkdir -p "$CACHE_DIR"
		printf '%s' "$json" > "$CACHE_FILE"
		date +%s > "$CACHE_TS"
	elif [ -s "$CACHE_FILE" ]; then
		json="$(cat "$CACHE_FILE")"
	else
		msg="$(cat /tmp/vohive-plugin-releases.err 2>/dev/null || true)"
		printf '{"ok":false,"message":"%s","repo":"%s","current":"%s","latest":"","has_update":false,"serial_driver_installed":%s,"option_driver_installed":%s,"versions":[]}\n' \
			"$(json_escape "Failed to query plugin releases: $msg")" \
			"$(json_escape "$PLUGIN_REPO")" \
			"$(json_escape "$current_norm")" \
			"$serial_driver_installed" \
			"$option_driver_installed"
		exit 0
	fi
fi

latest="$(printf '%s' "$json" | jsonfilter -e '@[0].tag_name' 2>/dev/null || true)"
latest_norm="$(normalize_plugin_version "$latest")"
has_update=false
[ -n "$latest_norm" ] && [ "$current_norm" != "$latest_norm" ] && has_update=true

printf '{"ok":true,"repo":"%s","current":"%s","latest":"%s","has_update":%s,"serial_driver_installed":%s,"option_driver_installed":%s,"versions":[' \
	"$(json_escape "$PLUGIN_REPO")" \
	"$(json_escape "$current_norm")" \
	"$(json_escape "$latest")" \
	"$has_update" \
	"$serial_driver_installed" \
	"$option_driver_installed"
i=0
while [ "$i" -lt "$limit" ]; do
	tag="$(printf '%s' "$json" | jsonfilter -e "@[$i].tag_name" 2>/dev/null || true)"
	[ -n "$tag" ] || break
	[ "$i" -eq 0 ] || printf ','
	printf '"%s"' "$(json_escape "$tag")"
	i=$((i + 1))
done
printf ']}\n'
