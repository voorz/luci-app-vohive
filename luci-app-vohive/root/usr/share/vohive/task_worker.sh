#!/bin/sh

set -e

. /usr/share/vohive/task_lib.sh

id="${1:-}"
type="${2:-}"
shift 2 || true

# 确保任何异常退出都将状态标记为 failed；但如果任务已经由
# task_fail/task_finish 明确写过 failed/completed，就不要用通用
# 消息覆盖掉具体的失败原因。
trap 'rc=$?; if [ "$rc" -ne 0 ]; then cur_state="$(jsonfilter -i "$(task_status_file "$id")" -e "@.state" 2>/dev/null || true)"; case "$cur_state" in failed|completed) ;; *) task_fail "$id" "$type" "任务执行异常退出（退出码 $rc）" 2>/dev/null || true ;; esac; fi' EXIT

BIN_DIR="/etc/vohive/bin"
BIN="$BIN_DIR/vohive"
VERSION_FILE="$BIN_DIR/version"
ARCH_FILE="$BIN_DIR/arch"
PLUGIN_REPO="$DEFAULT_PLUGIN_REPO"

[ -n "$id" ] || exit 1
[ -n "$type" ] || exit 1

finish_ok() {
	task_finish "$id" "$type" 1 "$1"
	exit 0
}

fail() {
	task_fail "$id" "$type" "$1"
}

release_json_for_version() {
	local repo="$1"
	local version="$2"

	if [ "$version" = "latest" ] || [ "$version" = "stable" ]; then
		curl -fsSL --show-error --connect-timeout 15 --retry 2 "https://api.github.com/repos/$repo/releases/latest"
	else
		curl -fsSL --show-error --connect-timeout 15 --retry 2 "https://api.github.com/repos/$repo/releases/tags/$version"
	fi
}

install_core() {
	local repo repo_input version selected_version core_arch core_arch_input asset_arch release_json asset url downloaded total was_running

	repo_input="${2:-}"
	if [ -n "$repo_input" ]; then
		repo="$(github_repo_slug "$repo_input")"
	else
		repo="$(github_repo_slug "$(uci_get release_repo "$DEFAULT_CORE_REPO")")"
	fi
	validate_github_repo "$repo" || fail "Invalid GitHub repository: $repo"

	version="${1:-}"
	[ -n "$version" ] || version="$(uci_get version 'latest')"
	[ -n "$version" ] || version="latest"
	selected_version="$version"
	core_arch_input="${3:-}"
	if [ -n "$core_arch_input" ]; then
		core_arch="$core_arch_input"
	else
		core_arch="$(uci_get core_arch '')"
	fi
	asset_arch="$(resolve_asset_arch "$core_arch")" || fail "Unsupported configured architecture: $core_arch"

	uci set vohive.main.release_repo="https://github.com/$repo" 2>/dev/null || true
	uci set vohive.main.version="$selected_version" 2>/dev/null || true
	[ -z "$core_arch" ] || uci set vohive.main.core_arch="$core_arch" 2>/dev/null || true
	uci commit vohive 2>/dev/null || true

	task_log "$id" "查询 VoHive Release"
	task_write_status "$id" "$type" "running" "prepare" "正在查询 VoHive Release" "" 0 0 0 0
	release_json="$(release_json_for_version "$repo" "$version")" || fail "Failed to query release"
	version="$(printf '%s' "$release_json" | jsonfilter -e '@.tag_name' 2>/dev/null || true)"
	[ -n "$version" ] || fail "Failed to parse release"

	asset="vohive_${version}_linux_${asset_arch}"
	url="https://github.com/$repo/releases/download/$version/$asset"
	downloaded="$DOWNLOAD_DIR/$asset"
	total="$(task_asset_size "$release_json" "$asset")"

	mkdir -p "$BIN_DIR" "$DOWNLOAD_DIR"
	rm -f "$downloaded"
	task_download "$id" "$type" "$url" "$downloaded" "$asset" "$total"
	[ -s "$downloaded" ] || fail "Downloaded file is empty"

	task_log "$id" "校验核心文件"
	task_write_status "$id" "$type" "running" "verify" "正在校验核心文件" "$asset" "$(wc -c < "$downloaded" 2>/dev/null || echo 0)" "$total" 0 0
	chmod +x "$downloaded"
	if command -v file >/dev/null 2>&1; then
		file "$downloaded" | grep -Eq 'ELF|executable' || {
			rm -f "$downloaded"
			fail "Downloaded file is not an executable"
		}
	fi

	was_running=0
	/etc/init.d/vohive running >/dev/null 2>&1 && was_running=1
	task_write_status "$id" "$type" "running" "install" "正在安装核心" "" 0 0 0 0
	[ "$was_running" = "0" ] || /etc/init.d/vohive stop || true

	cp -f "$downloaded" "$BIN"
	chmod 0755 "$BIN"
	printf '%s\n' "$version" > "$VERSION_FILE"
	printf '%s\n' "$asset_arch" > "$ARCH_FILE"

	if [ "$was_running" = "1" ]; then
		task_write_status "$id" "$type" "running" "restart" "正在重启 VoHive 服务" "" 0 0 0 0
		if ! /etc/init.d/vohive start >/tmp/vohive-start.log 2>&1; then
			fail "核心已安装但服务启动失败"
		fi
	fi

	rm -f "$downloaded" "$BIN_DIR/vohive.bak"
	finish_ok "已安装 VoHive 核心 $version"
}

update_plugin() {
	local json tag tag_norm asset ext base pkg_file sums total expected actual installed_version installed_norm msg install_log

	command -v curl >/dev/null 2>&1 || fail "缺少命令: curl"
	command -v jsonfilter >/dev/null 2>&1 || fail "缺少命令: jsonfilter"
	command -v sha256sum >/dev/null 2>&1 || fail "缺少命令: sha256sum"
	pkg_mgr >/dev/null 2>&1 || fail "缺少包管理器: 需要 opkg（OpenWrt 24）或 apk（OpenWrt 25）"

	tmp_avail="$(df -kP /tmp 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)"
	[ "${tmp_avail:-0}" -ge 2048 ] || fail "/tmp 临时空间不足，至少需要 2 MB"

	install_log="/tmp/vohive-plugin-install.log"
	ext="$(pkg_ext)"

	task_log "$id" "查询 LuCI 插件最新版本"
	task_write_status "$id" "$type" "running" "prepare" "正在查询 LuCI 插件最新版本" "" 0 0 0 0
	json="$(curl -fsSL --show-error --connect-timeout 15 --retry 2 "https://api.github.com/repos/$PLUGIN_REPO/releases/latest")" || fail "查询插件最新版本失败"
	tag="$(printf '%s' "$json" | jsonfilter -e '@.tag_name' 2>/dev/null)" || true
	[ -n "$tag" ] || fail "无法解析插件最新版本"
	: "${tag:=unknown}"
	tag_norm="$(normalize_plugin_version "$tag")"

	asset="$(select_plugin_asset "$json")" || fail "最新 Release 未找到 luci-app-vohive *.${ext} 安装包"

	base="https://github.com/$PLUGIN_REPO/releases/download/$tag"
	pkg_file="$DOWNLOAD_DIR/$asset"
	sums="$DOWNLOAD_DIR/sha256sums.txt"
	total="$(task_asset_size "$json" "$asset")"

	rm -f "$pkg_file" "$sums"
	task_download "$id" "$type" "$base/$asset" "$pkg_file" "$asset" "$total"
	task_download "$id" "$type" "$base/sha256sums.txt" "$sums" "sha256sums.txt" "$(task_asset_size "$json" "sha256sums.txt")"

	[ -s "$pkg_file" ] || fail "插件安装包为空"
	[ -s "$sums" ] || fail "sha256sums.txt 为空"

	task_log "$id" "校验插件安装包"
	task_write_status "$id" "$type" "running" "verify" "正在校验插件安装包" "$asset" "$(wc -c < "$pkg_file" 2>/dev/null || echo 0)" "$total" 0 0
	expected="$(awk -v f="$asset" '$2 == f {print $1}' "$sums" | head -n 1)"
	[ -n "$expected" ] || {
		rm -f "$pkg_file" "$sums"
		fail "sha256sums.txt 中未找到 $asset"
	}
	actual="$(sha256sum "$pkg_file" | awk '{print $1}')"
	[ "$actual" = "$expected" ] || {
		rm -f "$pkg_file" "$sums"
		fail "SHA256 校验失败"
	}

	task_log "$id" "安装 LuCI 插件"
	task_write_status "$id" "$type" "running" "install" "正在安装 LuCI 插件" "" 0 0 0 0
	pkg_install_file "$pkg_file" "$install_log" || {
		msg="$(tail -n 20 "$install_log" 2>/dev/null || true)"
		fail "安装 LuCI 插件失败: $msg"
	}

	installed_version="$(pkg_installed_version luci-app-vohive)"
	installed_norm="$(normalize_plugin_version "${installed_version:-}")"
	[ -n "$installed_norm" ] || installed_norm="$(cat /usr/share/vohive/plugin_version 2>/dev/null || true)"
	[ "$installed_norm" = "$tag_norm" ] || {
		msg="$(tail -n 20 "$install_log" 2>/dev/null || true)"
		fail "安装后版本仍为 ${installed_version:-unknown}，期望 $tag。$msg"
	}

	printf '%s\n' "$tag_norm" > /usr/share/vohive/plugin_version 2>/dev/null || true
	# Refresh the plugin-status cache with the release this task already
	# fetched (wrapped as a list, the cache's format), so the next page
	# load compares against post-update data, not a stale snapshot.
	mkdir -p /tmp/vohive
	printf '[%s]' "$json" > /tmp/vohive/plugin-releases.json
	date +%s > /tmp/vohive/plugin-releases.ts
	rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
	finish_ok "LuCI 插件已更新到 $tag，页面即将刷新。"
}

upload_core() {
	local upload_file="$DOWNLOAD_DIR/vohive-core-upload"
	local version="--"
	local asset_arch was_running api_port api_token api_version

	[ -s "$upload_file" ] || fail "上传文件不存在或为空"

	task_log "$id" "校验上传的核心文件"
	task_write_status "$id" "$type" "running" "verify" "正在校验核心文件" "" 0 0 0 0
	chmod +x "$upload_file"
	if command -v file >/dev/null 2>&1; then
		file "$upload_file" | grep -Eq 'ELF|executable' || {
			rm -f "$upload_file"
			fail "上传文件不是有效的可执行文件"
		}
	fi

	asset_arch="$(resolve_asset_arch "$(uci_get core_arch '')" 2>/dev/null || true)"
	[ -n "$asset_arch" ] || asset_arch="unknown"

	was_running=0
	/etc/init.d/vohive running >/dev/null 2>&1 && was_running=1
	task_write_status "$id" "$type" "running" "install" "正在安装核心" "" 0 0 0 0
	[ "$was_running" = "0" ] || /etc/init.d/vohive stop || true

	mkdir -p "$BIN_DIR"
	cp -f "$upload_file" "$BIN"
	chmod 0755 "$BIN"
	printf '%s\n' "$asset_arch" > "$ARCH_FILE"

	task_write_status "$id" "$type" "running" "restart" "正在启动 VoHive 服务" "" 0 0 0 0
	if ! /etc/init.d/vohive start >/tmp/vohive-start.log 2>&1; then
		fail "核心已安装但服务启动失败"
	fi

	# 等待服务就绪后从核心 API 获取真实版本号
	sleep 3
	api_port="$(uci_get port '7575')"
	api_token="$(curl -s --connect-timeout 3 http://127.0.0.1:$api_port/api/auth/login \
		-X POST -H 'Content-Type: application/json' \
		-d '{"username":"'"$(uci_get username 'admin')"'","password":"'"$(uci_get password 'admin')"'"}' \
		2>/dev/null | jsonfilter -e '@.token' 2>/dev/null || true)"
	if [ -n "$api_token" ]; then
		api_version="$(curl -s --connect-timeout 3 http://127.0.0.1:$api_port/api/system/info \
			-H "Authorization: Bearer $api_token" \
			2>/dev/null | jsonfilter -e '@.version' 2>/dev/null || true)"
		[ -n "$api_version" ] && version="$api_version"
	fi
	printf '%s\n' "$version" > "$VERSION_FILE"

	rm -f "$upload_file" "$BIN_DIR/vohive.bak"
	finish_ok "已安装 VoHive 核心（$version）"
}

install_instance_binary() {
	# $1 = target dir, $2 = mode (repo|upload), $3 = version (repo mode)
	# Prints resolved version on stdout. Dies via fail() on error.
	local dir="$1" mode="$2" version="$3"
	local repo release_json tag asset asset_arch url downloaded total

	if [ "$mode" = "repo" ]; then
		repo="$(github_repo_slug "$(uci_get release_repo "$DEFAULT_CORE_REPO")")"
		validate_github_repo "$repo" || fail "Invalid GitHub repository: $repo"
		[ -n "$version" ] || version="latest"
		uci set vohive.main.release_repo="https://github.com/$repo" 2>/dev/null || true
		uci commit vohive 2>/dev/null || true
		asset_arch="$(resolve_asset_arch "$(uci_get core_arch '')")" || fail "Unsupported configured architecture"
		task_log "$id" "查询 VoHive Release"
		task_write_status "$id" "$type" "running" "prepare" "正在查询 VoHive Release" "" 0 0 0 0
		release_json="$(release_json_for_version "$repo" "$version")" || fail "Failed to query release"
		tag="$(printf '%s' "$release_json" | jsonfilter -e '@.tag_name' 2>/dev/null || true)"
		[ -n "$tag" ] || fail "Failed to parse release"
		asset="vohive_${tag}_linux_${asset_arch}"
		url="https://github.com/$repo/releases/download/$tag/$asset"
		downloaded="$DOWNLOAD_DIR/$asset"
		total="$(task_asset_size "$release_json" "$asset")"
		mkdir -p "$DOWNLOAD_DIR"
		rm -f "$downloaded"
		task_download "$id" "$type" "$url" "$downloaded" "$asset" "$total"
		[ -s "$downloaded" ] || fail "Downloaded file is empty"
		chmod +x "$downloaded"
		if command -v file >/dev/null 2>&1; then
			file "$downloaded" | grep -Eq 'ELF|executable' || {
				rm -f "$downloaded"
				fail "Downloaded file is not an executable"
			}
		fi
		cp -f "$downloaded" "$dir/vohive"
		chmod 0755 "$dir/vohive"
		printf '%s\n' "$asset_arch" > "$dir/arch"
		rm -f "$downloaded"
		printf '%s' "$tag"
		return 0
	fi

	if [ "$mode" = "upload" ]; then
		[ -s "$DOWNLOAD_DIR/vohive-core-upload" ] || fail "上传文件不存在或为空"
		chmod +x "$DOWNLOAD_DIR/vohive-core-upload"
		if command -v file >/dev/null 2>&1; then
			file "$DOWNLOAD_DIR/vohive-core-upload" | grep -Eq 'ELF|executable' || {
				rm -f "$DOWNLOAD_DIR/vohive-core-upload"
				fail "上传文件不是有效的可执行文件"
			}
		fi
		cp -f "$DOWNLOAD_DIR/vohive-core-upload" "$dir/vohive"
		chmod 0755 "$dir/vohive"
		asset_arch="$(resolve_asset_arch "$(uci_get core_arch '')" 2>/dev/null || true)"
		printf '%s\n' "${asset_arch:-unknown}" > "$dir/arch"
		rm -f "$DOWNLOAD_DIR/vohive-core-upload"
		printf '%s' "--"
		return 0
	fi

	fail "不支持的实例来源: $mode"
}

instance_add() {
	local name="$1" mode="$2" version="${3:-}"
	local inst_id dir resolved

	[ -n "$name" ] || fail "实例名字不能为空"
	[ "$mode" = "repo" ] || [ "$mode" = "upload" ] || fail "不支持的实例来源: $mode"

	migrate_legacy_instance 2>/dev/null || true
	mkdir -p "$INSTANCES_DIR"
	inst_id="inst-$(date +%s)"
	[ -e "$(instance_dir "$inst_id")" ] && inst_id="inst-$(date +%s)-$$"
	dir="$(instance_dir "$inst_id")"
	mkdir -p "$dir" || fail "无法创建实例目录"

	task_log "$id" "正在创建核心实例"
	task_write_status "$id" "$type" "running" "install" "正在创建核心实例" "" 0 0 0 0
	resolved="$(install_instance_binary "$dir" "$mode" "$version")"
	printf '%s\n' "$resolved" > "$dir/version"
	{
		printf 'name=%s\n' "$name"
		printf 'source=%s\n' "$mode"
		printf 'created=%s\n' "$(date +%s)"
	} > "$dir/meta"

	finish_ok "已创建核心实例 $name"
}

instance_replace() {
	local inst_id="$1" mode="$2" version="${3:-}"
	local dir resolved was_running active

	[ "$mode" = "repo" ] || [ "$mode" = "upload" ] || fail "不支持的实例来源: $mode"
	instance_id_valid "$inst_id" || fail "无效的实例 id"
	dir="$(instance_dir "$inst_id")"
	[ -x "$dir/vohive" ] || fail "实例不存在"

	migrate_legacy_instance 2>/dev/null || true
	active="$(active_instance_id)"
	was_running=0
	if [ "$inst_id" = "$active" ]; then
		/etc/init.d/vohive running >/dev/null 2>&1 && was_running=1
	fi

	task_log "$id" "正在替换核心"
	task_write_status "$id" "$type" "running" "install" "正在替换核心" "" 0 0 0 0
	cp -f "$dir/vohive" "$dir/vohive.bak"
	if [ "$was_running" = "1" ]; then
		/etc/init.d/vohive stop || true
	fi

	resolved="$(install_instance_binary "$dir" "$mode" "$version")" || {
		cp -f "$dir/vohive.bak" "$dir/vohive"
		[ "$was_running" = "1" ] && /etc/init.d/vohive start >/tmp/vohive-start.log 2>&1 || true
		fail "替换失败，已恢复原核心"
	}
	printf '%s\n' "$resolved" > "$dir/version"
	# Read the old meta BEFORE truncating it with the redirect below.
	old_name="$(instance_meta_get "$inst_id" name 2>/dev/null || echo "$inst_id")"
	old_created="$(instance_meta_get "$inst_id" created 2>/dev/null || date +%s)"
	{
		printf 'name=%s\n' "$old_name"
		printf 'source=%s\n' "$mode"
		printf 'created=%s\n' "$old_created"
	} > "$dir/meta"

	if [ "$was_running" = "1" ]; then
		task_write_status "$id" "$type" "running" "restart" "正在重启 VoHive 服务" "" 0 0 0 0
		if ! /etc/init.d/vohive start >/tmp/vohive-start.log 2>&1; then
			cp -f "$dir/vohive.bak" "$dir/vohive"
			/etc/init.d/vohive start >/tmp/vohive-start.log 2>&1 || true
			fail "替换后服务启动失败，已恢复原核心"
		fi
		sleep 2
		if ! /etc/init.d/vohive running >/dev/null 2>&1; then
			cp -f "$dir/vohive.bak" "$dir/vohive"
			/etc/init.d/vohive start >/tmp/vohive-start.log 2>&1 || true
			fail "替换后服务未能保持运行，已恢复原核心"
		fi
		if [ "$mode" = "upload" ]; then
			sleep 3
			api_port="$(uci_get port '7575')"
			api_token="$(curl -s --connect-timeout 3 http://127.0.0.1:$api_port/api/auth/login \
				-X POST -H 'Content-Type: application/json' \
				-d '{"username":"'"$(uci_get username 'admin')"'","password":"'"$(uci_get password 'admin')"'"}' \
				2>/dev/null | jsonfilter -e '@.token' 2>/dev/null || true)"
			if [ -n "$api_token" ]; then
				api_version="$(curl -s --connect-timeout 3 http://127.0.0.1:$api_port/api/system/info \
					-H "Authorization: Bearer $api_token" \
					2>/dev/null | jsonfilter -e '@.version' 2>/dev/null || true)"
				[ -n "$api_version" ] && printf '%s\n' "$api_version" > "$dir/version"
			fi
		fi
	fi

	rm -f "$dir/vohive.bak"
	finish_ok "核心已替换"
}

task_mkdirs
task_log "$id" "任务启动"

case "$type" in
	install_core) install_core "$@" ;;
	upload_core) upload_core ;;
	update_plugin) update_plugin ;;
	instance_add) instance_add "$@" ;;
	instance_replace) instance_replace "$@" ;;
	*) fail "不支持的任务类型: $type" ;;
esac
