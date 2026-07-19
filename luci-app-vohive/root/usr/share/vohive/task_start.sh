#!/bin/sh

set -eu

. /usr/share/vohive/task_lib.sh

type="${1:-}"
shift || true

case "$type" in
	install_core|rollback_core|update_plugin|convert_identity|switch_usbnet|probe_device) ;;
	*) printf '{"ok":false,"message":"不支持的任务类型"}\n'; exit 1 ;;
esac

task_mkdirs
task_cleanup_old

if [ -s "$CURRENT_TASK" ]; then
	current="$(cat "$CURRENT_TASK" 2>/dev/null || true)"
	pid="$(cat "$(task_pid_file "$current")" 2>/dev/null || true)"
	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
		printf '{"ok":true,"id":"%s","message":"已有更新任务正在运行"}\n' "$(json_escape "$current")"
		exit 0
	fi
fi

id="$(date +%s)-$$"
printf '%s\n' "$id" > "$CURRENT_TASK"
task_write_status "$id" "$type" "starting" "starting" "正在启动任务" "" 0 0 0 0

/usr/share/vohive/task_worker.sh "$id" "$type" "$@" >/tmp/vohive/task-$id.out 2>&1 &
pid="$!"
printf '%s\n' "$pid" > "$(task_pid_file "$id")"

printf '{"ok":true,"id":"%s","message":"任务已启动"}\n' "$(json_escape "$id")"
