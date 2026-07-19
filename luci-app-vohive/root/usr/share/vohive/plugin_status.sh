#!/bin/sh

set -eu

. /usr/share/vohive/lib.sh

PLUGIN_REPO="$DEFAULT_PLUGIN_REPO"
VERSION_FILE="/usr/share/vohive/plugin_version"
limit="${1:-5}"

case "$limit" in
	''|*[!0-9]*) limit=5 ;;
esac
[ "$limit" -gt 0 ] && [ "$limit" -le 20 ] || limit=5

current="$(pkg_installed_version luci-app-vohive 2>/dev/null || true)"
[ -n "$current" ] || current="$(cat "$VERSION_FILE" 2>/dev/null || true)"
[ -n "$current" ] || current="unknown"
current_norm="$(normalize_plugin_version "$current")"

json="$(curl -fsSL --show-error --connect-timeout 8 --max-time 25 --retry 2 "https://api.github.com/repos/$PLUGIN_REPO/releases?per_page=$limit" 2>/tmp/vohive-plugin-releases.err)" || {
	msg="$(cat /tmp/vohive-plugin-releases.err 2>/dev/null || true)"
	printf '{"ok":false,"message":"%s","repo":"%s","current":"%s","latest":"","has_update":false,"versions":[]}\n' \
		"$(json_escape "Failed to query plugin releases: $msg")" \
		"$(json_escape "$PLUGIN_REPO")" \
		"$(json_escape "$current")"
	exit 0
}

latest="$(printf '%s' "$json" | jsonfilter -e '@[0].tag_name' 2>/dev/null || true)"
latest_norm="$(normalize_plugin_version "$latest")"
has_update=false
[ -n "$latest_norm" ] && [ "$current_norm" != "$latest_norm" ] && has_update=true

printf '{"ok":true,"repo":"%s","current":"%s","latest":"%s","has_update":%s,"versions":[' \
	"$(json_escape "$PLUGIN_REPO")" \
	"$(json_escape "$current")" \
	"$(json_escape "$latest")" \
	"$has_update"
i=0
while [ "$i" -lt "$limit" ]; do
	tag="$(printf '%s' "$json" | jsonfilter -e "@[$i].tag_name" 2>/dev/null || true)"
	[ -n "$tag" ] || break
	[ "$i" -eq 0 ] || printf ','
	printf '"%s"' "$(json_escape "$tag")"
	i=$((i + 1))
done
printf ']}\n'
