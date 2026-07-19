#!/bin/sh
# usb_status.sh — 扫描 USB 设备接口的驱动绑定状态
# 输出 JSON，供 LuCI 前端消费
# 用法: usb_status.sh [vid] [pid]
#   vid/pid 未传时从 UCI 读取，仍为空则扫描所有 USB 设备

. /lib/functions.sh

TARGET_VID=""
TARGET_PID=""

# 从 UCI 读取默认 VID/PID
config_load vohive-watchdog
config_get TARGET_VID main vid ""
config_get TARGET_PID main pid ""

# 命令行参数覆盖
[ -n "$1" ] && TARGET_VID="$1"
[ -n "$2" ] && TARGET_PID="$2"

# JSON 字符串转义（仅处理必要字符）
json_str() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/ /g'
}

# 读取 sysfs 文本，失败返回空
sysfs_read() {
	cat "$1" 2>/dev/null | tr -d '\n'
}

# 检测接口当前绑定的驱动
# 参数: 接口 sysfs 路径，如 /sys/bus/usb/devices/1-1:1.4
get_driver() {
	local iface_path="$1"
	local drv_link="${iface_path}/driver"
	if [ -L "$drv_link" ]; then
		readlink "$drv_link" | xargs basename 2>/dev/null
	else
		echo ""
	fi
}

# 检测网络接口名（qmi_wwan 绑定后会在 net/ 下出现）
get_net_iface() {
	local iface_path="$1"
	ls "${iface_path}/net/" 2>/dev/null | head -n1
}

# 检测 cdc-wdm 字符设备名
get_usbmisc() {
	local iface_path="$1"
	ls "${iface_path}/usbmisc/" 2>/dev/null | head -n1
}

# 获取 USB 接口协议类
get_iface_class() {
	local iface_path="$1"
	sysfs_read "${iface_path}/bInterfaceClass"
}

get_iface_subclass() {
	local iface_path="$1"
	sysfs_read "${iface_path}/bInterfaceSubClass"
}

get_iface_protocol() {
	local iface_path="$1"
	sysfs_read "${iface_path}/bInterfaceProtocol"
}

get_iface_number() {
	local iface_path="$1"
	sysfs_read "${iface_path}/bInterfaceNumber"
}

# 获取接口绑定的 tty 设备名（如 ttyUSB0）
get_tty_name() {
	local iface_path="$1"
	local tty
	# CDC ACM 设备在 tty/ 子目录下
	tty="$(ls "${iface_path}/tty/" 2>/dev/null | head -n1)"
	# USB serial 设备（option 驱动）直接作为接口子目录（如 ttyUSB0/）
	[ -n "$tty" ] || tty="$(ls -d "${iface_path}/ttyUSB"* 2>/dev/null | head -n1 | xargs basename 2>/dev/null)"
	printf '%s' "$tty"
}

# 根据 VID:PID 返回设备友好名称
device_friendly_name() {
	local vid="$1" pid="$2" product="$3"
	case "${vid}:${pid}" in
		2ca3:4006) printf 'DJI 4G 模块' ;;
		2c7c:0125) printf 'Quectel EC25' ;;
		2c7c:0124) printf 'Quectel EC21' ;;
		*)
			if [ -n "$product" ]; then
				printf '%s' "$product"
			else
				printf 'USB 设备'
			fi
			;;
	esac
}

# 扫描所有 USB 设备，构造 JSON 输出
scan_devices() {
	local devices_json=""
	local first_dev=1

	# 先收集 wwan 接口信息（用于设备级 net_state 计算）
	local wwan_ifaces=""
	local wwan_lookup=""
	local first_wwan=1
	for net in /sys/class/net/wwan*/; do
		[ -d "$net" ] || continue
		local wname wstate
		wname=$(basename "$net")
		wstate=$(sysfs_read "${net}operstate")
		wwan_lookup="${wwan_lookup} ${wname}:${wstate}"
		[ "$first_wwan" = "1" ] || wwan_ifaces="${wwan_ifaces},"
		first_wwan=0
		wwan_ifaces="${wwan_ifaces}{\"name\":\"$(json_str "$wname")\",\"state\":\"$(json_str "$wstate")\"}"
	done

	# 收集 /dev/cdc-wdm*
	local cdc_devs=""
	local first_cdc=1
	for cdc in /dev/cdc-wdm*; do
		[ -c "$cdc" ] || continue
		[ "$first_cdc" = "1" ] || cdc_devs="${cdc_devs},"
		first_cdc=0
		cdc_devs="${cdc_devs}\"$(json_str "$(basename "$cdc")")\""
	done

	for dev_path in /sys/bus/usb/devices/*/; do
		local dev
		dev=$(basename "$dev_path")

		# 跳过根 hub（无 idVendor）和接口目录（含冒号）
		echo "$dev" | grep -q ':' && continue
		[ ! -f "${dev_path}idVendor" ] && continue

		local vid pid manufacturer product serial speed
		vid=$(sysfs_read "${dev_path}idVendor")
		pid=$(sysfs_read "${dev_path}idProduct")

		[ -z "$vid" ] && continue

		# 过滤：若指定了 VID/PID，跳过不匹配的设备
		if [ -n "$TARGET_VID" ] && [ "$vid" != "$TARGET_VID" ]; then
			continue
		fi
		if [ -n "$TARGET_PID" ] && [ "$pid" != "$TARGET_PID" ]; then
			continue
		fi

		manufacturer=$(json_str "$(sysfs_read "${dev_path}manufacturer")")
		product=$(json_str "$(sysfs_read "${dev_path}product")")
		serial=$(json_str "$(sysfs_read "${dev_path}serial")")
		speed=$(sysfs_read "${dev_path}speed")
		busnum=$(sysfs_read "${dev_path}busnum")
		devnum=$(sysfs_read "${dev_path}devnum")

		# 先扫描一遍，找出所有 ff/ff/ff 接口中编号最大的（QMI 候选）
		local max_ff_num=-1
		for iface_path2 in /sys/bus/usb/devices/${dev}:*/; do
			[ ! -d "$iface_path2" ] && continue
			local cls2 sub2 pro2 num2
			cls2=$(sysfs_read "${iface_path2}bInterfaceClass")
			sub2=$(sysfs_read "${iface_path2}bInterfaceSubClass")
			pro2=$(sysfs_read "${iface_path2}bInterfaceProtocol")
			num2=$(sysfs_read "${iface_path2}bInterfaceNumber")
			if [ "$cls2" = "ff" ] && [ "$sub2" = "ff" ] && [ "$pro2" = "ff" ]; then
				num2_dec=$(printf '%d' "0x${num2}" 2>/dev/null || echo "${num2#0}")
				if [ "${num2_dec:-0}" -gt "$max_ff_num" ] 2>/dev/null; then
					max_ff_num="${num2_dec:-0}"
				fi
			fi
		done

		# 扫描该设备下的所有接口
		local ifaces_json=""
		local first_iface=1
		local dev_has_qmi="false"
		local dev_net_iface=""

		for iface_path in /sys/bus/usb/devices/${dev}:*/; do
			[ ! -d "$iface_path" ] && continue
			local iface
			iface=$(basename "$iface_path")

			local driver net_iface usbmisc iface_num iface_class iface_sub iface_proto tty_name
			driver=$(get_driver "$iface_path")
			net_iface=$(get_net_iface "$iface_path")
			usbmisc=$(get_usbmisc "$iface_path")
			iface_num=$(get_iface_number "$iface_path")
			iface_class=$(get_iface_class "$iface_path")
			iface_sub=$(get_iface_subclass "$iface_path")
			iface_proto=$(get_iface_protocol "$iface_path")
			tty_name=$(get_tty_name "$iface_path")

			# 追踪设备级状态
			if [ "$driver" = "qmi_wwan" ]; then
				dev_has_qmi="true"
			fi
			if [ -n "$net_iface" ]; then
				dev_net_iface="$net_iface"
			fi

			# QMI 候选：已有 cdc-wdm 绑定，或已绑定 qmi_wwan，
			# 或 ff/ff/ff 且是编号最大的接口（尚未绑定时的预判）
			local is_qmi_candidate="false"
			if [ -n "$usbmisc" ] || [ "$driver" = "qmi_wwan" ]; then
				is_qmi_candidate="true"
			elif [ "$iface_class" = "ff" ] && [ "$iface_sub" = "ff" ] && [ "$iface_proto" = "ff" ]; then
				iface_num_dec=$(printf '%d' "0x${iface_num}" 2>/dev/null || echo "${iface_num#0}")
				if [ "${iface_num_dec:-0}" -eq "$max_ff_num" ] 2>/dev/null; then
					is_qmi_candidate="true"
				fi
			fi

			# 判断状态（使用功能名称）
			local status="ok"
			local status_label=""
			if [ -z "$driver" ]; then
				status="unbound"
				status_label="未绑定"
			elif [ "$driver" = "qmi_wwan" ]; then
				status="qmi"
				status_label="QMI 数据"
			elif [ "$driver" = "option" ] && [ "$is_qmi_candidate" = "true" ]; then
				status="option_conflict"
				status_label="AT 串口（需转移）"
			elif [ "$driver" = "option" ]; then
				status="option"
				status_label="AT 串口"
			else
				status_label="$(json_str "$driver")"
			fi

			[ "$first_iface" = "1" ] || ifaces_json="${ifaces_json},"
			first_iface=0

			ifaces_json="${ifaces_json}{\"iface\":\"$(json_str "$iface")\",\"num\":\"$(json_str "$iface_num")\",\"class\":\"$(json_str "$iface_class")\",\"subclass\":\"$(json_str "$iface_sub")\",\"protocol\":\"$(json_str "$iface_proto")\",\"driver\":\"$(json_str "$driver")\",\"status\":\"${status}\",\"status_label\":\"$(json_str "$status_label")\",\"net_iface\":\"$(json_str "$net_iface")\",\"usbmisc\":\"$(json_str "$usbmisc")\",\"tty_name\":\"$(json_str "$tty_name")\",\"is_qmi_candidate\":${is_qmi_candidate}}"
		done

		# 计算设备级网络接口状态
		local dev_net_state=""
		if [ -n "$dev_net_iface" ]; then
			for pair in $wwan_lookup; do
				if [ "${pair%%:*}" = "$dev_net_iface" ]; then
					dev_net_state="${pair#*:}"
					break
				fi
			done
		fi

		# 设备友好名称
		local friendly_name
		friendly_name=$(device_friendly_name "$vid" "$pid" "$product")

		[ "$first_dev" = "1" ] || devices_json="${devices_json},"
		first_dev=0

		devices_json="${devices_json}{\"dev\":\"$(json_str "$dev")\",\"vid\":\"${vid}\",\"pid\":\"${pid}\",\"manufacturer\":\"${manufacturer}\",\"product\":\"${product}\",\"serial\":\"${serial}\",\"speed\":\"$(json_str "$speed")\",\"busnum\":\"$(json_str "$busnum")\",\"devnum\":\"$(json_str "$devnum")\",\"friendly_name\":\"$(json_str "$friendly_name")\",\"module_ready\":${dev_has_qmi},\"net_iface\":\"$(json_str "$dev_net_iface")\",\"net_state\":\"$(json_str "$dev_net_state")\",\"interfaces\":[${ifaces_json}]}"
	done

	printf '{"ok":true,"filter_vid":"%s","filter_pid":"%s","devices":[%s],"wwan_ifaces":[%s],"cdc_devs":[%s]}\n' \
		"$(json_str "$TARGET_VID")" \
		"$(json_str "$TARGET_PID")" \
		"$devices_json" \
		"$wwan_ifaces" \
		"$cdc_devs"
}

scan_devices
