#!/bin/sh

# Default repositories — single source of truth.
# Change here and every script that sources lib.sh picks it up.
DEFAULT_CORE_REPO='https://github.com/voorz/vohive-next'
DEFAULT_PLUGIN_REPO='voorz/luci-app-vohive'

json_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g; s/\r//g; :a; N; $!ba; s/\n/\\n/g'
}

uci_get() {
	local key="$1"
	local default="$2"
	local value

	value="$(uci -q get "vohive.main.$key" 2>/dev/null || true)"
	[ -n "$value" ] && printf '%s' "$value" || printf '%s' "$default"
}

github_repo_slug() {
	local repo="$1"

	repo="${repo#https://github.com/}"
	repo="${repo#http://github.com/}"
	repo="${repo#git@github.com:}"
	repo="${repo%/}"
	repo="${repo%.git}"

	printf '%s' "$repo"
}

validate_github_repo() {
	printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
}

resolve_asset_arch() {
	local configured="$1"
	local machine

	case "$configured" in
		'')
			machine="$(uname -m)"
			case "$machine" in
				aarch64|arm64) printf 'arm64' ;;
				x86_64|amd64) printf 'amd64' ;;
				armv7l|armv7) printf 'armv7' ;;
				*) return 1 ;;
			esac
			;;
		arm64|amd64|armv7)
			printf '%s' "$configured"
			;;
		*)
			return 1
			;;
	esac
}

# Package manager helpers: OpenWrt 24.x uses opkg/.ipk, 25.x uses apk/.apk.
pkg_mgr() {
	if command -v opkg >/dev/null 2>&1; then
		printf 'opkg'
	elif command -v apk >/dev/null 2>&1; then
		printf 'apk'
	else
		return 1
	fi
}

pkg_ext() {
	case "$(pkg_mgr 2>/dev/null || true)" in
		opkg) printf 'ipk' ;;
		apk) printf 'apk' ;;
		*) return 1 ;;
	esac
}

pkg_installed() {
	local name="$1"

	case "$(pkg_mgr 2>/dev/null || true)" in
		opkg)
			opkg status "$name" 2>/dev/null | grep -q '^Status: .* installed'
			;;
		apk)
			apk info -e "$name" >/dev/null 2>&1
			;;
		*)
			return 1
			;;
	esac
}

pkg_installed_version() {
	local name="$1"
	local ver=""

	case "$(pkg_mgr 2>/dev/null || true)" in
		opkg)
			opkg status "$name" 2>/dev/null | awk '/^Version:/ {print $2; exit}'
			;;
		apk)
			ver="$(apk list -I "$name" 2>/dev/null | awk -v n="$name" '
				index($1, n "-") == 1 {
					sub("^" n "-", "", $1)
					print $1
					exit
				}')"
			if [ -z "$ver" ]; then
				ver="$(apk info -v "$name" 2>/dev/null | head -n 1 | sed -n "s/^${name}-//p" | awk '{print $1}')"
			fi
			printf '%s' "$ver"
			;;
	esac
}

# Install a local package file (.ipk or .apk). Optional log path as $2.
pkg_install_file() {
	local file="$1"
	local log="${2:-/tmp/vohive-pkg-install.log}"

	case "$(pkg_mgr 2>/dev/null || true)" in
		opkg)
			opkg install "$file" >"$log" 2>&1
			;;
		apk)
			apk add --allow-untrusted "$file" >"$log" 2>&1
			;;
		*)
			printf 'no package manager (opkg/apk)\n' >"$log"
			return 1
			;;
	esac
}

# Install packages from configured feeds/repos. Remaining args are package names.
pkg_install_names() {
	case "$(pkg_mgr 2>/dev/null || true)" in
		opkg)
			opkg update >/dev/null 2>&1 || true
			opkg install "$@"
			;;
		apk)
			apk update >/dev/null 2>&1 || true
			apk add "$@"
			;;
		*)
			return 1
			;;
	esac
}

# From a GitHub release assets JSON blob, pick luci-app-vohive package for current pkg mgr.
# Prints asset filename on stdout. Uses $1 = json text.
select_plugin_asset() {
	local json="$1"
	local ext preferred any name i

	ext="$(pkg_ext)" || return 1
	preferred=""
	any=""
	i=0

	while :; do
		name="$(printf '%s' "$json" | jsonfilter -e "@.assets[$i].name" 2>/dev/null || true)"
		[ -n "$name" ] || break
		case "$ext" in
			ipk)
				case "$name" in
					luci-app-vohive_*_all.ipk)
						preferred="$name"
						break
						;;
					luci-app-vohive_*_*.ipk|luci-app-vohive_*.ipk)
						[ -n "$any" ] || any="$name"
						;;
				esac
				;;
			apk)
				case "$name" in
					luci-app-vohive_*_all.apk|luci-app-vohive-*-r*.apk)
						preferred="$name"
						break
						;;
					luci-app-vohive*.apk)
						[ -n "$any" ] || any="$name"
						;;
				esac
				;;
		esac
		i=$((i + 1))
	done

	if [ -n "$preferred" ]; then
		printf '%s' "$preferred"
		return 0
	fi
	if [ -n "$any" ]; then
		printf '%s' "$any"
		return 0
	fi
	return 1
}

normalize_plugin_version() {
	local version="${1#v}"
	version="${version%-r*}"
	version="${version%-[0-9]*}"
	# apk versions may look like 0.1.39-r1 already handled by %-r*
	printf '%s' "$version"
}
