#!/bin/sh

# Default repositories — single source of truth.
# Change here and every script that sources lib.sh picks it up.
DEFAULT_CORE_REPO='https://github.com/voorz/vohive-release'
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
	# GitHub repo addresses are owner/repo: keep the first two path
	# segments and drop any trailing ones (e.g. /releases, /tree/...).
	repo="$(printf '%s' "$repo" | cut -d/ -f1,2)"
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

# True when dotted version $1 is strictly newer than $2 (numeric fields).
version_gt() {
	awk -v a="$1" -v b="$2" 'BEGIN {
		na = split(a, x, "."); nb = split(b, y, ".");
		n = (na > nb) ? na : nb;
		for (i = 1; i <= n; i++) {
			va = (i <= na) ? x[i] + 0 : 0;
			vb = (i <= nb) ? y[i] + 0 : 0;
			if (va > vb) exit 0;
			if (va < vb) exit 1;
		}
		exit 1;
	}'
}

normalize_plugin_version() {
	local version="${1#v}"
	version="${version%-r*}"
	version="${version%-[0-9]*}"
	# apk versions may look like 0.1.39-r1 already handled by %-r*
	printf '%s' "$version"
}

# ---- Multi-core instances ----
# Layout on the router (shared config, one binary per instance):
#   /etc/vohive/instances/<id>/vohive   instance binary
#   /etc/vohive/instances/<id>/version  version string (may be "--")
#   /etc/vohive/instances/<id>/arch     asset arch (may be "unknown")
#   /etc/vohive/instances/<id>/meta     key=value: name, source, created, cfgver
#   /etc/vohive/active                  active instance id (single line)
# Legacy single-core layout (/etc/vohive/bin/vohive) is migrated lazily
# into an instance named "default" on first use; all resolvers below
# trigger that migration, so callers never see the legacy path.

INSTANCES_DIR="/etc/vohive/instances"
ACTIVE_FILE="/etc/vohive/active"
LEGACY_BIN_DIR="/etc/vohive/bin"
LEGACY_BIN="$LEGACY_BIN_DIR/vohive"

instance_id_valid() {
	printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_-]+$'
}

instance_dir() {
	printf '%s/%s' "$INSTANCES_DIR" "$1"
}

instance_meta_get() {
	local id="$1" key="$2" file value

	file="$(instance_dir "$id")/meta"
	[ -f "$file" ] || return 1
	value="$(awk -F= -v k="$key" '$1 == k { sub($1 "=", ""); print; exit }' "$file" 2>/dev/null || true)"
	[ -n "$value" ] || return 1
	printf '%s' "$value"
}

# Set one key in an instance's meta file, preserving all other keys.
instance_meta_set() {
	local id="$1" key="$2" value="$3" file tmp

	file="$(instance_dir "$id")/meta"
	[ -f "$file" ] || return 1
	tmp="$file.tmp.$$"
	awk -F= -v k="$key" -v v="$value" '
		BEGIN { done = 0 }
		$1 == k { if (!done) { print k "=" v; done = 1 } next }
		{ print }
		END { if (!done) print k "=" v }
	' "$file" > "$tmp" && mv "$tmp" "$file"
}

cfgver_valid() {
	case "$1" in
		1.0|2.0) return 0 ;;
		*) return 1 ;;
	esac
}

# The instance's config version: "1.0" cores take the plugin-rendered
# config.yaml via -c and are configured from LuCI; "2.0" cores are
# self-managed — they generate and own their configuration and are
# launched without -c. Instances created before this field existed
# have no cfgver in meta and default to "1.0".
instance_cfgver() {
	local id="$1" value

	value="$(instance_meta_get "$id" cfgver 2>/dev/null || true)"
	if cfgver_valid "$value"; then
		printf '%s' "$value"
	else
		printf '1.0'
	fi
}

migrate_legacy_instance() {
	local id dir

	# Already migrated: instances exist and an active pointer is set.
	if [ -s "$ACTIVE_FILE" ] && [ -d "$INSTANCES_DIR" ]; then
		return 0
	fi

	# No legacy binary: nothing to migrate (fresh install, or already
	# migrated with a missing pointer — pick the first instance then).
	if [ ! -x "$LEGACY_BIN" ]; then
		if [ -d "$INSTANCES_DIR" ] && [ ! -s "$ACTIVE_FILE" ]; then
			id="$(ls "$INSTANCES_DIR" 2>/dev/null | head -n 1 || true)"
			[ -n "$id" ] && printf '%s\n' "$id" > "$ACTIVE_FILE"
		fi
		return 0
	fi

	mkdir -p "$INSTANCES_DIR" || return 1
	id="default"
	dir="$(instance_dir "$id")"
	mkdir -p "$dir" || return 1
	mv "$LEGACY_BIN" "$dir/vohive" || return 1
	[ -f "$LEGACY_BIN_DIR/version" ] && mv "$LEGACY_BIN_DIR/version" "$dir/version"
	[ -f "$LEGACY_BIN_DIR/arch" ] && mv "$LEGACY_BIN_DIR/arch" "$dir/arch"
	[ -f "$dir/version" ] || printf '%s\n' "--" > "$dir/version"
	[ -f "$dir/arch" ] || printf '%s\n' "unknown" > "$dir/arch"
	{
		printf 'name=%s\n' "默认核心"
		printf 'source=%s\n' "local"
		printf 'created=%s\n' "$(date +%s)"
	} > "$dir/meta"
	printf '%s\n' "$id" > "$ACTIVE_FILE"
	return 0
}

active_instance_id() {
	migrate_legacy_instance 2>/dev/null || true
	[ -s "$ACTIVE_FILE" ] && cat "$ACTIVE_FILE" 2>/dev/null || true
}

core_bin_path() {
	local id

	id="$(active_instance_id)"
	if [ -n "$id" ] && [ -x "$(instance_dir "$id")/vohive" ]; then
		printf '%s/vohive' "$(instance_dir "$id")"
		return 0
	fi
	printf '%s' "$LEGACY_BIN"
}

core_version_file() {
	local id

	id="$(active_instance_id)"
	if [ -n "$id" ] && [ -d "$(instance_dir "$id")" ]; then
		printf '%s/version' "$(instance_dir "$id")"
		return 0
	fi
	printf '%s/version' "$LEGACY_BIN_DIR"
}
