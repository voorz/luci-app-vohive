#!/bin/sh

# Receive a base64-encoded chunk and write/append to upload temp file.
# Usage: receive_upload.sh <mode> <base64_data>
#   mode = "new"     → truncate file and write chunk
#   mode = "append"  → append chunk to existing file

set -eu

UPLOAD_DIR="/tmp/vohive/upload"
UPLOAD_FILE="$UPLOAD_DIR/vohive-core-upload"

mode="${1:-}"
data="${2:-}"

[ -n "$mode" ] || { printf '{"ok":false,"message":"缺少模式参数"}'; exit 1; }
[ -n "$data" ] || { printf '{"ok":false,"message":"缺少数据参数"}'; exit 1; }

mkdir -p "$UPLOAD_DIR"

case "$mode" in
	new)
		printf '%s' "$data" | base64 -d > "$UPLOAD_FILE"
		;;
	append)
		printf '%s' "$data" | base64 -d >> "$UPLOAD_FILE"
		;;
	*)
		printf '{"ok":false,"message":"未知模式: %s"}' "$(json_escape "$mode")"
		exit 1
		;;
esac

actual_size=$(wc -c < "$UPLOAD_FILE" 2>/dev/null || echo 0)
printf '{"ok":true,"size":%s}' "$actual_size"
