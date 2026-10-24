#!/bin/sh

# Delete a core instance. The active instance cannot be removed:
# switch to another instance first.

set -eu

. /usr/share/vohive/lib.sh

id="${1:-}"
fail() {
	printf '{"ok":false,"message":"%s"}\n' "$(json_escape "$*")"
	exit 1
}

instance_id_valid "$id" || fail "无效的实例 id"
[ -d "$(instance_dir "$id")" ] || fail "实例不存在"
[ "$id" != "$(active_instance_id)" ] || fail "当前运行的核心不能删除，请先切换到其他核心"

rm -rf "$(instance_dir "$id")"
printf '{"ok":true,"message":"实例已删除"}\n'
