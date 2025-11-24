#!/usr/bin/env bash
# Tool discovery, registry generation, invocation helpers.

set -euo pipefail

MCP_TOOLS_REGISTRY_JSON=""
MCP_TOOLS_REGISTRY_HASH=""
MCP_TOOLS_REGISTRY_PATH=""
# shellcheck disable=SC2034
MCP_TOOLS_TOTAL=0
# shellcheck disable=SC2034
MCP_TOOLS_ERROR_CODE=0
# shellcheck disable=SC2034
MCP_TOOLS_ERROR_MESSAGE=""
MCP_TOOLS_TTL="${MCP_TOOLS_TTL:-5}"
MCP_TOOLS_LAST_SCAN=0
MCP_TOOLS_CHANGED=false
MCP_TOOLS_MANUAL_ACTIVE=false
MCP_TOOLS_MANUAL_BUFFER=""
MCP_TOOLS_MANUAL_DELIM=$'\036'
MCP_TOOLS_LOGGER="${MCP_TOOLS_LOGGER:-mcp.tools}"

mcp_tools_manual_begin() {
	MCP_TOOLS_MANUAL_ACTIVE=true
	MCP_TOOLS_MANUAL_BUFFER=""
}

mcp_tools_manual_abort() {
	MCP_TOOLS_MANUAL_ACTIVE=false
	MCP_TOOLS_MANUAL_BUFFER=""
}

mcp_tools_register_manual() {
	local payload="$1"
	if [ "${MCP_TOOLS_MANUAL_ACTIVE}" != "true" ]; then
		return 0
	fi
	if [ -z "${payload}" ]; then
		return 0
	fi
	if [ -n "${MCP_TOOLS_MANUAL_BUFFER}" ]; then
		MCP_TOOLS_MANUAL_BUFFER="${MCP_TOOLS_MANUAL_BUFFER}${MCP_TOOLS_MANUAL_DELIM}${payload}"
	else
		MCP_TOOLS_MANUAL_BUFFER="${payload}"
	fi
	return 0
}

mcp_tools_manual_finalize() {
	if [ "${MCP_TOOLS_MANUAL_ACTIVE}" != "true" ]; then
		return 0
	fi

	local registry_json
	if ! registry_json="$(printf '%s' "${MCP_TOOLS_MANUAL_BUFFER}" | awk -v RS='\036' '{if ($0 != "") print $0}' | "${MCPBASH_JSON_TOOL_BIN}" -s '
		map(select(.name and .path)) |
		unique_by(.name) |
		map({
			name: .name,
			description: (.description // ""),
			path: .path,
			inputSchema: (.inputSchema // .arguments // {type: "object", properties: {}}),
			timeoutSecs: (.timeoutSecs // null),
			outputSchema: (.outputSchema // null)
		}) |
		map(
			if .outputSchema == null then del(.outputSchema) else . end
		) |
		sort_by(.name) |
		{
			version: 1,
			generatedAt: (now | todate),
			items: .,
			total: length
		}
	')"; then
		mcp_tools_manual_abort
		mcp_tools_error -32603 "Manual registration parsing failed"
		return 1
	fi

	registry_json="$(printf '%s' "${registry_json}" | "${MCPBASH_JSON_TOOL_BIN}" -c '
		def ensure_schema:
			if (type == "object") then
				(if ((.type // "") | length) > 0 then . else . + {type: "object"} end)
				| (if (.properties | type) == "object" then . else . + {properties: {}} end)
			else
				{type: "object", properties: {}}
			end;
		.items |= map(.inputSchema = (.inputSchema | ensure_schema))
	')"

	local items_json
	items_json="$(echo "${registry_json}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.items')"
	local hash
	if command -v sha256sum >/dev/null 2>&1; then
		hash="$(printf '%s' "${items_json}" | sha256sum | awk '{print $1}')"
	elif command -v shasum >/dev/null 2>&1; then
		hash="$(printf '%s' "${items_json}" | shasum -a 256 | awk '{print $1}')"
	else
		hash="$(printf '%s' "${items_json}" | cksum | awk '{print $1}')"
	fi

	registry_json="$(echo "${registry_json}" | "${MCPBASH_JSON_TOOL_BIN}" --arg hash "${hash}" '.hash = $hash')"

	local previous_hash="${MCP_TOOLS_REGISTRY_HASH}"
	MCP_TOOLS_REGISTRY_JSON="${registry_json}"
	MCP_TOOLS_REGISTRY_HASH="${hash}"
	MCP_TOOLS_TOTAL="$(echo "${registry_json}" | "${MCPBASH_JSON_TOOL_BIN}" '.total')"

	if ! mcp_tools_enforce_registry_limits "${MCP_TOOLS_TOTAL}" "${registry_json}"; then
		mcp_tools_manual_abort
		return 1
	fi

	MCP_TOOLS_MANUAL_ACTIVE=false
	MCP_TOOLS_MANUAL_BUFFER=""

	MCP_TOOLS_LAST_SCAN="$(date +%s)"
	if [ "${previous_hash}" != "${MCP_TOOLS_REGISTRY_HASH}" ]; then
		MCP_TOOLS_CHANGED=true
	fi
	printf '%s' "${registry_json}" >"${MCP_TOOLS_REGISTRY_PATH}"
	return 0
}

mcp_tools_normalize_schema() {
	local raw="$1"
	local normalized
	if ! normalized="$({ printf '%s' "${raw}"; } | "${MCPBASH_JSON_TOOL_BIN}" -c '
		def ensure_schema:
			if (type == "object") then
				(if ((.type // "") | length) > 0 then . else . + {type: "object"} end)
				| (if (.properties | type) == "object" then . else . + {properties: {}} end)
			else
				{type: "object", properties: {}}
			end;
		ensure_schema
	' 2>/dev/null)"; then
		normalized='{"type":"object","properties":{}}'
	fi
	printf '%s' "${normalized}"
}

mcp_tools_registry_max_bytes() {
	local limit="${MCPBASH_REGISTRY_MAX_BYTES:-104857600}"
	case "${limit}" in
	'' | *[!0-9]*) limit=104857600 ;;
	esac
	printf '%s' "${limit}"
}

mcp_tools_enforce_registry_limits() {
	local total="$1"
	local json_payload="$2"
	local limit
	local size
	limit="$(mcp_tools_registry_max_bytes)"
	size="$(LC_ALL=C printf '%s' "${json_payload}" | wc -c | tr -d ' ')"
	if [ "${size}" -gt "${limit}" ]; then
		mcp_tools_error -32603 "Tool registry exceeds ${limit} byte cap"
		return 1
	fi
	if [ "${total}" -gt 500 ]; then
		mcp_logging_warning "${MCP_TOOLS_LOGGER}" "Tools registry contains ${total} entries; consider manual registration"
	fi
	return 0
}

mcp_tools_error() {
	MCP_TOOLS_ERROR_CODE="$1"
	MCP_TOOLS_ERROR_MESSAGE="$2"
}

mcp_tools_init() {
	if [ -z "${MCP_TOOLS_REGISTRY_PATH}" ]; then
		MCP_TOOLS_REGISTRY_PATH="${MCPBASH_REGISTRY_DIR}/tools.json"
	fi
	mkdir -p "${MCPBASH_REGISTRY_DIR}"
}

mcp_tools_apply_manual_json() {
	local manual_json="$1"
	local registry_json

	if ! echo "${manual_json}" | "${MCPBASH_JSON_TOOL_BIN}" -e '.tools | type == "array"' >/dev/null 2>&1; then
		manual_json='{"tools":[]}'
	fi

	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	registry_json="$(echo "${manual_json}" | "${MCPBASH_JSON_TOOL_BIN}" --arg ts "${timestamp}" '{
		version: 1,
		generatedAt: $ts,
		items: .tools,
		total: (.tools | length)
	}')"

	local items_json
	items_json="$(echo "${registry_json}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.items')"
	local hash
	if command -v sha256sum >/dev/null 2>&1; then
		hash="$(printf '%s' "${items_json}" | sha256sum | awk '{print $1}')"
	elif command -v shasum >/dev/null 2>&1; then
		hash="$(printf '%s' "${items_json}" | shasum -a 256 | awk '{print $1}')"
	else
		hash="$(printf '%s' "${items_json}" | cksum | awk '{print $1}')"
	fi

	registry_json="$(echo "${registry_json}" | "${MCPBASH_JSON_TOOL_BIN}" --arg hash "${hash}" '.hash = $hash')"

	local new_hash="${hash}"
	if [ "${new_hash}" != "${MCP_TOOLS_REGISTRY_HASH}" ]; then
		MCP_TOOLS_CHANGED=true
	fi
	MCP_TOOLS_REGISTRY_JSON="${registry_json}"
	MCP_TOOLS_REGISTRY_HASH="${new_hash}"
	MCP_TOOLS_TOTAL="$(echo "${registry_json}" | "${MCPBASH_JSON_TOOL_BIN}" '.total')"

	if ! mcp_tools_enforce_registry_limits "${MCP_TOOLS_TOTAL}" "${registry_json}"; then
		return 1
	fi
	MCP_TOOLS_LAST_SCAN="$(date +%s)"
	printf '%s' "${registry_json}" >"${MCP_TOOLS_REGISTRY_PATH}"
}

mcp_tools_run_manual_script() {
	if [ ! -x "${MCPBASH_SERVER_DIR}/register.sh" ]; then
		return 1
	fi

	mcp_tools_manual_begin

	local script_output_file
	script_output_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-tools-manual-output.XXXXXX")"
	local script_status=0
	local manual_limit="${MCPBASH_MAX_MANUAL_REGISTRY_BYTES:-1048576}"
	case "${manual_limit}" in
	'' | *[!0-9]*) manual_limit=1048576 ;;
	0) manual_limit=1048576 ;;
	esac

	set +e
	# shellcheck disable=SC1090
	# shellcheck disable=SC1091  # register.sh lives in project; optional for callers
	. "${MCPBASH_SERVER_DIR}/register.sh" >"${script_output_file}" 2>&1
	script_status=$?
	set -e

	local script_size
	script_size="$(wc -c <"${script_output_file}" | tr -d ' ')"
	if [ "${script_size}" -gt "${manual_limit}" ]; then
		rm -f "${script_output_file}"
		mcp_tools_manual_abort
		mcp_tools_error -32603 "Manual registration output exceeded ${manual_limit} bytes"
		return 1
	fi
	local script_output
	script_output="$(cat "${script_output_file}" 2>/dev/null || true)"
	rm -f "${script_output_file}"

	if [ "${script_status}" -ne 0 ]; then
		mcp_tools_manual_abort
		mcp_tools_error -32603 "Manual registration script failed"
		if [ -n "${script_output}" ]; then
			mcp_logging_error "${MCP_TOOLS_LOGGER}" "Manual registration script output: ${script_output}"
		fi
		return 1
	fi

	if [ -z "${MCP_TOOLS_MANUAL_BUFFER}" ] && [ -n "${script_output}" ]; then
		mcp_tools_manual_abort
		if ! mcp_tools_apply_manual_json "${script_output}"; then
			return 1
		fi
		return 0
	fi

	if [ -n "${script_output}" ]; then
		mcp_logging_warning "${MCP_TOOLS_LOGGER}" "Manual registration script output: ${script_output}"
	fi

	if ! mcp_tools_manual_finalize; then
		return 1
	fi
	return 0
}

mcp_tools_refresh_registry() {
	mcp_tools_init
	if [ -x "${MCPBASH_SERVER_DIR}/register.sh" ]; then
		if mcp_tools_run_manual_script; then
			return 0
		fi
		return 1
	fi
	local now
	now="$(date +%s)"

	if [ -z "${MCP_TOOLS_REGISTRY_JSON}" ] && [ -f "${MCP_TOOLS_REGISTRY_PATH}" ]; then
		local tmp_json=""
		if tmp_json="$(cat "${MCP_TOOLS_REGISTRY_PATH}")"; then
			if echo "${tmp_json}" | "${MCPBASH_JSON_TOOL_BIN}" . >/dev/null 2>&1; then
				MCP_TOOLS_REGISTRY_JSON="${tmp_json}"
				MCP_TOOLS_REGISTRY_HASH="$(echo "${MCP_TOOLS_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.hash // empty')"
				MCP_TOOLS_TOTAL="$(echo "${MCP_TOOLS_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" '.total // 0')"
				if ! mcp_tools_enforce_registry_limits "${MCP_TOOLS_TOTAL}" "${MCP_TOOLS_REGISTRY_JSON}"; then
					return 1
				fi
			else
				MCP_TOOLS_REGISTRY_JSON=""
			fi
		else
			MCP_TOOLS_REGISTRY_JSON=""
		fi
	fi
	if [ -n "${MCP_TOOLS_REGISTRY_JSON}" ] && [ $((now - MCP_TOOLS_LAST_SCAN)) -lt "${MCP_TOOLS_TTL}" ]; then
		return 0
	fi
	local previous_hash="${MCP_TOOLS_REGISTRY_HASH}"
	mcp_tools_scan || return 1
	MCP_TOOLS_LAST_SCAN="${now}"
	if [ "${previous_hash}" != "${MCP_TOOLS_REGISTRY_HASH}" ]; then
		MCP_TOOLS_CHANGED=true
	fi
}

mcp_tools_scan() {
	local items_file
	items_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-tools-items.XXXXXX")"

	if [ -d "${MCPBASH_TOOLS_DIR}" ]; then
		find "${MCPBASH_TOOLS_DIR}" -type f ! -name ".*" ! -name "*.meta.json" 2>/dev/null | sort | while read -r path; do
			# On Windows (Git Bash/MSYS), -x test is unreliable. Check for shebang or .sh extension as fallback.
			if [ ! -x "${path}" ]; then
				# Fallback: check if file has shebang or is .sh/.bash
				if [[ ! "${path}" =~ \.(sh|bash)$ ]] && ! head -n1 "${path}" 2>/dev/null | grep -q '^#!'; then
					continue
				fi
			fi
			local rel_path="${path#"${MCPBASH_TOOLS_DIR}"/}"
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
			local arguments="{}"
			local timeout=""
			local output_schema="null"

			if [ -f "${meta_json}" ]; then
				local meta
				meta="$(cat "${meta_json}")"
				local j_name
				j_name="$(printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.name // empty' 2>/dev/null)"
				[ -n "${j_name}" ] && name="${j_name}"
				description="$(printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.description // empty' 2>/dev/null)"
				arguments="$(printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.inputSchema // .arguments // {type: "object", properties: {}}' 2>/dev/null)"
				timeout="$(printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.timeoutSecs // empty' 2>/dev/null)"
				output_schema="$(printf '%s' "${meta}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.outputSchema // null' 2>/dev/null)"
			fi

			if [ "${arguments}" = "{}" ]; then
				local header
				header="$(head -n 10 "${path}")"
				local mcp_line
				mcp_line="$(echo "${header}" | grep "mcp:" | head -n 1)"
				if [ -n "${mcp_line}" ]; then
					local json_payload
					json_payload="${mcp_line#*mcp:}"
					local h_name
					h_name="$(echo "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.name // empty' 2>/dev/null)"
					[ -n "${h_name}" ] && name="${h_name}"
					local h_desc
					h_desc="$(echo "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.description // empty' 2>/dev/null)"
					[ -n "${h_desc}" ] && description="${h_desc}"
					arguments="$(echo "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.arguments // {type: "object", properties: {}}' 2>/dev/null)"
					timeout="$(echo "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.timeoutSecs // empty' 2>/dev/null)"
					output_schema="$(echo "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.outputSchema // null' 2>/dev/null)"
				fi
			fi

			arguments="$(mcp_tools_normalize_schema "${arguments}")"

			# Construct item object
			"${MCPBASH_JSON_TOOL_BIN}" -n \
				--arg name "$name" \
				--arg desc "$description" \
				--arg path "$rel_path" \
				--argjson args "$arguments" \
				--arg timeout "$timeout" \
				--argjson out "$output_schema" \
				'{
					name: $name,
					description: $desc,
					path: $path,
					inputSchema: $args,
					timeoutSecs: (if $timeout != "" then ($timeout|tonumber) else null end)
				}
				+ (if $out != null then {outputSchema: $out} else {} end)' >>"${items_file}"
		done
	fi

	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	local items_json="[]"
	if [ -s "${items_file}" ]; then
		items_json="$("${MCPBASH_JSON_TOOL_BIN}" -s '.' "${items_file}")"
	fi
	rm -f "${items_file}"

	local hash
	if command -v sha256sum >/dev/null 2>&1; then
		hash="$(printf '%s' "${items_json}" | sha256sum | awk '{print $1}')"
	elif command -v shasum >/dev/null 2>&1; then
		hash="$(printf '%s' "${items_json}" | shasum -a 256 | awk '{print $1}')"
	else
		hash="$(printf '%s' "${items_json}" | cksum | awk '{print $1}')"
	fi

	local total
	total="$(printf '%s' "${items_json}" | "${MCPBASH_JSON_TOOL_BIN}" 'length')"

	MCP_TOOLS_REGISTRY_JSON="$("${MCPBASH_JSON_TOOL_BIN}" -n \
		--arg ver "1" \
		--arg ts "${timestamp}" \
		--arg hash "${hash}" \
		--argjson items "${items_json}" \
		--argjson total "${total}" \
		'{version: $ver|tonumber, generatedAt: $ts, items: $items, hash: $hash, total: $total}')"

	MCP_TOOLS_REGISTRY_HASH="${hash}"
	MCP_TOOLS_TOTAL="${total}"

	if ! mcp_tools_enforce_registry_limits "${MCP_TOOLS_TOTAL}" "${MCP_TOOLS_REGISTRY_JSON}"; then
		return 1
	fi

	printf '%s' "${MCP_TOOLS_REGISTRY_JSON}" >"${MCP_TOOLS_REGISTRY_PATH}"
}

mcp_tools_consume_notification() {
	if [ "${MCP_TOOLS_CHANGED}" = true ]; then
		MCP_TOOLS_CHANGED=false
		printf '{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{}}'
	else
		printf ''
	fi
}

mcp_tools_poll() {
	if mcp_runtime_is_minimal_mode; then
		return 0
	fi
	local ttl="${MCP_TOOLS_TTL:-5}"
	case "${ttl}" in
	'' | *[!0-9]*) ttl=5 ;;
	esac
	local now
	now="$(date +%s)"
	if [ "${MCP_TOOLS_LAST_SCAN}" -eq 0 ] || [ $((now - MCP_TOOLS_LAST_SCAN)) -ge "${ttl}" ]; then
		mcp_tools_refresh_registry || true
	fi
	return 0
}

mcp_tools_decode_cursor() {
	local cursor="$1"
	local hash="$2"
	local offset
	if ! offset="$(mcp_paginate_decode "${cursor}" "tools" "${hash}")"; then
		return 1
	fi
	printf '%s' "${offset}"
}

mcp_tools_list() {
	local limit="$1"
	local cursor="$2"
	# shellcheck disable=SC2034
	MCP_TOOLS_ERROR_CODE=0
	# shellcheck disable=SC2034
	MCP_TOOLS_ERROR_MESSAGE=""

	mcp_tools_refresh_registry || {
		mcp_tools_error -32603 "Unable to load tool registry"
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
		if ! offset="$(mcp_tools_decode_cursor "${cursor}" "${MCP_TOOLS_REGISTRY_HASH}")"; then
			mcp_tools_error -32602 "Invalid cursor"
			return 1
		fi
	fi

	local result_json
	result_json="$(echo "${MCP_TOOLS_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -c --argjson offset "${offset}" --argjson limit "${numeric_limit}" '
		{
			tools: .items[$offset:$offset+$limit]
		}
	')"

	local total="${MCP_TOOLS_TOTAL}"
	if [ $((offset + numeric_limit)) -lt "${total}" ]; then
		local next_offset=$((offset + numeric_limit))
		local cursor_payload
		cursor_payload="$("${MCPBASH_JSON_TOOL_BIN}" -n --arg ver "1" --arg col "tools" --argjson off "$next_offset" --arg hash "${MCP_TOOLS_REGISTRY_HASH}" '{ver: $ver|tonumber, collection: $col, offset: $off, hash: $hash}')"
		local encoded
		encoded="$(printf '%s' "${cursor_payload}" | base64 | tr -d '\n' | tr -d '=')"
		result_json="$(echo "${result_json}" | "${MCPBASH_JSON_TOOL_BIN}" -c --arg next "${encoded}" '.nextCursor = $next')"
	fi

	printf '%s' "${result_json}"
}

mcp_tools_metadata_for_name() {
	local name="$1"
	mcp_tools_refresh_registry || return 1
	local metadata
	if ! metadata="$(echo "${MCP_TOOLS_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -c --arg name "${name}" '.items[] | select(.name == $name)' | head -n 1)"; then
		return 1
	fi
	if [ -z "${metadata}" ]; then
		return 1
	fi
	printf '%s' "${metadata}"
}

mcp_tools_call() {
	local name="$1"
	local args_json="$2"
	local timeout_override="$3"
	# shellcheck disable=SC2034
	MCP_TOOLS_ERROR_CODE=0
	# shellcheck disable=SC2034
	MCP_TOOLS_ERROR_MESSAGE=""

	local metadata
	if ! metadata="$(mcp_tools_metadata_for_name "${name}")"; then
		mcp_tools_error -32601 "Tool not found"
		return 1
	fi

	local info_json
	info_json="$(echo "${metadata}" | "${MCPBASH_JSON_TOOL_BIN}" -c '{path, outputSchema, timeoutSecs}')"

	local tool_path
	tool_path="$(echo "${info_json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.path // empty')"

	if [ -z "${tool_path}" ]; then
		mcp_tools_error -32601 "Tool path unavailable"
		return 1
	fi

	local absolute_path="${MCPBASH_TOOLS_DIR}/${tool_path}"
	if [ ! -x "${absolute_path}" ]; then
		mcp_tools_error -32601 "Tool executable missing"
		return 1
	fi

	local env_limit="${MCPBASH_ENV_PAYLOAD_THRESHOLD:-65536}"
	case "${env_limit}" in
	'' | *[!0-9]*) env_limit=65536 ;;
	0) env_limit=65536 ;;
	esac

	local args_env_value="${args_json}"
	local args_file=""
	if [ "${#args_json}" -gt "${env_limit}" ]; then
		args_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-tool-args.XXXXXX")"
		printf '%s' "${args_json}" >"${args_file}"
		args_env_value=""
	fi

	local metadata_env_value="${metadata}"
	local metadata_file=""
	if [ "${#metadata}" -gt "${env_limit}" ]; then
		metadata_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-tool-metadata.XXXXXX")"
		printf '%s' "${metadata}" >"${metadata_file}"
		metadata_env_value=""
	fi

	local metadata_timeout
	metadata_timeout="$(echo "${info_json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.timeoutSecs // empty')"

	local output_schema
	output_schema="$(echo "${info_json}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.outputSchema // null')"

	local effective_timeout="${timeout_override}"
	if [ -z "${effective_timeout}" ] && [ -n "${metadata_timeout}" ]; then
		effective_timeout="${metadata_timeout}"
	fi

	local stdout_file stderr_file
	stdout_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-tools-stdout.XXXXXX")"
	stderr_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-tools-stderr.XXXXXX")"

	local has_json_tool="false"
	if [ "${MCPBASH_MODE}" != "minimal" ] && [ "${MCPBASH_JSON_TOOL}" != "none" ]; then
		has_json_tool="true"
	fi

	local exit_code
	(
		cd "${MCPBASH_PROJECT_ROOT}" || exit 1
		MCP_SDK="${MCPBASH_HOME}/sdk"
		MCP_TOOL_NAME="${name}"
		MCP_TOOL_PATH="${absolute_path}"
		MCP_TOOL_ARGS_JSON="${args_env_value}"
		MCP_TOOL_METADATA_JSON="${metadata_env_value}"
		if [ -n "${args_file}" ]; then
			MCP_TOOL_ARGS_FILE="${args_file}"
		else
			unset MCP_TOOL_ARGS_FILE 2>/dev/null || true
		fi
		if [ -n "${metadata_file}" ]; then
			MCP_TOOL_METADATA_FILE="${metadata_file}"
		else
			unset MCP_TOOL_METADATA_FILE 2>/dev/null || true
		fi
		export MCP_SDK MCP_TOOL_NAME MCP_TOOL_PATH MCP_TOOL_ARGS_JSON MCP_TOOL_METADATA_JSON
		[ -n "${args_file}" ] && export MCP_TOOL_ARGS_FILE
		[ -n "${metadata_file}" ] && export MCP_TOOL_METADATA_FILE
		if [ -n "${effective_timeout}" ]; then
			with_timeout "${effective_timeout}" -- "${absolute_path}"
		else
			"${absolute_path}"
		fi
	) >"${stdout_file}" 2>"${stderr_file}" || exit_code=$?
	exit_code=${exit_code:-0}

	local limit="${MCPBASH_MAX_TOOL_OUTPUT_SIZE:-10485760}"
	case "${limit}" in
	'' | *[!0-9]*) limit=10485760 ;;
	esac
	local stdout_size
	stdout_size="$(wc -c <"${stdout_file}" | tr -d ' ')"
	if [ "${stdout_size}" -gt "${limit}" ]; then
		mcp_logging_error "${MCP_TOOLS_LOGGER}" "Tool ${name} output ${stdout_size} bytes exceeds limit ${limit}" || true
		rm -f "${stdout_file}" "${stderr_file}"
		# shellcheck disable=SC2034
		MCP_TOOLS_ERROR_CODE=-32603
		# shellcheck disable=SC2034
		MCP_TOOLS_ERROR_MESSAGE="Tool output exceeded ${limit} bytes"
		return 1
	fi

	local stdout_content
	local stderr_content
	local stderr_limit="${MCPBASH_MAX_TOOL_STDERR_SIZE:-${limit}}"
	case "${stderr_limit}" in
	'' | *[!0-9]*) stderr_limit="${limit}" ;;
	0) stderr_limit="${limit}" ;;
	esac
	local stderr_size
	stderr_size="$(wc -c <"${stderr_file}" | tr -d ' ')"
	if [ "${stderr_size}" -gt "${stderr_limit}" ]; then
		mcp_logging_error "${MCP_TOOLS_LOGGER}" "Tool ${name} stderr ${stderr_size} bytes exceeds limit ${stderr_limit}" || true
		rm -f "${stdout_file}" "${stderr_file}"
		[ -n "${args_file}" ] && rm -f "${args_file}"
		[ -n "${metadata_file}" ] && rm -f "${metadata_file}"
		# shellcheck disable=SC2034
		MCP_TOOLS_ERROR_CODE=-32603
		# shellcheck disable=SC2034
		MCP_TOOLS_ERROR_MESSAGE="Tool stderr exceeded ${stderr_limit} bytes"
		return 1
	fi
	stderr_content="${stderr_file}"
	stdout_content="${stdout_file}"

	case "${exit_code}" in
	124 | 137)
		# shellcheck disable=SC2034
		MCP_TOOLS_ERROR_CODE=-32002
		# shellcheck disable=SC2034
		MCP_TOOLS_ERROR_MESSAGE="Tool timed out"
		return 1
		;;
	143)
		# shellcheck disable=SC2034
		MCP_TOOLS_ERROR_CODE=-32001
		# shellcheck disable=SC2034
		MCP_TOOLS_ERROR_MESSAGE="Tool cancelled"
		return 1
		;;
	esac

	local result_json
	result_json="$(
		"${MCPBASH_JSON_TOOL_BIN}" -n -c \
			--arg name "${name}" \
			--rawfile stdout "${stdout_content}" \
			--rawfile stderr "${stderr_content}" \
			--argjson exit_code "${exit_code}" \
			--arg has_json "${has_json_tool}" \
			'
		{
			name: $name,
			content: [],
			isError: false,
			_meta: {
				exitCode: $exit_code
			}
		} as $base |
		
		# Try to parse stdout as JSON if enabled
		if $has_json == "true" and ($stdout | length > 0) then
			try (
				($stdout | fromjson) as $json |
				$base
				| .content += [{type: "json", json: $json}]
				| .content += [{type: "text", text: $stdout}]
				| .structuredContent = $json
			) catch (
				$base | .content += [{type: "text", text: $stdout}]
			)
		else
			$base | .content += [{type: "text", text: $stdout}]
		end |
		
		# Add stderr if present
		if ($stderr | length > 0) then
			._meta.stderr = $stderr
		else . end |
		
		# Set isError if exit code non-zero
		if $exit_code != 0 then
			.isError = true
		else . end
		'
	)"

	rm -f "${stdout_file}" "${stderr_file}"
	[ -n "${args_file}" ] && rm -f "${args_file}"
	[ -n "${metadata_file}" ] && rm -f "${metadata_file}"

	printf '%s' "${result_json}"
}
