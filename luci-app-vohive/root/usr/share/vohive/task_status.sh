#!/bin/sh

. /usr/share/vohive/task_lib.sh

id="${1:-}"
task_mkdirs
task_cleanup_old

if [ -z "$id" ]; then
	id="$(cat "$CURRENT_TASK" 2>/dev/null || true)"
fi

if [ -z "$id" ] || [ ! -f "$(task_status_file "$id")" ]; then
	printf '{"ok":true,"running":false,"message":"没有正在运行的任务"}\n'
	exit 0
fi

cat "$(task_status_file "$id")"
