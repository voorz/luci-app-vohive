#!/bin/sh

set -eu

. /usr/share/vohive/lib.sh

repo="$(github_repo_slug "$(uci_get release_repo 'https://github.com/voorz/vohive-next')")"
limit="${1:-5}"

case "$limit" in
	''|*[!0-9]*) limit=5 ;;
esac
[ "$limit" -gt 0 ] && [ "$limit" -le 20 ] || limit=5

validate_github_repo "$repo" || {
	printf '{"ok":false,"message":"%s","latest":"","versions":[]}\n' "$(json_escape "Invalid GitHub repository: $repo")"
	exit 0
}

json="$(curl -fsSL --show-error --connect-timeout 8 --max-time 25 --retry 2 "https://api.github.com/repos/$repo/releases?per_page=$limit" 2>/tmp/vohive-releases.err)" || {
	msg="$(cat /tmp/vohive-releases.err 2>/dev/null || true)"
	printf '{"ok":false,"message":"%s","latest":"","versions":[]}\n' "$(json_escape "Failed to query releases: $msg")"
	exit 0
}

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
