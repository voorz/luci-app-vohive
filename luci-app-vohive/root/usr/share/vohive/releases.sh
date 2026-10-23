#!/bin/sh

set -eu

. /usr/share/vohive/lib.sh

repo="$(github_repo_slug "$(uci_get release_repo "$DEFAULT_CORE_REPO")")"
limit="${1:-5}"
force="${2:-}"

# Cloud version checks are cached for 24h: page loads serve the cache,
# only an explicit force (the check button) or an expired cache refetches.
CACHE_DIR="/tmp/vohive"
CACHE_SLUG="$(printf '%s' "$repo" | tr '/' '-')"
CACHE_FILE="$CACHE_DIR/releases-$CACHE_SLUG.json"
CACHE_TS="$CACHE_DIR/releases-$CACHE_SLUG.ts"
CACHE_TTL=86400

case "$limit" in
	''|*[!0-9]*) limit=5 ;;
esac
[ "$limit" -gt 0 ] && [ "$limit" -le 20 ] || limit=5

validate_github_repo "$repo" || {
	printf '{"ok":false,"message":"%s","latest":"","versions":[]}\n' "$(json_escape "Invalid GitHub repository: $repo")"
	exit 0
}

json=""
if [ "$force" != "force" ] && [ -s "$CACHE_FILE" ] && [ -f "$CACHE_TS" ]; then
	age=$(( $(date +%s) - $(cat "$CACHE_TS" 2>/dev/null || echo 0) ))
	if [ "$age" -ge 0 ] && [ "$age" -lt "$CACHE_TTL" ]; then
		json="$(cat "$CACHE_FILE")"
	fi
fi
if [ -z "$json" ]; then
	if fetched="$(curl -fsSL --show-error --connect-timeout 8 --max-time 25 --retry 2 "https://api.github.com/repos/$repo/releases?per_page=$limit" 2>/tmp/vohive-releases.err)"; then
		json="$fetched"
		mkdir -p "$CACHE_DIR"
		printf '%s' "$json" > "$CACHE_FILE"
		date +%s > "$CACHE_TS"
	elif [ -s "$CACHE_FILE" ]; then
		json="$(cat "$CACHE_FILE")"
	else
		msg="$(cat /tmp/vohive-releases.err 2>/dev/null || true)"
		printf '{"ok":false,"message":"%s","latest":"","versions":[]}\n' "$(json_escape "Failed to query releases: $msg")"
		exit 0
	fi
fi

latest="$(printf '%s' "$json" | jsonfilter -e '@[0].tag_name' 2>/dev/null || true)"

printf '{"ok":true,"repo":"%s","latest":"%s","versions":[' "$(json_escape "$repo")" "$(json_escape "$latest")"
i=0
while [ "$i" -lt "$limit" ]; do
	tag="$(printf '%s' "$json" | jsonfilter -e "@[$i].tag_name" 2>/dev/null || true)"
	[ -n "$tag" ] || break
	[ "$i" -eq 0 ] || printf ','
	printf '"%s"' "$(json_escape "$tag")"
	i=$((i + 1))
done
printf ']}\n'
