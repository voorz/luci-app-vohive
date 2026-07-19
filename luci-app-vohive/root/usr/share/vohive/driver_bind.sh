#!/bin/sh
# driver_bind.sh — 手动执行 USB 接口驱动绑定/解绑操作
# 用法:
#   driver_bind.sh bind_qmi   <iface> [vid] [pid]
#     将指定接口从当前驱动解绑并绑定到 qmi_wwan
#     先尝试直接绑定，失败时才用 vid/pid 注册 new_id 作为兜底
#     绑定成功后立即清理 new_id，避免 qmi_wwan 全量抢占同 VID/PID 接口
#
#   driver_bind.sh unbind     <iface>
#     从当前驱动解绑指定接口
#
#   driver_bind.sh add_id     <vid> <pid>
#     仅向 qmi_wwan 注册设备 ID
#
#   driver_bind.sh cleanup
#     清理 qmi_wwan 的 new_id 注册表，防止 USB 重新枚举时全量抢占

ACTION="$1"
IFACE="$2"
VID="$3"
PID="$4"

ok() {
	printf '{"ok":true,"message":"%s"}\n' "$1"
}

fail() {
	printf '{"ok":false,"message":"%s"}\n' "$1"
}

# 验证接口名格式（如 1-1:1.4），防止路径注入
validate_iface() {
	echo "$1" | grep -qE '^[0-9]+-[0-9]+(.[0-9]+)*:[0-9]+\.[0-9]+$'
}

validate_vidpid() {
	echo "$1" | grep -qE '^[0-9a-fA-F]{4}$'
}

case "$ACTION" in

bind_qmi)
	[ -z "$IFACE" ] && { fail "缺少接口参数"; exit 1; }
	validate_iface "$IFACE" || { fail "接口名格式无效: $IFACE"; exit 1; }

	IFACE_PATH="/sys/bus/usb/devices/${IFACE}"
	[ -d "$IFACE_PATH" ] || { fail "接口不存在: $IFACE"; exit 1; }

	BIND_FILE="/sys/bus/usb/drivers/qmi_wwan/bind"
	[ -f "$BIND_FILE" ] || { fail "qmi_wwan 驱动不可用，请确认 kmod-usb-net-qmi-wwan 已安装"; exit 1; }

	# 1. 先从当前驱动解绑（避免 new_id 导致 qmi_wwan 全量抢占）
	DRV_LINK="${IFACE_PATH}/driver"
	if [ -L "$DRV_LINK" ]; then
		CURRENT_DRV=$(readlink "$DRV_LINK" | xargs basename 2>/dev/null)
		UNBIND_FILE="/sys/bus/usb/drivers/${CURRENT_DRV}/unbind"
		if [ -f "$UNBIND_FILE" ]; then
			printf '%s\n' "$IFACE" > "$UNBIND_FILE" 2>/dev/null
			RET=$?
			[ "$RET" -ne 0 ] && { fail "从 ${CURRENT_DRV} 解绑 ${IFACE} 失败 (ret=${RET})"; exit 1; }
			sleep 1
		fi
	fi

	# 2. 尝试直接绑定到 qmi_wwan（不使用 new_id，避免全量抢占）
	printf '%s\n' "$IFACE" > "$BIND_FILE" 2>/dev/null
	RET=$?

	# 3. 若直接绑定失败且提供了 vid/pid，使用 new_id 注册后重试
	if [ "$RET" -ne 0 ] && [ -n "$VID" ] && [ -n "$PID" ]; then
		validate_vidpid "$VID" || { fail "VID 格式无效: $VID"; exit 1; }
		validate_vidpid "$PID" || { fail "PID 格式无效: $PID"; exit 1; }
		NEW_ID_FILE="/sys/bus/usb/drivers/qmi_wwan/new_id"
		if [ -f "$NEW_ID_FILE" ]; then
			VID_LOWER=$(echo "$VID" | tr '[:upper:]' '[:lower:]')
			PID_LOWER=$(echo "$PID" | tr '[:upper:]' '[:lower:]')
			printf '%s %s\n' "$VID_LOWER" "$PID_LOWER" \
				> "$NEW_ID_FILE" 2>/dev/null || true
			sleep 1
			# new_id 可能已触发内核自动绑定，先检查是否已绑定
			if readlink "${IFACE_PATH}/driver" 2>/dev/null | grep -q 'qmi_wwan'; then
				RET=0
			else
				printf '%s\n' "$IFACE" > "$BIND_FILE" 2>/dev/null
				RET=$?
			fi
			# 绑定成功后立即清理 new_id，防止 qmi_wwan 抢占其他接口
			REMOVE_ID_FILE="/sys/bus/usb/drivers/qmi_wwan/remove_id"
			[ -f "$REMOVE_ID_FILE" ] && printf '%s %s\n' "$VID_LOWER" "$PID_LOWER" > "$REMOVE_ID_FILE" 2>/dev/null || true
		fi
	fi

	[ "$RET" -ne 0 ] && { fail "绑定 ${IFACE} 到 qmi_wwan 失败 (ret=${RET})"; exit 1; }

	# 4. 等待网络接口出现并启用 raw_ip
	sleep 2
	NET_IFACE=$(ls "/sys/bus/usb/devices/${IFACE}/net/" 2>/dev/null | head -n1)
	if [ -n "$NET_IFACE" ]; then
		RAW_IP="/sys/class/net/${NET_IFACE}/qmi/raw_ip"
		[ -f "$RAW_IP" ] && printf 'Y\n' > "$RAW_IP" 2>/dev/null || true
		ok "已绑定 ${IFACE} 到 qmi_wwan，网络接口: ${NET_IFACE}"
	else
		ok "已绑定 ${IFACE} 到 qmi_wwan（网络接口暂未出现，请刷新）"
	fi
;;

unbind)
	[ -z "$IFACE" ] && { fail "缺少接口参数"; exit 1; }
	validate_iface "$IFACE" || { fail "接口名格式无效: $IFACE"; exit 1; }

	IFACE_PATH="/sys/bus/usb/devices/${IFACE}"
	[ -d "$IFACE_PATH" ] || { fail "接口不存在: $IFACE"; exit 1; }

	DRV_LINK="${IFACE_PATH}/driver"
	if [ ! -L "$DRV_LINK" ]; then
		fail "${IFACE} 当前未绑定任何驱动"
		exit 1
	fi

	CURRENT_DRV=$(readlink "$DRV_LINK" | xargs basename 2>/dev/null)
	UNBIND_FILE="/sys/bus/usb/drivers/${CURRENT_DRV}/unbind"
	[ -f "$UNBIND_FILE" ] || { fail "驱动 ${CURRENT_DRV} 的 unbind 节点不存在"; exit 1; }

	printf '%s\n' "$IFACE" > "$UNBIND_FILE" 2>/dev/null
	RET=$?
	[ "$RET" -ne 0 ] && { fail "从 ${CURRENT_DRV} 解绑 ${IFACE} 失败 (ret=${RET})"; exit 1; }

	ok "已从 ${CURRENT_DRV} 解绑 ${IFACE}"
	;;

add_id)
	[ -z "$VID" ] || [ -z "$PID" ] && { fail "缺少 vid/pid 参数"; exit 1; }
	validate_vidpid "$VID" || { fail "VID 格式无效"; exit 1; }
	validate_vidpid "$PID" || { fail "PID 格式无效"; exit 1; }

	NEW_ID_FILE="/sys/bus/usb/drivers/qmi_wwan/new_id"
	[ -f "$NEW_ID_FILE" ] || { fail "qmi_wwan 驱动不可用"; exit 1; }

	printf '%s %s\n' "$(echo "$VID" | tr '[:upper:]' '[:lower:]')" "$(echo "$PID" | tr '[:upper:]' '[:lower:]')" \
		> "$NEW_ID_FILE" 2>/dev/null
	RET=$?
	[ "$RET" -ne 0 ] && { fail "注册设备 ID ${VID}:${PID} 到 qmi_wwan 失败"; exit 1; }

	ok "已注册设备 ID ${VID}:${PID} 到 qmi_wwan 驱动"
	;;

cleanup)
	# 清理 qmi_wwan 的 new_id，防止 USB 重新枚举时全量抢占接口
	NEW_ID_FILE="/sys/bus/usb/drivers/qmi_wwan/new_id"
	REMOVE_ID_FILE="/sys/bus/usb/drivers/qmi_wwan/remove_id"
	if [ ! -f "$NEW_ID_FILE" ]; then
		ok "qmi_wwan 驱动不可用，无需清理"
		exit 0
	fi
	if [ ! -f "$REMOVE_ID_FILE" ]; then
		ok "qmi_wwan 不支持 remove_id，无法清理"
		exit 0
	fi
	count=0
	while read -r vid pid rest; do
		[ -n "$vid" ] && [ -n "$pid" ] || continue
		printf '%s %s\n' "$vid" "$pid" > "$REMOVE_ID_FILE" 2>/dev/null || true
		count=$((count + 1))
	done < "$NEW_ID_FILE"
	ok "已清理 qmi_wwan new_id（${count} 条记录）"
	;;

*)
	fail "未知操作: ${ACTION}，支持: bind_qmi, unbind, add_id, cleanup"
	;;

esac
