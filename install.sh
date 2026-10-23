#!/bin/sh
# luci-app-vohive one-line installer for OpenWrt/ImmortalWrt.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/voorz/luci-app-vohive/main/install.sh | sh
#
# Environment:
#   VERSION  Specific version to install (e.g. "0.1.46"), default: latest
#   REPO     GitHub repo (default: voorz/luci-app-vohive)
#
# Behavior, mirroring the plugin's own update flow:
#   1. If the VoHive core service is running, stop it first.
#   2. If luci-app-vohive is already installed, remove it first,
#      then install the new package. /etc/config/vohive is not a
#      package-owned file, so the configuration survives.
#   3. Start the service again only if it was running before.
set -eu

REPO="${REPO:-voorz/luci-app-vohive}"
VERSION="${VERSION:-latest}"
PKG="luci-app-vohive"
INIT="/etc/init.d/vohive"
TAG=""

log() { printf '[vohive-install] %s\n' "$*"; }
err() { printf '[vohive-install] 错误: %s\n' "$*" >&2; }

# Must run on OpenWrt, as root.
[ -f /etc/openwrt_release ] || { err "仅支持 OpenWrt/ImmortalWrt。"; exit 1; }
[ "$(id -u)" -eq 0 ] || { err "请以 root 运行。"; exit 1; }

# Package manager: OpenWrt 24.x uses opkg/.ipk, 25.x uses apk/.apk.
if command -v opkg >/dev/null 2>&1; then
	MGR=opkg; EXT=ipk
elif command -v apk >/dev/null 2>&1; then
	MGR=apk; EXT=apk
else
	err "未找到包管理器 (opkg/apk)。"; exit 1
fi

# Download tool (curl preferred, wget fallback: the script must also
# work on a machine where the plugin and its dependencies are absent).
if command -v curl >/dev/null 2>&1; then
	DL="curl -fsSL -o"; FETCH="curl -fsSL"
elif command -v wget >/dev/null 2>&1; then
	DL="wget -O"; FETCH="wget -qO-"
else
	err "需要 curl 或 wget。"; exit 1
fi
command -v sha256sum >/dev/null 2>&1 || { err "需要 sha256sum。"; exit 1; }

# Resolve the release and pick the package asset for this system.
if [ "$VERSION" = "latest" ]; then
	API="https://api.github.com/repos/$REPO/releases/latest"
else
	TAG="v${VERSION#v}"
	API="https://api.github.com/repos/$REPO/releases/tags/$TAG"
fi
log "查询版本信息..."
JSON="$($FETCH "$API")" || { err "查询 Release 失败。"; exit 1; }
[ -n "$TAG" ] || TAG="$(printf '%s' "$JSON" | grep '"tag_name"' | head -n 1 | cut -d'"' -f4)"
case "$EXT" in
	ipk) ASSET="$(printf '%s' "$JSON" | grep '"name"' | cut -d'"' -f4 | grep '^luci-app-vohive_.*_all\.ipk$' | head -n 1)" ;;
	apk) ASSET="$(printf '%s' "$JSON" | grep '"name"' | cut -d'"' -f4 | grep '^luci-app-vohive-.*\.apk$' | head -n 1)" ;;
esac
[ -n "$TAG" ] && [ -n "$ASSET" ] || { err "未找到匹配的安装包 (VERSION=$VERSION, $EXT)。"; exit 1; }

BASE="https://github.com/$REPO/releases/download/$TAG"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT INT TERM

log "下载 $ASSET ($TAG)..."
$DL "$TMPDIR/$ASSET" "$BASE/$ASSET"
$DL "$TMPDIR/sha256sums.txt" "$BASE/sha256sums.txt"

log "校验 SHA256..."
EXPECTED="$(awk -v f="$ASSET" '$2 == f {print $1}' "$TMPDIR/sha256sums.txt" | head -n 1)"
[ -n "$EXPECTED" ] || { err "sha256sums.txt 中未找到 $ASSET。"; exit 1; }
ACTUAL="$(sha256sum "$TMPDIR/$ASSET" | awk '{print $1}')"
[ "$ACTUAL" = "$EXPECTED" ] || { err "SHA256 校验失败。"; exit 1; }

# 1) Stop the core service first if it is running.
was_running=0
if [ -x "$INIT" ] && "$INIT" running >/dev/null 2>&1; then
	was_running=1
	log "停止 VoHive 服务..."
	"$INIT" stop || true
fi

restart_if_needed() {
	if [ "$was_running" = "1" ] && [ -x "$INIT" ]; then
		log "重新启动 VoHive 服务..."
		"$INIT" start || true
	fi
}

# 2) Remove the old package first if installed, then install the new one.
installed=0
case "$MGR" in
	opkg) opkg status "$PKG" 2>/dev/null | grep -q '^Status: .* installed' && installed=1 || true ;;
	apk) apk info -e "$PKG" >/dev/null 2>&1 && installed=1 || true ;;
esac
if [ "$installed" = "1" ]; then
	log "卸载旧版本..."
	case "$MGR" in
		opkg) opkg remove "$PKG" ;;
		apk) apk del "$PKG" ;;
	esac || { err "卸载旧版本失败。"; restart_if_needed; exit 1; }
fi

log "安装 $ASSET..."
case "$MGR" in
	opkg) opkg install "$TMPDIR/$ASSET" ;;
	apk) apk add --allow-untrusted "$TMPDIR/$ASSET" ;;
esac || { err "安装失败。"; restart_if_needed; exit 1; }

# Make the LuCI menu entry show up without a reboot.
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null || true

# 3) Bring the service back only if it was running before.
restart_if_needed

NEWVER=""
case "$MGR" in
	opkg) NEWVER="$(opkg status "$PKG" 2>/dev/null | awk '/^Version:/ {print $2; exit}' || true)" ;;
	apk) NEWVER="$(apk list -I "$PKG" 2>/dev/null | awk '{print $1}' | sed "s/^$PKG-//" || true)" ;;
esac
log "完成: luci-app-vohive ${NEWVER:-$TAG} 已安装。刷新 LuCI 页面即可。"
