#!/bin/sh

lines="${1:-100}"
case "$lines" in
	''|*[!0-9]*) lines=100 ;;
esac
[ "$lines" -gt 0 ] && [ "$lines" -le 500 ] || lines=100

if command -v logread >/dev/null 2>&1; then
	logread -e vohive 2>/dev/null | tail -n "$lines" || true
fi

if [ -d /tmp/vohive/logs ]; then
	find /tmp/vohive/logs -maxdepth 1 -type f 2>/dev/null | while read -r file; do
		printf '\n==> %s <==\n' "$file"
		tail -n "$lines" "$file" 2>/dev/null || true
	done
fi
