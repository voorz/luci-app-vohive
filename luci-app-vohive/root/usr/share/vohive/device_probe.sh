#!/bin/sh

ACTION="${1:-probe}"
CACHE="/tmp/vohive/device-probe.json"

case "$ACTION" in
	status|probe)
		exec /usr/share/vohive/device_tools.sh "$ACTION"
		;;
	cache)
		if [ -s "$CACHE" ]; then
			cat "$CACHE"
		else
			printf '{"ok":false,"message":"暂无探测缓存","ports":[]}\n'
		fi
		;;
	*)
		printf '{"ok":false,"message":"只读探测接口不支持该操作"}\n'
		exit 1
		;;
esac
