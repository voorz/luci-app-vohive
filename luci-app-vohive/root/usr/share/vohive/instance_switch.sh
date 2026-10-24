#!/bin/sh

# Switch the running core to another instance (mutually exclusive).
# Usage: instance_switch.sh <id>
# If the service is running: stop -> flip pointer -> start -> verify.
# On start failure, roll back to the previous instance and restart it.
# If the service is stopped: only flip the pointer (next start uses it).

set -eu

. /usr/share/vohive/lib.sh

id="${1:-}"
fail() {
	printf '{"ok":false,"message":"%s"}\n' "$(json_escape "$*")"
	exit 1
}

instance_id_valid "$id" || fail "无效的实例 id"
[ -x "$(instance_dir "$id")/vohive" ] || fail "实例不存在"

migrate_legacy_instance 2>/dev/null || true
prev="$(active_instance_id)"
[ "$id" = "$prev" ] && {
	printf '{"ok":true,"message":"已经是当前核心"}\n'
	exit 0
}

was_running=0
/etc/init.d/vohive running >/dev/null 2>&1 && was_running=1

if [ "$was_running" = "1" ]; then
	/etc/init.d/vohive stop || true
fi

printf '%s\n' "$id" > "$ACTIVE_FILE"

if [ "$was_running" = "0" ]; then
	printf '{"ok":true,"message":"已切换核心（服务未运行，下次启动生效）"}\n'
	exit 0
fi

if /etc/init.d/vohive start >/tmp/vohive-start.log 2>&1; then
	# Verify the new core actually stays up before declaring success.
	sleep 2
	if /etc/init.d/vohive running >/dev/null 2>&1; then
		printf '{"ok":true,"message":"已切换核心"}\n'
		exit 0
	fi
fi

# Roll back: restore the previous instance and restart it.
printf '%s\n' "$prev" > "$ACTIVE_FILE"
if [ -n "$prev" ]; then
	/etc/init.d/vohive start >/tmp/vohive-start.log 2>&1 || true
fi
fail "新核心启动失败，已回滚到上一个核心"
