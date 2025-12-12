#!/usr/bin/env bash
# Prompt discovery and rendering.

set -euo pipefail

MCP_PROMPTS_REGISTRY_JSON=""
MCP_PROMPTS_REGISTRY_HASH=""
MCP_PROMPTS_REGISTRY_PATH=""
# shellcheck disable=SC2034
MCP_PROMPTS_TOTAL=0
# Internal error handoff between library and handler (not user-configurable).
# shellcheck disable=SC2034
_MCP_PROMPTS_ERR_CODE=0
# shellcheck disable=SC2034
_MCP_PROMPTS_ERR_MESSAGE=""
# shellcheck disable=SC2034
_MCP_PROMPTS_RESULT=""
MCP_PROMPTS_TTL="${MCP_PROMPTS_TTL:-5}"
MCP_PROMPTS_LAST_SCAN=0
MCP_PROMPTS_LAST_NOTIFIED_HASH=""
MCP_PROMPTS_CHANGED=false
MCP_PROMPTS_LOGGER="${MCP_PROMPTS_LOGGER:-mcp.prompts}"
MCP_PROMPTS_MANUAL_ACTIVE=false
MCP_PROMPTS_MANUAL_BUFFER=""
MCP_PROMPTS_MANUAL_DELIM=$'\036'

if ! command -v mcp_registry_resolve_scan_root >/dev/null 2>&1; then
	# shellcheck disable=SC1090
	. "${MCPBASH_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/registry.sh"
fi

mcp_prompts_scan_root() {
	mcp_registry_resolve_scan_root "${MCPBASH_PROMPTS_DIR}"
}

mcp_prompts_manual_begin() {
	MCP_PROMPTS_MANUAL_ACTIVE=true
	MCP_PROMPTS_MANUAL_BUFFER=""
}

mcp_prompts_manual_abort() {
	MCP_PROMPTS_MANUAL_ACTIVE=false
	MCP_PROMPTS_MANUAL_BUFFER=""
}

mcp_prompts_register_manual() {
	local payload="$1"
	if [ "${MCP_PROMPTS_MANUAL_ACTIVE}" != "true" ]; then
		return 0
	fi
	if [ -z "${payload}" ]; then
		return 0
	fi
	if [ -n "${MCP_PROMPTS_MANUAL_BUFFER}" ]; then
		MCP_PROMPTS_MANUAL_BUFFER="${MCP_PROMPTS_MANUAL_BUFFER}${MCP_PROMPTS_MANUAL_DELIM}${payload}"
	else
		MCP_PROMPTS_MANUAL_BUFFER="${payload}"
	fi
	return 0
}

mcp_prompts_hash_string() {
	local value="$1"
	mcp_hash_string "${value}"
}

mcp_prompts_manual_finalize() {
	if [ "${MCP_PROMPTS_MANUAL_ACTIVE}" != "true" ]; then
		return 0
	fi

	local manual_entries
	if [ -n "${MCP_PROMPTS_MANUAL_BUFFER}" ]; then
		manual_entries="$(printf '%s' "${MCP_PROMPTS_MANUAL_BUFFER}" | tr "${MCP_PROMPTS_MANUAL_DELIM}" '\n')"
	else
		manual_entries=""
	fi

	local items_json
	if ! items_json="$(printf '%s' "${manual_entries}" | "${MCPBASH_JSON_TOOL_BIN}" -s '
		map(select(.name and .path)) |
		unique_by(.name) |
		map({
			name: .name,
			description: (.description // ""),
			path: .path,
			arguments: (.arguments // {type: "object", properties: {}}),
			role: (.role // null),
			metadata: (.metadata // null),
			icons: (.icons // null)
		}) |
		map(if .icons == null then del(.icons) else . end) |
		sort_by(.name)
	')"; then
		mcp_prompts_manual_abort
		mcp_prompts_error -32603 "Manual registration parsing failed"
		return 1
	fi

	local hash
	hash="$(mcp_prompts_hash_string "${items_json}")"
	local total
	total="$(printf '%s' "${items_json}" | "${MCPBASH_JSON_TOOL_BIN}" 'length')"

	MCP_PROMPTS_REGISTRY_JSON="$("${MCPBASH_JSON_TOOL_BIN}" -n \
		--arg hash "${hash}" \
		--argjson items "${items_json}" \
		--argjson total "${total}" \
		'{
			version: 1,
			generatedAt: (now | todate),
			items: $items,
			total: $total,
			hash: $hash
		}
	')"

	local previous_hash="${MCP_PROMPTS_REGISTRY_HASH}"
	MCP_PROMPTS_REGISTRY_HASH="${hash}"
	MCP_PROMPTS_TOTAL="${total}"

	if ! mcp_prompts_enforce_registry_limits "${MCP_PROMPTS_TOTAL}" "${MCP_PROMPTS_REGISTRY_JSON}"; then
		mcp_prompts_manual_abort
		return 1
	fi

	MCP_PROMPTS_LAST_SCAN="$(date +%s)"
	local write_rc=0
	mcp_registry_write_with_lock "${MCP_PROMPTS_REGISTRY_PATH}" "${MCP_PROMPTS_REGISTRY_JSON}" || write_rc=$?
	if [ "${write_rc}" -ne 0 ]; then
		return "${write_rc}"
	fi
	MCP_PROMPTS_MANUAL_ACTIVE=false
	MCP_PROMPTS_MANUAL_BUFFER=""
	return 0
}

mcp_prompts_enforce_registry_limits() {
	local total="$1"
	local json_payload="$2"
	local limit_or_size

	if ! limit_or_size="$(mcp_registry_check_size "${json_payload}")"; then
		_MCP_PROMPTS_ERR_CODE=-32603
		_MCP_PROMPTS_ERR_MESSAGE="Prompts registry exceeds ${limit_or_size} byte cap"
		return 1
	fi
	if [ "${total}" -gt 500 ]; then
		mcp_logging_warning "${MCP_PROMPTS_LOGGER}" "Prompts registry contains ${total} entries; consider manual registration"
	fi
	return 0
}

mcp_prompts_error() {
	_MCP_PROMPTS_ERR_CODE="$1"
	_MCP_PROMPTS_ERR_MESSAGE="$2"
}

mcp_prompts_init() {
	if [ -z "${MCP_PROMPTS_REGISTRY_PATH}" ]; then
		MCP_PROMPTS_REGISTRY_PATH="${MCPBASH_REGISTRY_DIR}/prompts.json"
	fi
	mkdir -p "${MCPBASH_REGISTRY_DIR}"
	mkdir -p "${MCPBASH_PROMPTS_DIR}" >/dev/null 2>&1 || true
}

mcp_prompts_apply_manual_json() {
	local manual_json="$1"
	local items_json
	if ! items_json="$(printf '%s' "${manual_json}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.prompts // []')"; then
		return 1
	fi

	local hash
	hash="$(mcp_prompts_hash_string "${items_json}")"
	local total
	total="$(printf '%s' "${items_json}" | "${MCPBASH_JSON_TOOL_BIN}" 'length')"

	local registry_json
	registry_json="$("${MCPBASH_JSON_TOOL_BIN}" -n \
		--arg hash "${hash}" \
		--argjson items "${items_json}" \
		--argjson total "${total}" \
		'{
			version: 1,
			generatedAt: (now | todate),
			items: $items,
			total: $total,
			hash: $hash
		}
	')"

	if ! mcp_prompts_enforce_registry_limits "${total}" "${registry_json}"; then
		return 1
	fi

	local previous_hash="${MCP_PROMPTS_REGISTRY_HASH}"
	MCP_PROMPTS_REGISTRY_JSON="${registry_json}"
	MCP_PROMPTS_REGISTRY_HASH="${hash}"
	MCP_PROMPTS_TOTAL="${total}"

	if mcp_logging_is_enabled "debug"; then
		mcp_logging_debug "${MCP_PROMPTS_LOGGER}" "Refresh count=${MCP_PROMPTS_TOTAL} hash=${MCP_PROMPTS_REGISTRY_HASH}"
	fi

	MCP_PROMPTS_LAST_SCAN="$(date +%s)"
	local write_rc=0
	mcp_registry_write_with_lock "${MCP_PROMPTS_REGISTRY_PATH}" "${registry_json}" || write_rc=$?
	if [ "${write_rc}" -ne 0 ]; then
		return "${write_rc}"
	fi
}

mcp_prompts_refresh_registry() {
	local scan_root
	scan_root="$(mcp_prompts_scan_root)"
	mcp_prompts_init
	local manual_status=0
	mcp_registry_register_apply "prompts"
	manual_status=$?
	if [ "${manual_status}" -eq 2 ]; then
		local err
		err="$(mcp_registry_register_error_for_kind "prompts")"
		if [ -z "${err}" ]; then
			err="Manual registration script returned empty output or non-zero"
		fi
		mcp_logging_error "${MCP_PROMPTS_LOGGER}" "${err}"
		return 1
	fi
	if [ "${manual_status}" -eq 0 ] && [ "${MCP_REGISTRY_REGISTER_LAST_APPLIED:-false}" = "true" ]; then
		return 0
	fi
	local now
	now="$(date +%s)"

	if [ -z "${MCP_PROMPTS_REGISTRY_JSON}" ] && [ -f "${MCP_PROMPTS_REGISTRY_PATH}" ]; then
		local tmp_json=""
		if tmp_json="$(cat "${MCP_PROMPTS_REGISTRY_PATH}")"; then
			if printf '%s' "${tmp_json}" | "${MCPBASH_JSON_TOOL_BIN}" . >/dev/null 2>&1; then
				MCP_PROMPTS_REGISTRY_JSON="${tmp_json}"
				MCP_PROMPTS_REGISTRY_HASH="$(printf '%s' "${MCP_PROMPTS_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.hash // empty')"
				MCP_PROMPTS_TOTAL="$(printf '%s' "${MCP_PROMPTS_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" '.total // 0')"
				if ! mcp_prompts_enforce_registry_limits "${MCP_PROMPTS_TOTAL}" "${MCP_PROMPTS_REGISTRY_JSON}"; then
					return 1
				fi
			else
				mcp_logging_warning "${MCP_PROMPTS_LOGGER}" "Discarding invalid prompt registry cache"
				MCP_PROMPTS_REGISTRY_JSON=""
			fi
		else
			if mcp_logging_verbose_enabled; then
				mcp_logging_warning "${MCP_PROMPTS_LOGGER}" "Failed to read prompt registry cache ${MCP_PROMPTS_REGISTRY_PATH}"
			else
				mcp_logging_warning "${MCP_PROMPTS_LOGGER}" "Failed to read prompt registry cache"
			fi
			MCP_PROMPTS_REGISTRY_JSON=""
		fi
	fi
	if [ -n "${MCP_PROMPTS_REGISTRY_JSON}" ] && [ $((now - MCP_PROMPTS_LAST_SCAN)) -lt "${MCP_PROMPTS_TTL}" ]; then
		return 0
	fi

	local fastpath_snapshot
	fastpath_snapshot="$(mcp_registry_fastpath_snapshot "${scan_root}")"
	if mcp_registry_fastpath_unchanged "prompts" "${fastpath_snapshot}"; then
		MCP_PROMPTS_LAST_SCAN="${now}"
		# Sync in-memory state from cache if another process refreshed the registry
		if [ -f "${MCP_PROMPTS_REGISTRY_PATH}" ]; then
			local cached_hash
			cached_hash="$("${MCPBASH_JSON_TOOL_BIN}" -r '.hash // empty' "${MCP_PROMPTS_REGISTRY_PATH}" 2>/dev/null || true)"
			if [ -n "${cached_hash}" ] && [ "${cached_hash}" != "${MCP_PROMPTS_REGISTRY_HASH}" ]; then
				local cached_json cached_total
				cached_json="$(cat "${MCP_PROMPTS_REGISTRY_PATH}" 2>/dev/null || true)"
				cached_total="$("${MCPBASH_JSON_TOOL_BIN}" '.total // 0' "${MCP_PROMPTS_REGISTRY_PATH}" 2>/dev/null || printf '0')"
				MCP_PROMPTS_REGISTRY_JSON="${cached_json}"
				MCP_PROMPTS_REGISTRY_HASH="${cached_hash}"
				MCP_PROMPTS_TOTAL="${cached_total}"
				MCP_PROMPTS_CHANGED=true
			fi
		fi
		return 0
	fi

	# Capture previous hash from cache file if in-memory state is empty (parent may not have run scan yet)
	local previous_hash="${MCP_PROMPTS_REGISTRY_HASH}"
	if [ -z "${previous_hash}" ] && [ -f "${MCP_PROMPTS_REGISTRY_PATH}" ]; then
		previous_hash="$("${MCPBASH_JSON_TOOL_BIN}" -r '.hash // empty' "${MCP_PROMPTS_REGISTRY_PATH}" 2>/dev/null || true)"
	fi
	mcp_prompts_scan "${scan_root}" || return 1
	MCP_PROMPTS_LAST_SCAN="${now}"
	# Recompute fastpath snapshot post-scan to capture content-only changes
	fastpath_snapshot="$(mcp_registry_fastpath_snapshot "${scan_root}")"
	mcp_registry_fastpath_store "prompts" "${fastpath_snapshot}" || true
	# Incorporate fastpath snapshot into registry hash so content changes trigger notifications
	if [ -n "${MCP_PROMPTS_REGISTRY_HASH}" ] && [ -n "${fastpath_snapshot}" ]; then
		local combined_hash
		combined_hash="$(mcp_hash_string "${MCP_PROMPTS_REGISTRY_HASH}|${fastpath_snapshot}")"
		MCP_PROMPTS_REGISTRY_HASH="${combined_hash}"
		MCP_PROMPTS_REGISTRY_JSON="$(printf '%s' "${MCP_PROMPTS_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" --arg hash "${combined_hash}" '.hash = $hash')"
		local write_rc=0
		mcp_registry_write_with_lock "${MCP_PROMPTS_REGISTRY_PATH}" "${MCP_PROMPTS_REGISTRY_JSON}" || write_rc=$?
		if [ "${write_rc}" -ne 0 ]; then
			return "${write_rc}"
		fi
	fi
	if [ "${previous_hash}" != "${MCP_PROMPTS_REGISTRY_HASH}" ]; then
		MCP_PROMPTS_CHANGED=true
	fi
}

mcp_prompts_scan() {
	local prompts_dir="${1:-${MCPBASH_PROMPTS_DIR}}"
	local items_file
	items_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-prompts-items.XXXXXX")"

	if [ -d "${prompts_dir}" ]; then
		find "${prompts_dir}" -type f ! -name ".*" ! -name "*.meta.json" 2>/dev/null | sort | while read -r path; do
			local rel_path="${path#"${MCPBASH_PROMPTS_DIR}"/}"
			local base_name
			base_name="$(basename "${path}")"
			local name="${base_name%.*}"
			local dir_name
			dir_name="$(dirname "${path}")"
			local meta_json="${dir_name}/${base_name}.meta.json"
			if [ ! -f "${meta_json}" ]; then
				local stem="${base_name%.*}"
				if [ -n "${stem}" ] && [ "${stem}" != "${base_name}" ]; then
					local alt_meta="${dir_name}/${stem}.meta.json"
					if [ -f "${alt_meta}" ]; then
						meta_json="${alt_meta}"
					fi
				fi
			fi
			local description=""
			local role="user"
			local arguments='{"type": "object", "properties": {}}'
			local metadata="null"
			local icons="null"

			if [ -f "${meta_json}" ]; then
				local meta
				# Strip \r to handle CRLF line endings from Windows checkouts
				meta="$(tr -d '\r' <"${meta_json}")"
				local j_name
				j_name="$(printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.name // empty' 2>/dev/null)"
				[ -n "${j_name}" ] && name="${j_name}"
				description="$(printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.description // empty' 2>/dev/null)"
				role="$(printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.role // "user"' 2>/dev/null)"
				if printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -e '.arguments' >/dev/null 2>&1; then
					arguments="$(printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.arguments')"
				fi
				if printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -e '.metadata' >/dev/null 2>&1; then
					metadata="$(printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.metadata')"
				fi
				icons="$(printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.icons // null' 2>/dev/null || printf 'null')"
				# Convert local file paths to data URIs
				local meta_dir
				meta_dir="$(dirname "${meta_json}")"
				icons="$(mcp_json_icons_to_data_uris "${icons}" "${meta_dir}")"
			fi

			# Ensure all --argjson values are valid JSON (fallback to safe defaults)
			[ -z "${arguments}" ] && arguments='{"type":"object","properties":{}}'
			[ -z "${metadata}" ] && metadata='null'
			[ -z "${icons}" ] && icons='null'

			"${MCPBASH_JSON_TOOL_BIN}" -n \
				--arg name "$name" \
				--arg desc "$description" \
				--arg path "$rel_path" \
				--arg role "$role" \
				--argjson args "$arguments" \
				--argjson meta "$metadata" \
				--argjson icons "$icons" \
				'{
					name: $name,
					description: $desc,
					path: $path,
					arguments: $args,
					role: $role,
					metadata: $meta
				}
				+ (if $icons != null then {icons: $icons} else {} end)' >>"${items_file}"
		done
	fi

	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	local items_json="[]"
	if [ -s "${items_file}" ]; then
		local parsed
		if parsed="$("${MCPBASH_JSON_TOOL_BIN}" -s 'sort_by(.name)' "${items_file}" 2>/dev/null)"; then
			items_json="${parsed}"
		fi
	fi
	rm -f "${items_file}"

	local hash
	hash="$(mcp_prompts_hash_string "${items_json}")"
	local total
	total="$(printf '%s' "${items_json}" | "${MCPBASH_JSON_TOOL_BIN}" 'length' 2>/dev/null)" || total=0
	# Ensure total is a valid number
	case "${total}" in
	'' | *[!0-9]*) total=0 ;;
	esac

	MCP_PROMPTS_REGISTRY_JSON="$("${MCPBASH_JSON_TOOL_BIN}" -n \
		--arg ver "1" \
		--arg ts "${timestamp}" \
		--arg hash "${hash}" \
		--argjson items "${items_json}" \
		--argjson total "${total}" \
		'{version: $ver|tonumber, generatedAt: $ts, items: $items, hash: $hash, total: $total}')"

	MCP_PROMPTS_REGISTRY_HASH="${hash}"
	MCP_PROMPTS_TOTAL="${total}"

	if ! mcp_prompts_enforce_registry_limits "${MCP_PROMPTS_TOTAL}" "${MCP_PROMPTS_REGISTRY_JSON}"; then
		return 1
	fi

	local write_rc=0
	mcp_registry_write_with_lock "${MCP_PROMPTS_REGISTRY_PATH}" "${MCP_PROMPTS_REGISTRY_JSON}" || write_rc=$?
	if [ "${write_rc}" -ne 0 ]; then
		return "${write_rc}"
	fi
}

mcp_prompts_decode_cursor() {
	local cursor="$1"
	local hash="$2"
	local offset
	if ! offset="$(mcp_paginate_decode "${cursor}" "prompts" "${hash}")"; then
		return 1
	fi
	printf '%s' "${offset}"
}

mcp_prompts_list() {
	local limit="$1"
	local cursor="$2"
	# shellcheck disable=SC2034
	_MCP_PROMPTS_ERR_CODE=0
	# shellcheck disable=SC2034
	_MCP_PROMPTS_ERR_MESSAGE=""

	mcp_prompts_refresh_registry || {
		mcp_prompts_error -32603 "Unable to load prompts registry"
		return 1
	}

	local numeric_limit
	if [ -z "${limit}" ]; then
		numeric_limit=50
	else
		case "${limit}" in
		'' | *[!0-9]*) numeric_limit=50 ;;
		0) numeric_limit=50 ;;
		*) numeric_limit="${limit}" ;;
		esac
	fi
	if [ "${numeric_limit}" -gt 200 ]; then
		numeric_limit=200
	fi

	local offset=0
	if [ -n "${cursor}" ]; then
		if ! offset="$(mcp_prompts_decode_cursor "${cursor}" "${MCP_PROMPTS_REGISTRY_HASH}")"; then
			mcp_prompts_error -32602 "Invalid cursor"
			return 1
		fi
	fi

	local total="${MCP_PROMPTS_TOTAL}"
	local result_json
	# ListPromptsResult is paginated; expose total via result._meta["mcpbash/total"] for
	# strict-client compatibility (instead of a top-level field).
	result_json="$(printf '%s' "${MCP_PROMPTS_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -c --argjson offset "$offset" --argjson limit "$numeric_limit" --argjson total "${total}" '
		{
			prompts: .items[$offset:$offset+$limit],
			_meta: {"mcpbash/total": $total}
		}
	')"

	if ! result_json="$(mcp_paginate_attach_next_cursor "${result_json}" "prompts" "${offset}" "${numeric_limit}" "${total}" "${MCP_PROMPTS_REGISTRY_HASH}")"; then
		mcp_prompts_error -32603 "Unable to encode prompts cursor"
		return 1
	fi

	printf '%s' "${result_json}"
}

mcp_prompts_metadata_for_name() {
	local name="$1"
	mcp_prompts_refresh_registry || return 1
	local metadata
	if ! metadata="$(printf '%s' "${MCP_PROMPTS_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -c --arg name "${name}" '.items[] | select(.name == $name)' | head -n 1)"; then
		return 1
	fi
	[ -z "${metadata}" ] && return 1
	printf '%s' "${metadata}"
}

mcp_prompts_render() {
	local metadata="$1"
	local args_json="$2"
	# shellcheck disable=SC2034
	_MCP_PROMPTS_RESULT=""
	local path description role metadata_value
	path="$(printf '%s' "${metadata}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.path // empty')"
	description="$(printf '%s' "${metadata}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.description // ""')"
	role="$(printf '%s' "${metadata}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.role // "system"')"
	metadata_value="$(printf '%s' "${metadata}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.metadata // null')"

	if [ -z "${path}" ]; then
		mcp_prompts_emit_render_result "" "${args_json}" "${role}" "${description}" "${metadata_value}"
		return 0
	fi

	local full_path="${MCPBASH_PROMPTS_DIR}/${path}"
	if [ ! -f "${full_path}" ]; then
		mcp_prompts_emit_render_result "" "${args_json}" "${role}" "${description}" "${metadata_value}"
		return 0
	fi

	local normalized_args="${args_json}"
	if [ -z "${normalized_args}" ] || ! printf '%s' "${normalized_args}" | "${MCPBASH_JSON_TOOL_BIN}" empty >/dev/null 2>&1; then
		normalized_args="{}"
	fi

	local export_pairs=""
	if ! export_pairs="$(
		printf '%s' "${normalized_args}" | "${MCPBASH_JSON_TOOL_BIN}" -r '
			def allowed($key; $val):
				($key | test("^[A-Za-z_][A-Za-z0-9_]*$"))
				and ((["string","number","boolean"] | index($val|type)) != null);
			def value_string($val):
				if ($val | type) == "boolean" then
					(if $val then "true" else "false" end)
				elif ($val | type) == "number" then
					($val | tostring)
				else
					($val | tostring)
				end;
			if type == "object" then
				to_entries
				| map(select(allowed(.key; .value)))
				| .[]
				| [ .key, value_string(.value) ]
				| @tsv
			else
				empty
			end
		'
	)"; then
		export_pairs=""
	fi

	local env_cmd=("env" "-i" "PATH=${PATH}")
	while IFS=$'\t' read -r export_key export_value; do
		[ -z "${export_key}" ] && continue
		case "${export_value}" in
		*$'\n'*)
			continue
			;;
		esac
		env_cmd+=("${export_key}=${export_value}")
	done <<<"${export_pairs}"

	local text
	if ! text="$("${env_cmd[@]}" envsubst <"${full_path}")"; then
		return 1
	fi

	mcp_prompts_emit_render_result "${text}" "${normalized_args}" "${role}" "${description}" "${metadata_value}"
}

mcp_prompts_emit_render_result() {
	local text="$1"
	local args_json="$2"
	local role="$3"
	local description="$4"
	local metadata_value="$5"

	local normalized_args="${args_json}"
	if [ -z "${normalized_args}" ] || ! printf '%s' "${normalized_args}" | "${MCPBASH_JSON_TOOL_BIN}" empty >/dev/null 2>&1; then
		normalized_args="{}"
	fi
	local normalized_meta="${metadata_value:-null}"
	if [ -z "${normalized_meta}" ]; then
		normalized_meta="null"
	fi

	_MCP_PROMPTS_RESULT="$("${MCPBASH_JSON_TOOL_BIN}" -n -c \
		--arg text "${text}" \
		--arg role "${role}" \
		--arg desc "${description}" \
		--argjson args "${normalized_args}" \
		--argjson meta "${normalized_meta}" \
		'{
			text: $text,
			arguments: $args,
			messages: [
				{
					role: $role,
					content: [{type: "text", text: $text}]
				}
			]
		}
		+ (if ($desc | length) > 0 then {description: $desc} else {} end)
		+ (if $meta != null then {metadata: $meta} else {} end)')"
}

mcp_prompts_poll() {
	if mcp_runtime_is_minimal_mode; then
		return 0
	fi
	local ttl="${MCP_PROMPTS_TTL:-5}"
	case "${ttl}" in
	'' | *[!0-9]*) ttl=5 ;;
	esac
	local now
	now="$(date +%s)"
	if [ "${MCP_PROMPTS_LAST_SCAN}" -eq 0 ] || [ $((now - MCP_PROMPTS_LAST_SCAN)) -ge "${ttl}" ]; then
		mcp_prompts_refresh_registry || true
	fi
	return 0
}

mcp_prompts_consume_notification() {
	local actually_emit="${1:-true}"
	local current_hash="${MCP_PROMPTS_REGISTRY_HASH}"
	_MCP_NOTIFICATION_PAYLOAD=""

	if [ -z "${current_hash}" ]; then
		return 0
	fi

	if [ "${MCP_PROMPTS_CHANGED}" != "true" ]; then
		return 0
	fi

	if [ "${actually_emit}" = "true" ]; then
		# shellcheck disable=SC2034  # stored for next consume call
		MCP_PROMPTS_LAST_NOTIFIED_HASH="${current_hash}"
		MCP_PROMPTS_CHANGED=false
		_MCP_NOTIFICATION_PAYLOAD='{"jsonrpc":"2.0","method":"notifications/prompts/list_changed","params":{}}'
	fi
}
