#!/bin/sh

set -eu

action="${1:-}"

json_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

run_action() {
	case "$action" in
		start)
			[ -x /etc/vohive/bin/vohive ] || {
				printf '%s\n' "VoHive core is not installed"
				return 1
			}
			/usr/share/vohive/render_config.sh
			uci set vohive.main.enabled='1'
			uci commit vohive
			/etc/init.d/vohive enable
			/etc/init.d/vohive start
			;;
		stop)
			uci set vohive.main.enabled='0'
			uci commit vohive
			/etc/init.d/vohive stop || true
			/etc/init.d/vohive disable
			;;
		restart)
			/usr/share/vohive/render_config.sh
			/etc/init.d/vohive restart
			;;
		*)
			printf '{"ok":false,"message":"Unsupported service action"}\n'
			exit 1
			;;
	esac
}

output="$(run_action 2>&1)" || {
	printf '{"ok":false,"message":"%s"}\n' "$(json_escape "$output")"
	exit 1
}

printf '{"ok":true,"message":"%s"}\n' "$(json_escape "$output")"
