#!/bin/sh

set -eu

. /usr/share/vohive/lib.sh

PLUGIN_REPO="kedaya2025/luci-app-vohive"
DOWNLOAD_DIR="/tmp/vohive/download"
INSTALL_LOG="/tmp/vohive-plugin-install.log"

fail() {
	printf '{"ok":false,"message":"%s"}\n' "$(json_escape "$*")"
	exit 1
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || fail "缺少命令: $1"
}

need_cmd curl
need_cmd jsonfilter
need_cmd sha256sum
pkg_mgr >/dev/null 2>&1 || fail "缺少包管理器: 需要 opkg（OpenWrt 24）或 apk（OpenWrt 25）"

tmp_avail="$(df -kP /tmp 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)"
[ "${tmp_avail:-0}" -ge 2048 ] || fail "/tmp 临时空间不足，至少需要 2 MB"

mkdir -p "$DOWNLOAD_DIR"

json="$(curl -fsSL --show-error --connect-timeout 15 --retry 2 "https://api.github.com/repos/$PLUGIN_REPO/releases/latest" 2>/tmp/vohive-plugin-update.err)" || {
	msg="$(cat /tmp/vohive-plugin-update.err 2>/dev/null || true)"
	fail "查询插件最新版本失败: $msg"
}

tag="$(printf '%s' "$json" | jsonfilter -e '@.tag_name' 2>/dev/null || true)"
[ -n "$tag" ] || fail "无法解析插件最新版本"
tag_norm="$(normalize_plugin_version "$tag")"
ext="$(pkg_ext)"

asset="$(select_plugin_asset "$json")" || fail "最新 Release 未找到 luci-app-vohive *.${ext} 安装包"

base="https://github.com/$PLUGIN_REPO/releases/download/$tag"
pkg_file="$DOWNLOAD_DIR/$asset"
sums="$DOWNLOAD_DIR/sha256sums.txt"

rm -f "$pkg_file" "$sums"
curl -fsSL --show-error --connect-timeout 15 --retry 2 "$base/$asset" -o "$pkg_file" || fail "下载插件安装包失败"
curl -fsSL --show-error --connect-timeout 15 --retry 2 "$base/sha256sums.txt" -o "$sums" || fail "下载 sha256sums.txt 失败"

[ -s "$pkg_file" ] || fail "插件安装包为空"
[ -s "$sums" ] || fail "sha256sums.txt 为空"

expected="$(awk -v f="$asset" '$2 == f {print $1}' "$sums" | head -n 1)"
[ -n "$expected" ] || fail "sha256sums.txt 中未找到 $asset"
actual="$(sha256sum "$pkg_file" | awk '{print $1}')"
[ "$actual" = "$expected" ] || fail "SHA256 校验失败"

pkg_install_file "$pkg_file" "$INSTALL_LOG" || {
	msg="$(tail -n 20 "$INSTALL_LOG" 2>/dev/null || true)"
	fail "安装 LuCI 插件失败: $msg"
}

installed_version="$(pkg_installed_version luci-app-vohive)"
installed_norm="$(normalize_plugin_version "${installed_version:-}")"
[ -n "$installed_norm" ] || installed_norm="$(cat /usr/share/vohive/plugin_version 2>/dev/null || true)"
[ "$installed_norm" = "$tag_norm" ] || {
	msg="$(tail -n 20 "$INSTALL_LOG" 2>/dev/null || true)"
	fail "安装后版本仍为 ${installed_version:-unknown}，期望 $tag。$msg"
}

printf '%s\n' "$tag_norm" > /usr/share/vohive/plugin_version 2>/dev/null || true
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache

printf '{"ok":true,"message":"%s"}\n' "$(json_escape "LuCI 插件已更新到 $tag，页面即将刷新。")"
