#!/usr/bin/env bash
# Prompt discovery and rendering.

set -euo pipefail

MCP_PROMPTS_REGISTRY_JSON=""
MCP_PROMPTS_REGISTRY_HASH=""
MCP_PROMPTS_REGISTRY_PATH=""
# shellcheck disable=SC2034
MCP_PROMPTS_TOTAL=0
# shellcheck disable=SC2034
MCP_PROMPTS_ERR_CODE=0
# shellcheck disable=SC2034
MCP_PROMPTS_ERR_MESSAGE=""
MCP_PROMPTS_TTL="${MCP_PROMPTS_TTL:-5}"
MCP_PROMPTS_LAST_SCAN=0
MCP_PROMPTS_CHANGED=false
MCP_PROMPTS_LOGGER="${MCP_PROMPTS_LOGGER:-mcp.prompts}"
MCP_PROMPTS_MANUAL_ACTIVE=false
MCP_PROMPTS_MANUAL_BUFFER=""
MCP_PROMPTS_MANUAL_DELIM=$'\036'

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
	if command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "${value}" | sha256sum | awk '{print $1}'
		return 0
	fi
	if command -v shasum >/dev/null 2>&1; then
		printf '%s' "${value}" | shasum -a 256 | awk '{print $1}'
		return 0
	fi
	printf '%s' "${value}" | cksum | awk '{print $1}'
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
	if ! items_json="$(printf '%s' "${manual_entries}" | jq -s '
		map(select(.name and .path)) |
		unique_by(.name) |
		map({
			name: .name,
			description: (.description // ""),
			path: .path,
			arguments: (.arguments // {type: "object", properties: {}}),
			role: (.role // null),
			metadata: (.metadata // null)
		}) |
		sort_by(.name)
	')"; then
		mcp_prompts_manual_abort
		mcp_prompts_error -32603 "Manual registration parsing failed"
		return 1
	fi

	local hash
	hash="$(mcp_prompts_hash_string "${items_json}")"
	local total
	total="$(printf '%s' "${items_json}" | jq 'length')"

	MCP_PROMPTS_REGISTRY_JSON="$(jq -n \
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
	if [ "${previous_hash}" != "${MCP_PROMPTS_REGISTRY_HASH}" ]; then
		MCP_PROMPTS_CHANGED=true
	fi
	printf '%s' "${MCP_PROMPTS_REGISTRY_JSON}" >"${MCP_PROMPTS_REGISTRY_PATH}"
	MCP_PROMPTS_MANUAL_ACTIVE=false
	MCP_PROMPTS_MANUAL_BUFFER=""
	return 0
}

mcp_prompts_run_manual_script() {
	if [ ! -x "${MCPBASH_REGISTER_SCRIPT}" ]; then
		return 1
	fi

	mcp_prompts_manual_begin

	local script_output_file
	script_output_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-prompts-manual-output.XXXXXX")"
	local script_status=0

	set +e
	# shellcheck disable=SC1090
	. "${MCPBASH_REGISTER_SCRIPT}" >"${script_output_file}" 2>&1
	script_status=$?
	set -e

	local script_output
	script_output="$(cat "${script_output_file}" 2>/dev/null || true)"
	rm -f "${script_output_file}"

	if [ "${script_status}" -ne 0 ]; then
		mcp_prompts_manual_abort
		mcp_prompts_error -32603 "Manual registration script failed"
		if [ -n "${script_output}" ]; then
			mcp_logging_error "${MCP_PROMPTS_LOGGER}" "Manual registration script output: ${script_output}"
		fi
		return 1
	fi

	if [ -z "${MCP_PROMPTS_MANUAL_BUFFER}" ] && [ -n "${script_output}" ]; then
		mcp_prompts_manual_abort
		if ! mcp_prompts_apply_manual_json "${script_output}"; then
			return 1
		fi
		return 0
	fi

	if [ -n "${script_output}" ]; then
		mcp_logging_warning "${MCP_PROMPTS_LOGGER}" "Manual registration script output: ${script_output}"
	fi

	if ! mcp_prompts_manual_finalize; then
		return 1
	fi
	return 0
}
mcp_prompts_registry_max_bytes() {
	local limit="${MCPBASH_REGISTRY_MAX_BYTES:-104857600}"
	case "${limit}" in
	'' | *[!0-9]*) limit=104857600 ;;
	esac
	printf '%s' "${limit}"
}

mcp_prompts_enforce_registry_limits() {
	local total="$1"
	local json_payload="$2"
	local limit
	local size
	limit="$(mcp_prompts_registry_max_bytes)"
	size="$(LC_ALL=C printf '%s' "${json_payload}" | wc -c | tr -d ' ')"
	if [ "${size}" -gt "${limit}" ]; then
		MCP_PROMPTS_ERR_CODE=-32603
		MCP_PROMPTS_ERR_MESSAGE="Prompts registry exceeds ${limit} byte cap"
		return 1
	fi
	if [ "${total}" -gt 500 ]; then
		mcp_logging_warning "${MCP_PROMPTS_LOGGER}" "Prompts registry contains ${total} entries; consider manual registration"
	fi
	return 0
}

mcp_prompts_error() {
	MCP_PROMPTS_ERR_CODE="$1"
	MCP_PROMPTS_ERR_MESSAGE="$2"
}

mcp_prompts_init() {
	if [ -z "${MCP_PROMPTS_REGISTRY_PATH}" ]; then
		MCP_PROMPTS_REGISTRY_PATH="${MCPBASH_REGISTRY_DIR}/prompts.json"
	fi
	mkdir -p "${MCPBASH_REGISTRY_DIR}"
	mkdir -p "${MCPBASH_ROOT}/prompts" >/dev/null 2>&1 || true
}

mcp_prompts_apply_manual_json() {
	local manual_json="$1"
	local items_json
	if ! items_json="$(printf '%s' "${manual_json}" | jq -c '.prompts // []')"; then
		return 1
	fi

	local hash
	hash="$(mcp_prompts_hash_string "${items_json}")"
	local total
	total="$(printf '%s' "${items_json}" | jq 'length')"

	local registry_json
	registry_json="$(jq -n \
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

	if [ "${previous_hash}" != "${MCP_PROMPTS_REGISTRY_HASH}" ]; then
		MCP_PROMPTS_CHANGED=true
	fi
	MCP_PROMPTS_LAST_SCAN="$(date +%s)"
	printf '%s' "${registry_json}" >"${MCP_PROMPTS_REGISTRY_PATH}"
}

mcp_prompts_refresh_registry() {
	mcp_prompts_init
	if [ -x "${MCPBASH_REGISTER_SCRIPT}" ]; then
		if mcp_prompts_run_manual_script; then
			return 0
		fi
		mcp_logging_error "${MCP_PROMPTS_LOGGER}" "Manual registration script returned empty output or non-zero"
		return 1
	fi
	local now
	now="$(date +%s)"

	if [ -z "${MCP_PROMPTS_REGISTRY_JSON}" ] && [ -f "${MCP_PROMPTS_REGISTRY_PATH}" ]; then
		local tmp_json=""
		if tmp_json="$(cat "${MCP_PROMPTS_REGISTRY_PATH}")"; then
			if echo "${tmp_json}" | jq . >/dev/null 2>&1; then
				MCP_PROMPTS_REGISTRY_JSON="${tmp_json}"
				MCP_PROMPTS_REGISTRY_HASH="$(echo "${MCP_PROMPTS_REGISTRY_JSON}" | jq -r '.hash // empty')"
				MCP_PROMPTS_TOTAL="$(echo "${MCP_PROMPTS_REGISTRY_JSON}" | jq '.total // 0')"
				if ! mcp_prompts_enforce_registry_limits "${MCP_PROMPTS_TOTAL}" "${MCP_PROMPTS_REGISTRY_JSON}"; then
					return 1
				fi
			else
				mcp_logging_warn "${MCP_PROMPTS_LOGGER}" "Discarding invalid prompt registry cache"
				MCP_PROMPTS_REGISTRY_JSON=""
			fi
		else
			mcp_logging_warn "${MCP_PROMPTS_LOGGER}" "Failed to read prompt registry cache ${MCP_PROMPTS_REGISTRY_PATH}"
			MCP_PROMPTS_REGISTRY_JSON=""
		fi
	fi
	if [ -n "${MCP_PROMPTS_REGISTRY_JSON}" ] && [ $((now - MCP_PROMPTS_LAST_SCAN)) -lt "${MCP_PROMPTS_TTL}" ]; then
		return 0
	fi
	local previous_hash="${MCP_PROMPTS_REGISTRY_HASH}"
	mcp_prompts_scan || return 1
	MCP_PROMPTS_LAST_SCAN="${now}"
	if [ "${previous_hash}" != "${MCP_PROMPTS_REGISTRY_HASH}" ]; then
		MCP_PROMPTS_CHANGED=true
	fi
}

mcp_prompts_scan() {
	local prompts_dir="${MCPBASH_ROOT}/prompts"
	local items_file
	items_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-prompts-items.XXXXXX")"

	if [ -d "${prompts_dir}" ]; then
		find "${prompts_dir}" -type f ! -name ".*" ! -name "*.meta.json" 2>/dev/null | sort | while read -r path; do
			local rel_path="${path#"${MCPBASH_ROOT}"/}"
			local base_name
			base_name="$(basename "${path}")"
			local name="${base_name%.*}"
			local dir_name
			dir_name="$(dirname "${path}")"
			local meta_json="${dir_name}/${base_name}.meta.json"
			local description=""
			local role="user"
			local arguments='{"type": "object", "properties": {}}'
			local metadata="null"

			if [ -f "${meta_json}" ]; then
				local meta
				meta="$(cat "${meta_json}")"
				local j_name
				j_name="$(printf '%s' "${meta}" | jq -r '.name // empty' 2>/dev/null)"
				[ -n "${j_name}" ] && name="${j_name}"
				description="$(printf '%s' "${meta}" | jq -r '.description // empty' 2>/dev/null)"
				role="$(printf '%s' "${meta}" | jq -r '.role // "user"' 2>/dev/null)"
				if printf '%s' "${meta}" | jq -e '.arguments' >/dev/null 2>&1; then
					arguments="$(printf '%s' "${meta}" | jq -c '.arguments')"
				fi
				if printf '%s' "${meta}" | jq -e '.metadata' >/dev/null 2>&1; then
					metadata="$(printf '%s' "${meta}" | jq -c '.metadata')"
				fi
			fi

			jq -n \
				--arg name "$name" \
				--arg desc "$description" \
				--arg path "$rel_path" \
				--arg role "$role" \
				--argjson args "$arguments" \
				--argjson meta "$metadata" \
				'{
					name: $name,
					description: $desc,
					path: $path,
					arguments: $args,
					role: $role,
					metadata: $meta
				}' >>"${items_file}"
		done
	fi

	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	local items_json="[]"
	if [ -s "${items_file}" ]; then
		items_json="$(jq -s 'sort_by(.name)' "${items_file}")"
	fi
	rm -f "${items_file}"

	local hash
	hash="$(mcp_prompts_hash_string "${items_json}")"
	local total
	total="$(printf '%s' "${items_json}" | jq 'length')"

	MCP_PROMPTS_REGISTRY_JSON="$(jq -n \
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

	printf '%s' "${MCP_PROMPTS_REGISTRY_JSON}" >"${MCP_PROMPTS_REGISTRY_PATH}"
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
	MCP_PROMPTS_ERR_CODE=0
	# shellcheck disable=SC2034
	MCP_PROMPTS_ERR_MESSAGE=""

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

	local result_json
	result_json="$(echo "${MCP_PROMPTS_REGISTRY_JSON}" | jq -c --argjson offset "$offset" --argjson limit "$numeric_limit" '
		{
			items: .items[$offset:$offset+$limit],
			total: .total
		}
	')"

	# Check if we have a next cursor
	local total
	total="$(echo "${result_json}" | jq '.total')"
	if [ $((offset + numeric_limit)) -lt "${total}" ]; then
		local next_offset=$((offset + numeric_limit))
		local cursor_payload
		cursor_payload="$(jq -n --arg ver "1" --arg col "prompts" --argjson off "$next_offset" --arg hash "${MCP_PROMPTS_REGISTRY_HASH}" '{ver: $ver|tonumber, collection: $col, offset: $off, hash: $hash}')"
		local encoded
		encoded="$(printf '%s' "${cursor_payload}" | base64 | tr -d '\n' | tr -d '=')"
		result_json="$(echo "${result_json}" | jq --arg next "${encoded}" '.nextCursor = $next')"
	fi

	printf '%s' "${result_json}"
}

mcp_prompts_metadata_for_name() {
	local name="$1"
	mcp_prompts_refresh_registry || return 1
	local metadata
	if ! metadata="$(printf '%s' "${MCP_PROMPTS_REGISTRY_JSON}" | jq -c --arg name "${name}" '.items[] | select(.name == $name)' | head -n 1)"; then
		return 1
	fi
	[ -z "${metadata}" ] && return 1
	printf '%s' "${metadata}"
}

mcp_prompts_render() {
	local metadata="$1"
	local args_json="$2"
	local path description role metadata_value
	path="$(printf '%s' "${metadata}" | jq -r '.path // empty')"
	description="$(printf '%s' "${metadata}" | jq -r '.description // ""')"
	role="$(printf '%s' "${metadata}" | jq -r '.role // "system"')"
	metadata_value="$(printf '%s' "${metadata}" | jq -c '.metadata // null')"

	if [ -z "${path}" ]; then
		mcp_prompts_emit_render_result "" "${args_json}" "${role}" "${description}" "${metadata_value}"
		return 0
	fi

	local full_path="${MCPBASH_ROOT}/${path}"
	if [ ! -f "${full_path}" ]; then
		mcp_prompts_emit_render_result "" "${args_json}" "${role}" "${description}" "${metadata_value}"
		return 0
	fi

	local text
	# Use a subshell to isolate exported variables
	if ! text="$(
		set -a
		# Parse args_json and export variables. Only alphanumeric keys are safe for envsubst.
		# We filter keys to simple identifiers.
		eval "$(printf '%s' "${args_json}" | jq -r '
			to_entries | map(select(.key | test("^[a-zA-Z_][a-zA-Z0-9_]*$"))) |
			.[] | "export \(.key)=\(@sh \(.value))"' 2>/dev/null)"
		set +a
		envsubst <"${full_path}"
	)"; then
		return 1
	fi

	mcp_prompts_emit_render_result "${text}" "${args_json}" "${role}" "${description}" "${metadata_value}"
}

mcp_prompts_emit_render_result() {
	local text="$1"
	local args_json="$2"
	local role="$3"
	local description="$4"
	local metadata_value="$5"

	jq -n -c \
		--arg text "${text}" \
		--argjson args "${args_json:-{}}" \
		--arg role "${role}" \
		--arg desc "${description}" \
		--argjson meta "${metadata_value}" \
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
		+ (if $meta != null then {metadata: $meta} else {} end)'
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
	if [ "${MCP_PROMPTS_CHANGED}" = true ]; then
		MCP_PROMPTS_CHANGED=false
		printf '{"jsonrpc":"2.0","method":"notifications/prompts/list_changed","params":{}}'
	else
		printf ''
	fi
}
