#!/bin/sh

set -eu

. /usr/share/vohive/lib.sh

BIN_DIR="/etc/vohive/bin"
BIN="$BIN_DIR/vohive"
VERSION_FILE="$BIN_DIR/version"
BACKUP_VERSION_FILE="$BIN_DIR/version.bak"
ARCH_FILE="$BIN_DIR/arch"
BACKUP_ARCH_FILE="$BIN_DIR/arch.bak"
DOWNLOAD_DIR="/tmp/vohive/download"
TEMP_CURRENT="$DOWNLOAD_DIR/vohive.current"

fail() {
	printf '{"ok":false,"message":"%s"}\n' "$(json_escape "$*")"
	exit 1
}

repo="$(github_repo_slug "$(uci_get release_repo 'https://github.com/voorz/vohive-next')")"
validate_github_repo "$repo" || fail "Invalid GitHub repository: $repo"

rollback_version="$(cat "$BACKUP_VERSION_FILE" 2>/dev/null || true)"
[ -n "$rollback_version" ] && [ "$rollback_version" != "已安装，版本未知" ] && [ "$rollback_version" != "版本未知" ] || fail "No rollback version recorded"

rollback_arch="$(cat "$BACKUP_ARCH_FILE" 2>/dev/null || true)"
if [ -z "$rollback_arch" ] || [ "$rollback_arch" = "unknown" ]; then
	rollback_arch="$(resolve_asset_arch "$(uci_get core_arch '')")" || fail "No rollback architecture recorded"
fi

asset="vohive_${rollback_version}_linux_${rollback_arch}"
url="https://github.com/$repo/releases/download/$rollback_version/$asset"
downloaded="$DOWNLOAD_DIR/$asset"
was_running=0
current_version="$(cat "$VERSION_FILE" 2>/dev/null || true)"
current_arch="$(cat "$ARCH_FILE" 2>/dev/null || true)"

mkdir -p "$BIN_DIR" "$DOWNLOAD_DIR"
rm -f "$downloaded" "$TEMP_CURRENT"

curl -fsSL --show-error --connect-timeout 15 --retry 2 "$url" -o "$downloaded" || fail "Failed to download $url"
[ -s "$downloaded" ] || fail "Downloaded rollback core is empty"
chmod +x "$downloaded"

if command -v file >/dev/null 2>&1; then
	file "$downloaded" | grep -Eq 'ELF|executable' || fail "Downloaded rollback core is not an executable"
fi

/etc/init.d/vohive running >/dev/null 2>&1 && was_running=1
[ "$was_running" = "0" ] || /etc/init.d/vohive stop || true

[ ! -x "$BIN" ] || cp -f "$BIN" "$TEMP_CURRENT"
cp -f "$downloaded" "$BIN"
chmod 0755 "$BIN"
printf '%s\n' "$rollback_version" > "$VERSION_FILE"
printf '%s\n' "$rollback_arch" > "$ARCH_FILE"

if [ "$was_running" = "1" ]; then
	if ! /etc/init.d/vohive start >/tmp/vohive-rollback-start.log 2>&1; then
		if [ -f "$TEMP_CURRENT" ]; then
			cp -f "$TEMP_CURRENT" "$BIN"
			[ -n "$current_version" ] && printf '%s\n' "$current_version" > "$VERSION_FILE"
			[ -n "$current_arch" ] && printf '%s\n' "$current_arch" > "$ARCH_FILE"
			/etc/init.d/vohive start >/dev/null 2>&1 || true
		fi
		fail "Rolled back core, but service failed to start; restored current core when possible"
	fi
fi

[ -n "$current_version" ] && printf '%s\n' "$current_version" > "$BACKUP_VERSION_FILE"
[ -n "$current_arch" ] && printf '%s\n' "$current_arch" > "$BACKUP_ARCH_FILE"
rm -f "$TEMP_CURRENT" "$downloaded" "$BIN_DIR/vohive.bak"

printf '{"ok":true,"message":"已回滚到 %s"}\n' "$(json_escape "$rollback_version")"
