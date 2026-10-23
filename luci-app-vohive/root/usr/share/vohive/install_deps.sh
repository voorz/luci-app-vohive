#!/bin/sh
# install_deps.sh — Install OS-layer driver packages the core depends on
#
# The vohive core can only see a USB modem once the kernel enumerates it
# as ttyUSB ports, which needs kmod-usb-serial + kmod-usb-serial-option.
# This is the install backend for the overview's dependency rows.
#
# Usage: install_deps.sh install_serial_drivers

set -eu

. /usr/share/vohive/lib.sh

action="${1:-}"

case "$action" in
	install_serial_drivers)
		packages="kmod-usb-serial kmod-usb-serial-option"
		;;
	*)
		printf '{"ok":false,"message":"%s"}\n' "$(json_escape "不支持的操作: $action")"
		exit 1
		;;
esac

output="$(pkg_install_names $packages 2>&1)" || {
	printf '{"ok":false,"message":"%s","output":"%s"}\n' "$(json_escape "安装失败")" "$(json_escape "$output")"
	exit 1
}

printf '{"ok":true,"message":"%s","output":"%s"}\n' "$(json_escape "安装完成")" "$(json_escape "$output")"
