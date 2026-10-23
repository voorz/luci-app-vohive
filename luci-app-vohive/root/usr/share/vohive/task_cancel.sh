#!/bin/sh

. /usr/share/vohive/task_lib.sh

id="${1:-}"
[ -n "$id" ] || id="$(cat "$CURRENT_TASK" 2>/dev/null || true)"

if [ -z "$id" ] || [ ! -f "$(task_status_file "$id")" ]; then
	printf '{"ok":false,"message":"没有可取消的任务"}\n'
	exit 1
fi

touch "$(task_cancel_file "$id")"
printf '{"ok":true,"message":"已请求取消下载"}\n'
