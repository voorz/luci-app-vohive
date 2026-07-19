#!/bin/sh

set -eu

/usr/share/vohive/render_config.sh

if /etc/init.d/vohive running >/dev/null 2>&1; then
	/etc/init.d/vohive restart
fi

printf '{"ok":true,"message":"配置已保存"}\n'
