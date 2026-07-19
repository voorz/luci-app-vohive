#!/bin/sh

set -eu

. /usr/share/vohive/lib.sh

if command -v logread >/dev/null 2>&1; then
	logread -c >/dev/null 2>&1 || true
fi

if [ -d /tmp/vohive/logs ]; then
	find /tmp/vohive/logs -maxdepth 1 -type f -exec sh -c ': > "$1"' _ {} \; 2>/dev/null || true
fi

printf '{"ok":true,"message":"%s"}\n' "$(json_escape "日志已清理")"
