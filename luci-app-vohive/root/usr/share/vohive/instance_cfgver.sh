#!/bin/sh

# Set an instance's config version (1.0 or 2.0).
# Usage: instance_cfgver.sh <id> <cfgver>
# The value is stored in the instance meta and takes effect on the
# instance's next start; a running instance is not disturbed.

set -eu

. /usr/share/vohive/lib.sh

id="${1:-}"
cfgver="${2:-}"
fail() {
	printf '{"ok":false,"message":"%s"}\n' "$(json_escape "$*")"
	exit 1
}

instance_id_valid "$id" || fail "无效的实例 id"
[ -x "$(instance_dir "$id")/vohive" ] || fail "实例不存在"
cfgver_valid "$cfgver" || fail "无效的配置版本: $cfgver"
instance_meta_set "$id" cfgver "$cfgver" || fail "保存配置版本失败"

printf '{"ok":true,"message":"%s"}\n' "$(json_escape "配置版本已设为 $cfgver，下次启动生效")"
