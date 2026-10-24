#!/bin/sh

# List all core instances as JSON. Read-only; triggers lazy migration
# of a legacy single-core install into the "default" instance.

. /usr/share/vohive/lib.sh

active="$(active_instance_id)"

printf '{'
printf '"active":"%s",' "$(json_escape "$active")"
printf '"instances":['

first=1
if [ -d "$INSTANCES_DIR" ]; then
	for dir in "$INSTANCES_DIR"/*; do
		[ -d "$dir" ] || continue
		[ -x "$dir/vohive" ] || continue
		id="${dir##*/}"
		name="$(instance_meta_get "$id" name 2>/dev/null || true)"
		source="$(instance_meta_get "$id" source 2>/dev/null || true)"
		version="$(cat "$dir/version" 2>/dev/null || true)"
		created="$(instance_meta_get "$id" created 2>/dev/null || true)"
		size="$(wc -c < "$dir/vohive" 2>/dev/null || echo 0)"
		is_active=0
		[ "$id" = "$active" ] && is_active=1
		[ "$first" = "1" ] || printf ','
		first=0
		printf '{'
		printf '"id":"%s",' "$(json_escape "$id")"
		printf '"name":"%s",' "$(json_escape "${name:-$id}")"
		printf '"source":"%s",' "$(json_escape "${source:-local}")"
		printf '"version":"%s",' "$(json_escape "${version:---}")"
		printf '"created":"%s",' "$(json_escape "${created:-}")"
		printf '"size":%s,' "${size:-0}"
		printf '"active":%s' "$is_active"
		printf '}'
	done
fi

printf ']}\n'
