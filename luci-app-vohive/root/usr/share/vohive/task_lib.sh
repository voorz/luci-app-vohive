#!/bin/sh

. /usr/share/vohive/lib.sh

TASK_DIR="/tmp/vohive/tasks"
DOWNLOAD_DIR="/tmp/vohive/download"
CURRENT_TASK="$TASK_DIR/current"

task_mkdirs() {
	mkdir -p "$TASK_DIR" "$DOWNLOAD_DIR"
}

task_status_file() {
	printf '%s/%s.json' "$TASK_DIR" "$1"
}

task_log_file() {
	printf '%s/%s.log' "$TASK_DIR" "$1"
}

task_cancel_file() {
	printf '%s/%s.cancel' "$TASK_DIR" "$1"
}

task_pid_file() {
	printf '%s/%s.pid' "$TASK_DIR" "$1"
}

task_now() {
	date +%s
}

task_log() {
	local id="$1"
	local message="$2"

	task_mkdirs
	printf '%s %s\n' "$(date '+%H:%M:%S')" "$message" >> "$(task_log_file "$id")"
}

task_log_json() {
	local log_file="$1"
	local first=1 line

	printf '['
	if [ -f "$log_file" ]; then
		tail -n 20 "$log_file" | while IFS= read -r line; do
			if [ "$first" = 1 ]; then
				first=0
			else
				printf ','
			fi
			printf '"%s"' "$(json_escape "$line")"
		done
	fi
	printf ']'
}

task_write_status() {
	local id="$1"
	local type="$2"
	local state="$3"
	local stage="$4"
	local message="$5"
	local file="${6:-}"
	local downloaded="${7:-0}"
	local total="${8:-0}"
	local speed="${9:-0}"
	local cancellable="${10:-0}"
	local ok="${11:-}"
	local result_message="${12:-}"
	local percent=0
	local tmp log_file status_file prev_file prev_downloaded prev_total prev_speed

	task_mkdirs
	downloaded="${downloaded:-0}"
	total="${total:-0}"
	speed="${speed:-0}"
	status_file="$(task_status_file "$id")"
	if [ -f "$status_file" ] && [ "${speed:-0}" = 0 ]; then
		prev_file="$(jsonfilter -i "$status_file" -e '@.file' 2>/dev/null || true)"
		prev_speed="$(jsonfilter -i "$status_file" -e '@.speed_bps' 2>/dev/null || true)"
		if [ "${prev_speed:-0}" -gt 0 ] 2>/dev/null && { [ "$stage" != "download" ] || [ -n "$file" ] && [ "$file" = "$prev_file" ]; }; then
			speed="$prev_speed"
		fi
	fi
	if [ -f "$status_file" ] && [ -z "$file" ] && [ "${downloaded:-0}" = 0 ] && [ "${total:-0}" = 0 ]; then
		prev_file="$(jsonfilter -i "$status_file" -e '@.file' 2>/dev/null || true)"
		prev_downloaded="$(jsonfilter -i "$status_file" -e '@.downloaded' 2>/dev/null || true)"
		prev_total="$(jsonfilter -i "$status_file" -e '@.total' 2>/dev/null || true)"
		prev_speed="$(jsonfilter -i "$status_file" -e '@.speed_bps' 2>/dev/null || true)"
		if [ "${prev_total:-0}" -gt 0 ] 2>/dev/null || [ "${prev_downloaded:-0}" -gt 0 ] 2>/dev/null; then
			file="$prev_file"
			downloaded="${prev_downloaded:-0}"
			total="${prev_total:-0}"
			speed="${prev_speed:-0}"
		fi
	fi
	if [ "$total" -gt 0 ] 2>/dev/null; then
		percent=$((downloaded * 100 / total))
		[ "$percent" -gt 100 ] && percent=100
	fi

	log_file="$(task_log_file "$id")"
	tmp="${status_file}.tmp"
	{
		printf '{'
		printf '"ok":true,'
		printf '"id":"%s",' "$(json_escape "$id")"
		printf '"type":"%s",' "$(json_escape "$type")"
		printf '"state":"%s",' "$(json_escape "$state")"
		printf '"stage":"%s",' "$(json_escape "$stage")"
		printf '"message":"%s",' "$(json_escape "$message")"
		printf '"file":"%s",' "$(json_escape "$file")"
		printf '"downloaded":%s,' "$downloaded"
		printf '"total":%s,' "$total"
		printf '"speed_bps":%s,' "$speed"
		printf '"percent":%s,' "$percent"
		printf '"cancellable":%s,' "$([ "$cancellable" = 1 ] && printf true || printf false)"
		if [ -n "$ok" ]; then
			printf '"result":{"ok":%s,"message":"%s"},' "$([ "$ok" = 1 ] && printf true || printf false)" "$(json_escape "$result_message")"
		else
			printf '"result":null,'
		fi
		printf '"updated_at":%s,' "$(task_now)"
		printf '"log":'
		task_log_json "$log_file"
		printf '}'
	} > "$tmp"
	mv -f "$tmp" "$status_file"
}

task_finish() {
	local id="$1"
	local type="$2"
	local ok="$3"
	local message="$4"
	local state="failed"
	local status_file file downloaded total speed

	[ "$ok" = 1 ] && state="completed"
	task_log "$id" "$message"

	status_file="$(task_status_file "$id")"
	file="$(jsonfilter -i "$status_file" -e '@.file' 2>/dev/null || true)"
	downloaded="$(jsonfilter -i "$status_file" -e '@.downloaded' 2>/dev/null || true)"
	total="$(jsonfilter -i "$status_file" -e '@.total' 2>/dev/null || true)"
	speed="$(jsonfilter -i "$status_file" -e '@.speed_bps' 2>/dev/null || true)"
	task_write_status "$id" "$type" "$state" "$state" "$message" "$file" "${downloaded:-0}" "${total:-0}" "${speed:-0}" 0 "$ok" "$message"
}

task_fail() {
	task_finish "$1" "$2" 0 "$3"
	exit 1
}

task_cancelled() {
	local id="$1"
	local type="$2"
	local message="${3:-已取消下载}"

	task_log "$id" "$message"
	task_write_status "$id" "$type" "canceled" "canceled" "$message" "" 0 0 0 0 0 "$message"
	exit 2
}

task_cleanup_old() {
	task_mkdirs
	find "$TASK_DIR" -type f \( -name '*.json' -o -name '*.log' -o -name '*.cancel' -o -name '*.pid' \) -mmin +30 -exec rm -f {} \; 2>/dev/null || true
	ls -1t "$TASK_DIR"/*.json 2>/dev/null | awk 'NR>10 {print}' | while IFS= read -r old; do
		base="${old##*/}"
		id="${base%.json}"
		rm -f "$TASK_DIR/$id.json" "$TASK_DIR/$id.log" "$TASK_DIR/$id.cancel" "$TASK_DIR/$id.pid"
	done
}

task_asset_size() {
	local json="$1"
	local asset="$2"
	local i=0 name size

	while :; do
		name="$(printf '%s' "$json" | jsonfilter -e "@.assets[$i].name" 2>/dev/null || true)"
		[ -n "$name" ] || break
		if [ "$name" = "$asset" ]; then
			size="$(printf '%s' "$json" | jsonfilter -e "@.assets[$i].size" 2>/dev/null || true)"
			printf '%s' "${size:-0}"
			return 0
		fi
		i=$((i + 1))
	done
	printf '0'
}

task_file_size() {
	local file="$1"

	if [ -f "$file" ]; then
		wc -c < "$file" 2>/dev/null || echo 0
	else
		echo 0
	fi
}

task_download() {
	local id="$1"
	local type="$2"
	local url="$3"
	local dest="$4"
	local label="$5"
	local total="${6:-0}"
	local part="${dest}.part"
	local curl_log="$TASK_DIR/$id.curl"
	local started last_time now last_size size speed curl_pid exit_code

	rm -f "$part" "$curl_log"
	task_log "$id" "开始下载 $label"
	started="$(task_now)"
	last_time="$started"
	last_size=0
	task_write_status "$id" "$type" "running" "download" "正在下载 $label" "$label" 0 "$total" 0 1

	curl -fL --show-error --connect-timeout 20 --retry 2 "$url" -o "$part" 2>"$curl_log" &
	curl_pid="$!"

	while kill -0 "$curl_pid" 2>/dev/null; do
		if [ -f "$(task_cancel_file "$id")" ]; then
			kill "$curl_pid" 2>/dev/null || true
			wait "$curl_pid" 2>/dev/null || true
			rm -f "$part"
			task_cancelled "$id" "$type"
		fi

		size="$(task_file_size "$part")"
		now="$(task_now)"
		speed=0
		if [ "$now" -gt "$last_time" ] 2>/dev/null; then
			speed=$(((size - last_size) / (now - last_time)))
			[ "$speed" -lt 0 ] && speed=0
		fi
		task_write_status "$id" "$type" "running" "download" "正在下载 $label" "$label" "$size" "$total" "$speed" 1
		last_time="$now"
		last_size="$size"
		sleep 1
	done

	if wait "$curl_pid"; then
		exit_code=0
	else
		exit_code="$?"
	fi
	size="$(task_file_size "$part")"
	now="$(task_now)"
	if [ "${speed:-0}" = 0 ] && [ "$now" -gt "$started" ] 2>/dev/null; then
		speed=$((size / (now - started)))
	fi
	task_write_status "$id" "$type" "running" "download" "正在下载 $label" "$label" "$size" "$total" "$speed" 1

	if [ "$exit_code" -ne 0 ]; then
		rm -f "$part"
		task_log "$id" "$(tail -n 1 "$curl_log" 2>/dev/null || true)"
		task_fail "$id" "$type" "下载失败: $label"
	fi

	mv -f "$part" "$dest"
	rm -f "$curl_log"
	task_log "$id" "下载完成 $label"
}
