#!/usr/bin/env bash
# Tool discovery, registry generation, invocation helpers.

set -euo pipefail
# shellcheck disable=SC2030,SC2031  # Subshell env mutations are intentionally isolated

MCP_TOOLS_REGISTRY_JSON=""
MCP_TOOLS_REGISTRY_HASH=""
MCP_TOOLS_REGISTRY_PATH=""
# shellcheck disable=SC2034
MCP_TOOLS_TOTAL=0
# Internal error handoff between library and handler (not user-configurable).
# shellcheck disable=SC2034
_MCP_TOOLS_ERROR_CODE=0
# shellcheck disable=SC2034
_MCP_TOOLS_ERROR_MESSAGE=""
# shellcheck disable=SC2034
_MCP_TOOLS_ERROR_DATA=""
# shellcheck disable=SC2034
_MCP_TOOLS_RESULT=""
MCP_TOOLS_TTL="${MCP_TOOLS_TTL:-5}"
MCP_TOOLS_LAST_SCAN=0
MCP_TOOLS_LAST_NOTIFIED_HASH=""
MCP_TOOLS_CHANGED=false
MCP_TOOLS_MANUAL_ACTIVE=false
MCP_TOOLS_MANUAL_BUFFER=""
MCP_TOOLS_MANUAL_DELIM=$'\036'
MCP_TOOLS_LOGGER="${MCP_TOOLS_LOGGER:-mcp.tools}"
: "${MCPBASH_TOOL_ENV_INHERIT_WARNED:=false}"

if ! command -v mcp_registry_resolve_scan_root >/dev/null 2>&1; then
	# shellcheck disable=SC1090
	. "${MCPBASH_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib/registry.sh"
fi

mcp_tools_scan_root() {
	mcp_registry_resolve_scan_root "${MCPBASH_TOOLS_DIR}"
}

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
	hash="$(mcp_hash_string "${items_json}")"

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
	local write_rc=0
	mcp_registry_write_with_lock "${MCP_TOOLS_REGISTRY_PATH}" "${registry_json}" || write_rc=$?
	if [ "${write_rc}" -ne 0 ]; then
		mcp_tools_manual_abort
		return "${write_rc}"
	fi
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
	mcp_registry_global_max_bytes
}

mcp_tools_enforce_registry_limits() {
	local total="$1"
	local json_payload="$2"
	local limit_or_size

	if ! limit_or_size="$(mcp_registry_check_size "${json_payload}")"; then
		mcp_tools_error -32603 "Tool registry exceeds ${limit_or_size} byte cap"
		return 1
	fi
	if [ "${total}" -gt 500 ]; then
		mcp_logging_warning "${MCP_TOOLS_LOGGER}" "Tools registry contains ${total} entries; consider manual registration"
	fi
	return 0
}

mcp_tools_error() {
	_MCP_TOOLS_ERROR_CODE="$1"
	_MCP_TOOLS_ERROR_MESSAGE="$2"
	_MCP_TOOLS_ERROR_DATA="${3:-}"
}

# Emit error JSON to stdout for propagation through command substitution.
# Usage: _mcp_tools_emit_error <code> <message> [data]
# The data argument should be valid JSON (object, string, null, etc.)
# Codes are JSON-RPC 2.0 values; we also emit the reserved server range for
# tool-specific states (-32001 cancelled, -32603 timed out).
_mcp_tools_emit_error() {
	local err_code="$1"
	local err_message="$2"
	local err_data="${3:-null}"
	# Also set the global variables for any code that reads them directly
	_MCP_TOOLS_ERROR_CODE="${err_code}"
	_MCP_TOOLS_ERROR_MESSAGE="${err_message}"
	_MCP_TOOLS_ERROR_DATA="${err_data}"
	# Output error JSON to variable - handler will parse this
	if [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
		local msg_escaped
		msg_escaped="$(printf '%s' "${err_message}" | "${MCPBASH_JSON_TOOL_BIN}" -Rs '.')"
		_MCP_TOOLS_RESULT="$(printf '{"_mcpToolError":true,"code":%s,"message":%s,"data":%s}' "${err_code}" "${msg_escaped}" "${err_data}")"
	else
		# Minimal mode: basic JSON escaping
		local msg_escaped="${err_message//\\/\\\\}"
		msg_escaped="${msg_escaped//\"/\\\"}"
		msg_escaped="${msg_escaped//$'\n'/\\n}"
		_MCP_TOOLS_RESULT="$(printf '{"_mcpToolError":true,"code":%s,"message":"%s","data":%s}' "${err_code}" "${msg_escaped}" "${err_data}")"
	fi
}

mcp_tools_init() {
	if [ -z "${MCP_TOOLS_REGISTRY_PATH}" ]; then
		MCP_TOOLS_REGISTRY_PATH="${MCPBASH_REGISTRY_DIR}/tools.json"
	fi
	mkdir -p "${MCPBASH_REGISTRY_DIR}"
}

mcp_tools_validate_output_schema() {
	local stdout_file="$1"
	local output_schema="$2"
	local has_json_tool="$3"

	# Skip validation if no schema or no JSON tool
	if [ "${output_schema}" = "null" ] || [ -z "${output_schema}" ] || [ "${has_json_tool}" != "true" ]; then
		return 0
	fi

	# Parse the tool output as JSON
	local structured_json=""
	if ! structured_json="$("${MCPBASH_JSON_TOOL_BIN}" -c '.' "${stdout_file}" 2>/dev/null)"; then
		_mcp_tools_emit_error -32603 "Tool output is not valid JSON for declared outputSchema" "null"
		return 1
	fi

	if [ -z "${structured_json}" ]; then
		_mcp_tools_emit_error -32603 "Tool output is empty for declared outputSchema" "null"
		return 1
	fi

	# Write schema to temp file to avoid shell quoting issues with --argjson
	# Run validation using jq -s pattern (avoid --slurpfile for Windows/gojq compatibility)
	local validation_result
	local validation_status=0
	set +e
	validation_result="$(printf '%s\n%s' "${output_schema}" "${structured_json}" | "${MCPBASH_JSON_TOOL_BIN}" -s '
		.[0] as $s |
		.[1] as $data |
		(
			# Check required fields exist
			(($s.required // []) | all(. as $k | $data | has($k)))
		) as $required_ok |
		(
			# Check types match for present fields
			(($s.properties // {}) | keys) |
			all(. as $k |
				($data[$k] // null) as $v |
				(($s.properties // {})[$k].type // "") as $t |
				if ($v == null) or ($t == "") then true
				else
					(if $t=="string" then ($v|type)=="string"
					elif $t=="number" then ($v|type)=="number"
					elif $t=="integer" then ($v|type)=="number" and (($v|floor)==$v)
					elif $t=="boolean" then ($v|type)=="boolean"
					elif $t=="array" then ($v|type)=="array"
					elif $t=="object" then ($v|type)=="object"
					else true end)
				end)
		) as $types_ok |
		if ($s.type // "object") != "object" then true
		elif $required_ok and $types_ok then true
		else false
		end
	' 2>/dev/null)"
	validation_status=$?
	set -e

	if [ "${validation_status}" -ne 0 ]; then
		_mcp_tools_emit_error -32603 "Tool output does not satisfy outputSchema" "null"
		return 1
	fi

	# Check result - must be exactly true
	if [ "${validation_result}" = "true" ]; then
		return 0
	fi

	_mcp_tools_emit_error -32603 "Tool output does not satisfy outputSchema" "null"
	return 1
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
	hash="$(mcp_hash_string "${items_json}")"

	registry_json="$(echo "${registry_json}" | "${MCPBASH_JSON_TOOL_BIN}" --arg hash "${hash}" '.hash = $hash')"

	local new_hash="${hash}"
	MCP_TOOLS_REGISTRY_JSON="${registry_json}"
	MCP_TOOLS_REGISTRY_HASH="${new_hash}"
	MCP_TOOLS_TOTAL="$(echo "${registry_json}" | "${MCPBASH_JSON_TOOL_BIN}" '.total')"

	if ! mcp_tools_enforce_registry_limits "${MCP_TOOLS_TOTAL}" "${registry_json}"; then
		return 1
	fi
	MCP_TOOLS_LAST_SCAN="$(date +%s)"
	local write_rc=0
	mcp_registry_write_with_lock "${MCP_TOOLS_REGISTRY_PATH}" "${registry_json}" || write_rc=$?
	if [ "${write_rc}" -ne 0 ]; then
		return "${write_rc}"
	fi
}

mcp_tools_refresh_registry() {
	local scan_root
	scan_root="$(mcp_tools_scan_root)"
	mcp_tools_init
	# Registry refresh order: prefer user-provided server.d/register.sh output,
	# then reuse cached JSON if TTL has not expired, finally fall back to a full
	# filesystem scan (with fastpath snapshot to avoid rescanning unchanged trees).
	if mcp_registry_register_apply "tools"; then
		return 0
	else
		local manual_status=$?
		if [ "${manual_status}" -eq 2 ]; then
			local err
			err="$(mcp_registry_register_error_for_kind "tools")"
			if [ -z "${err}" ]; then
				err="Manual registration script returned empty output or non-zero"
			fi
			mcp_logging_error "${MCP_TOOLS_LOGGER}" "${err}"
			return 1
		fi
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

	local fastpath_snapshot
	fastpath_snapshot="$(mcp_registry_fastpath_snapshot "${scan_root}")"
	if mcp_registry_fastpath_unchanged "tools" "${fastpath_snapshot}"; then
		MCP_TOOLS_LAST_SCAN="${now}"
		# Sync in-memory state from cache if another process refreshed the registry
		if [ -f "${MCP_TOOLS_REGISTRY_PATH}" ]; then
			local cached_hash
			cached_hash="$("${MCPBASH_JSON_TOOL_BIN}" -r '.hash // empty' "${MCP_TOOLS_REGISTRY_PATH}" 2>/dev/null || true)"
			if [ -n "${cached_hash}" ] && [ "${cached_hash}" != "${MCP_TOOLS_REGISTRY_HASH}" ]; then
				local cached_json cached_total
				cached_json="$(cat "${MCP_TOOLS_REGISTRY_PATH}" 2>/dev/null || true)"
				cached_total="$("${MCPBASH_JSON_TOOL_BIN}" '.total // 0' "${MCP_TOOLS_REGISTRY_PATH}" 2>/dev/null || printf '0')"
				MCP_TOOLS_REGISTRY_JSON="${cached_json}"
				MCP_TOOLS_REGISTRY_HASH="${cached_hash}"
				MCP_TOOLS_TOTAL="${cached_total}"
				MCP_TOOLS_CHANGED=true
			fi
		fi
		return 0
	fi

	# Capture previous hash from cache file if in-memory state is empty (parent may not have run scan yet)
	local previous_hash="${MCP_TOOLS_REGISTRY_HASH}"
	if [ -z "${previous_hash}" ] && [ -f "${MCP_TOOLS_REGISTRY_PATH}" ]; then
		previous_hash="$("${MCPBASH_JSON_TOOL_BIN}" -r '.hash // empty' "${MCP_TOOLS_REGISTRY_PATH}" 2>/dev/null || true)"
	fi
	mcp_tools_scan "${scan_root}" || return 1
	MCP_TOOLS_LAST_SCAN="${now}"
	# Recompute fastpath snapshot post-scan to track content changes (mtime/cksum)
	fastpath_snapshot="$(mcp_registry_fastpath_snapshot "${scan_root}")"
	mcp_registry_fastpath_store "tools" "${fastpath_snapshot}" || true
	# Incorporate fastpath snapshot into registry hash so content-only changes trigger notifications
	if [ -n "${MCP_TOOLS_REGISTRY_HASH}" ] && [ -n "${fastpath_snapshot}" ]; then
		local combined_hash
		combined_hash="$(mcp_hash_string "${MCP_TOOLS_REGISTRY_HASH}|${fastpath_snapshot}")"
		MCP_TOOLS_REGISTRY_HASH="${combined_hash}"
		MCP_TOOLS_REGISTRY_JSON="$(printf '%s' "${MCP_TOOLS_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" --arg hash "${combined_hash}" '.hash = $hash')"
		local write_rc=0
		mcp_registry_write_with_lock "${MCP_TOOLS_REGISTRY_PATH}" "${MCP_TOOLS_REGISTRY_JSON}" || write_rc=$?
		if [ "${write_rc}" -ne 0 ]; then
			return "${write_rc}"
		fi
	fi
	if [ "${previous_hash}" != "${MCP_TOOLS_REGISTRY_HASH}" ]; then
		MCP_TOOLS_CHANGED=true
	fi
}

mcp_tools_scan() {
	local scan_root="${1:-${MCPBASH_TOOLS_DIR}}"
	local items_file
	items_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-tools-items.XXXXXX")"

	if [ -d "${scan_root}" ]; then
		find "${scan_root}" -type f ! -name ".*" ! -name "*.meta.json" 2>/dev/null | sort | while read -r path; do
			# On Windows (Git Bash/MSYS), -x test is unreliable. Check for shebang or .sh extension as fallback.
			if [ ! -x "${path}" ]; then
				# Fallback: check if file has shebang or is .sh/.bash
				if [[ ! "${path}" =~ \.(sh|bash)$ ]] && ! head -n1 "${path}" 2>/dev/null | grep -q '^#!'; then
					continue
				fi
			fi
			local rel_path="${path#"${MCPBASH_TOOLS_DIR}"/}"
			# Enforce per-tool subdirectories under tools/ (ignore root-level scripts)
			case "${rel_path}" in
			*/*) ;;
			*) continue ;;
			esac
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
				# Read fields individually to avoid collapsing empty columns
				local j_name
				j_name="$("${MCPBASH_JSON_TOOL_BIN}" -r '.name // ""' "${meta_json}" 2>/dev/null || printf '')"
				[ -n "${j_name}" ] && name="${j_name}"
				description="$("${MCPBASH_JSON_TOOL_BIN}" -r '.description // ""' "${meta_json}" 2>/dev/null || printf '')"
				arguments="$("${MCPBASH_JSON_TOOL_BIN}" -c '.inputSchema // .arguments // {type:"object",properties:{}}' "${meta_json}" 2>/dev/null || printf '{}')"
				timeout="$("${MCPBASH_JSON_TOOL_BIN}" -r '.timeoutSecs // ""' "${meta_json}" 2>/dev/null || printf '')"
				output_schema="$("${MCPBASH_JSON_TOOL_BIN}" -c '.outputSchema // null' "${meta_json}" 2>/dev/null || printf 'null')"
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
					timeoutSecs: (if ($timeout|test("^[0-9]+$")) then ($timeout|tonumber) else null end)
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
	hash="$(mcp_hash_string "${items_json}")"

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

	if mcp_logging_is_enabled "debug"; then
		mcp_logging_debug "${MCP_TOOLS_LOGGER}" "Refresh count=${MCP_TOOLS_TOTAL} hash=${MCP_TOOLS_REGISTRY_HASH}"
	fi

	if ! mcp_tools_enforce_registry_limits "${MCP_TOOLS_TOTAL}" "${MCP_TOOLS_REGISTRY_JSON}"; then
		return 1
	fi

	local write_rc=0
	mcp_registry_write_with_lock "${MCP_TOOLS_REGISTRY_PATH}" "${MCP_TOOLS_REGISTRY_JSON}" || write_rc=$?
	if [ "${write_rc}" -ne 0 ]; then
		return "${write_rc}"
	fi
}

mcp_tools_consume_notification() {
	local actually_emit="${1:-true}"
	local current_hash="${MCP_TOOLS_REGISTRY_HASH}"
	_MCP_NOTIFICATION_PAYLOAD=""

	if [ -z "${current_hash}" ]; then
		return 0
	fi

	if [ "${MCP_TOOLS_CHANGED}" != "true" ]; then
		return 0
	fi

	if [ "${actually_emit}" = "true" ]; then
		# shellcheck disable=SC2034  # stored for next consume call
		MCP_TOOLS_LAST_NOTIFIED_HASH="${current_hash}"
		MCP_TOOLS_CHANGED=false
		_MCP_NOTIFICATION_PAYLOAD='{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{}}'
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
	# Args:
	#   limit  - optional max items per page (stringified number).
	#   cursor - opaque pagination cursor from previous response.
	# Note: The MCP schema for ListToolsResult requires a `tools` array and
	# allows additional properties. We include a `total` field as a
	# spec-compliant extension so clients can see the full count without
	# extra round trips; strict clients may ignore it safely.
	# shellcheck disable=SC2034
	_MCP_TOOLS_ERROR_CODE=0
	# shellcheck disable=SC2034
	_MCP_TOOLS_ERROR_MESSAGE=""
	# shellcheck disable=SC2034
	_MCP_TOOLS_ERROR_DATA=""

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

	local total="${MCP_TOOLS_TOTAL}"
	local result_json
	result_json="$(echo "${MCP_TOOLS_REGISTRY_JSON}" | "${MCPBASH_JSON_TOOL_BIN}" -c --argjson offset "${offset}" --argjson limit "${numeric_limit}" --argjson total "${total}" '
		{
			tools: .items[$offset:$offset+$limit],
			total: $total
		}
	')"

	if ! result_json="$(mcp_paginate_attach_next_cursor "${result_json}" "tools" "${offset}" "${numeric_limit}" "${total}" "${MCP_TOOLS_REGISTRY_HASH}")"; then
		mcp_tools_error -32603 "Unable to encode tools cursor"
		return 1
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

# shellcheck disable=SC2031  # Subshell env exports are deliberate; parent values remain unchanged.
mcp_tools_call() {
	local name="$1"
	local args_json="$2"
	local timeout_override="$3"
	# Args:
	#   name             - tool name as registered.
	#   args_json        - JSON string of parameters (object shape, possibly "{}").
	#   timeout_override - optional numeric seconds to override metadata timeout.
	# shellcheck disable=SC2034
	_MCP_TOOLS_ERROR_CODE=0
	# shellcheck disable=SC2034
	_MCP_TOOLS_ERROR_MESSAGE=""
	# shellcheck disable=SC2034
	_MCP_TOOLS_ERROR_DATA=""
	# shellcheck disable=SC2034
	_MCP_TOOLS_RESULT=""

	local metadata
	if ! metadata="$(mcp_tools_metadata_for_name "${name}")"; then
		mcp_tools_error -32601 "Tool not found"
		return 1
	fi

	local tool_path metadata_timeout output_schema
	tool_path="$(printf '%s' "${metadata}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.path // ""')"
	metadata_timeout="$(printf '%s' "${metadata}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.timeoutSecs // "" | tostring')"
	output_schema="$(printf '%s' "${metadata}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.outputSchema // null')"
	case "${metadata_timeout}" in
	"" | "null") metadata_timeout="" ;;
	esac
	case "${output_schema}" in
	"" | "null") output_schema="null" ;;
	esac
	if [ -z "${tool_path}" ]; then
		mcp_tools_error -32601 "Tool path unavailable"
		return 1
	fi

	# Warn once per process when running in inherit mode, since tools then
	# receive the full host environment including any secrets present.
	local env_mode_raw="${MCPBASH_TOOL_ENV_MODE:-minimal}"
	local env_mode_lc
	env_mode_lc="$(printf '%s' "${env_mode_raw}" | tr '[:upper:]' '[:lower:]')"
	if [ "${env_mode_lc}" = "inherit" ] && [ "${MCPBASH_TOOL_ENV_INHERIT_WARNED}" != "true" ]; then
		MCPBASH_TOOL_ENV_INHERIT_WARNED="true"
		mcp_logging_warning "${MCP_TOOLS_LOGGER}" "MCPBASH_TOOL_ENV_MODE=inherit; tools receive the full host environment"
	fi

	local absolute_path="${MCPBASH_TOOLS_DIR}/${tool_path}"
	local tool_runner=("${absolute_path}")
	# On Windows (Git Bash/MSYS), -x test is unreliable. Check for shebang or .sh extension as fallback.
	if [ ! -x "${absolute_path}" ]; then
		if [[ ! "${absolute_path}" =~ \.(sh|bash)$ ]] && ! head -n1 "${absolute_path}" 2>/dev/null | grep -q '^#!'; then
			mcp_tools_error -32601 "Tool executable missing"
			return 1
		fi
		# Fallback: invoke via shell if not marked executable but looks runnable
		tool_runner=(bash "${absolute_path}")
	fi

	local env_limit="${MCPBASH_ENV_PAYLOAD_THRESHOLD:-65536}"
	case "${env_limit}" in
	'' | *[!0-9]*) env_limit=65536 ;;
	0) env_limit=65536 ;;
	esac

	# Roots environment (blocks until roots ready when available)
	local MCP_ROOTS_JSON MCP_ROOTS_PATHS MCP_ROOTS_COUNT
	if declare -F mcp_roots_wait_ready >/dev/null 2>&1; then
		mcp_roots_wait_ready
		MCP_ROOTS_JSON="$(mcp_roots_get_json)"
		MCP_ROOTS_PATHS="$(mcp_roots_get_paths)"
		MCP_ROOTS_COUNT="${#MCPBASH_ROOTS_PATHS[@]}"
	fi

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

	local tool_error_file
	tool_error_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-tool-error.XXXXXX")"

	local effective_timeout="${timeout_override}"
	if [ -z "${effective_timeout}" ] && [ -n "${metadata_timeout}" ]; then
		effective_timeout="${metadata_timeout}"
	fi
	case "${effective_timeout}" in
	'' | *[!0-9]*) effective_timeout="" ;;
	esac

	if mcp_logging_is_enabled "debug"; then
		local arg_count=0
		if [ -n "${args_json}" ] && [ "${args_json}" != "{}" ]; then
			arg_count="$(printf '%s' "${args_json}" | "${MCPBASH_JSON_TOOL_BIN}" -r 'keys | length' 2>/dev/null || echo 0)"
		fi
		mcp_logging_debug "${MCP_TOOLS_LOGGER}" "Invoke tool=${name} arg_count=${arg_count} timeout=${effective_timeout:-none}"
		if mcp_logging_verbose_enabled; then
			mcp_logging_debug "${MCP_TOOLS_LOGGER}" "Tool path=${absolute_path}"
		fi
	fi

	local stdout_file stderr_file
	stdout_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-tools-stdout.XXXXXX")"
	stderr_file="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-tools-stderr.XXXXXX")"

	local has_json_tool="false"
	if [ "${MCPBASH_MODE}" != "minimal" ] && [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
		has_json_tool="true"
	fi
	local stream_stderr="${MCPBASH_TOOL_STREAM_STDERR:-false}"

	# Tool invocation lifecycle:
	# 1) Build an isolated env (respecting allowlist/minimal/inherit) and ship
	#    args/metadata via env or temp files to avoid huge env blobs.
	# 2) Run the tool with optional timeout and collect stdout/stderr into temp
	#    files so we can post-process them safely.
	# 3) Prefer structured errors emitted by the tool, enforce size limits, then
	#    validate outputSchema and produce the structured MCP response object.
	# Elicitation environment
	local elicit_supported="0"
	local elicit_request_file=""
	local elicit_response_file=""
	local elicit_key="${MCPBASH_WORKER_KEY:-${key:-}}"
	if declare -F mcp_elicitation_is_supported >/dev/null 2>&1 && [ -n "${elicit_key}" ]; then
		if mcp_elicitation_is_supported; then
			elicit_supported="1"
			elicit_request_file="$(mcp_elicitation_request_path_for_worker "${elicit_key}")"
			elicit_response_file="$(mcp_elicitation_response_path_for_worker "${elicit_key}")"
			rm -f "${elicit_request_file}" "${elicit_response_file}"
		fi
	fi
	if mcp_logging_is_enabled "debug"; then
		mcp_logging_debug "${MCP_TOOLS_LOGGER}" "Elicitation env supported=${elicit_supported} request=${elicit_request_file:-none} response=${elicit_response_file:-none}"
	fi

	cleanup_tool_temp_files() {
		# Preserve temp files when debugging so we can inspect tool I/O.
		if [ "${MCPBASH_PRESERVE_STATE:-}" = "true" ]; then
			return 0
		fi
		rm -f "${stdout_file}" "${stderr_file}"
		[ -n "${tool_error_file}" ] && rm -f "${tool_error_file}"
		[ -n "${args_file}" ] && rm -f "${args_file}"
		[ -n "${metadata_file}" ] && rm -f "${metadata_file}"
	}

	local exit_code
	# shellcheck disable=SC2030,SC2031,SC2094
	(
		# Environment mutations here are intentionally scoped to this subshell.
		# Ignore SIGTERM in this subshell - only the tool process should be killed
		# The tool runs in its own process via with_timeout, which handles the signal
		trap '' TERM
		set -o pipefail
		cd "${MCPBASH_PROJECT_ROOT}" || exit 1
		MCP_SDK="${MCPBASH_HOME}/sdk"
		MCP_TOOL_NAME="${name}"
		MCP_TOOL_PATH="${absolute_path}"
		MCP_TOOL_ARGS_JSON="${args_env_value}"
		MCP_TOOL_METADATA_JSON="${metadata_env_value}"
		MCP_TOOL_ERROR_FILE="${tool_error_file}"
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

		local tool_env_mode
		tool_env_mode="$(printf '%s' "${MCPBASH_TOOL_ENV_MODE:-minimal}" | tr '[:upper:]' '[:lower:]')"
		case " ${tool_env_mode} " in
		" inherit " | " minimal " | " allowlist ") ;;
		*) tool_env_mode="minimal" ;;
		esac

		local env_exec=()
		if [ "${tool_env_mode}" != "inherit" ]; then
			env_exec=(
				env -i
				"PATH=${PATH:-/usr/bin:/bin}"
				"HOME=${HOME:-${MCPBASH_PROJECT_ROOT:-${PWD}}}"
				"TMPDIR=${TMPDIR:-/tmp}"
				"LANG=${LANG:-C}"
			)
			local env_line env_key env_value
			while IFS= read -r env_line || [ -n "${env_line}" ]; do
				[ -z "${env_line}" ] && continue
				env_key="${env_line%%=*}"
				env_value="${env_line#*=}"
				case "${env_key}" in
				MCP_* | MCPBASH_*)
					env_exec+=("${env_key}=${env_value}")
					;;
				esac
			done < <(env)

			env_exec+=(
				"MCP_SDK=${MCP_SDK}"
				"MCP_TOOL_NAME=${MCP_TOOL_NAME}"
				"MCP_TOOL_PATH=${MCP_TOOL_PATH}"
				"MCP_TOOL_ARGS_JSON=${MCP_TOOL_ARGS_JSON}"
				"MCP_TOOL_METADATA_JSON=${MCP_TOOL_METADATA_JSON}"
				"MCP_TOOL_ERROR_FILE=${MCP_TOOL_ERROR_FILE}"
				"MCP_ELICIT_SUPPORTED=${elicit_supported}"
				"MCPBASH_JSON_TOOL=${MCPBASH_JSON_TOOL:-}"
				"MCPBASH_JSON_TOOL_BIN=${MCPBASH_JSON_TOOL_BIN:-}"
				"MCPBASH_MODE=${MCPBASH_MODE:-full}"
			)
			if declare -F mcp_roots_wait_ready >/dev/null 2>&1; then
				env_exec+=("MCP_ROOTS_JSON=${MCP_ROOTS_JSON:-[]}")
				env_exec+=("MCP_ROOTS_PATHS=${MCP_ROOTS_PATHS:-}")
				env_exec+=("MCP_ROOTS_COUNT=${MCP_ROOTS_COUNT:-0}")
			fi
			[ -n "${MCP_TOOL_ARGS_FILE:-}" ] && env_exec+=("MCP_TOOL_ARGS_FILE=${MCP_TOOL_ARGS_FILE}")
			[ -n "${MCP_TOOL_METADATA_FILE:-}" ] && env_exec+=("MCP_TOOL_METADATA_FILE=${MCP_TOOL_METADATA_FILE}")
			if [ "${elicit_supported}" = "1" ]; then
				env_exec+=("MCP_ELICIT_REQUEST_FILE=${elicit_request_file}")
				env_exec+=("MCP_ELICIT_RESPONSE_FILE=${elicit_response_file}")
			fi

			if [ "${tool_env_mode}" = "allowlist" ]; then
				local allowlist_raw allowlist_var allowlist_value
				allowlist_raw="${MCPBASH_TOOL_ENV_ALLOWLIST:-}"
				allowlist_raw="${allowlist_raw//,/ }"
				for allowlist_var in ${allowlist_raw}; do
					[ -n "${allowlist_var}" ] || continue
					allowlist_value="${!allowlist_var:-}"
					[ -n "${allowlist_value}" ] || continue
					env_exec+=("${allowlist_var}=${allowlist_value}")
				done
			fi
		else
			export MCP_SDK MCP_TOOL_NAME MCP_TOOL_PATH MCP_TOOL_ARGS_JSON MCP_TOOL_METADATA_JSON
			[ -n "${MCP_TOOL_ARGS_FILE:-}" ] && export MCP_TOOL_ARGS_FILE
			[ -n "${MCP_TOOL_METADATA_FILE:-}" ] && export MCP_TOOL_METADATA_FILE
			export MCP_TOOL_ERROR_FILE
			export MCP_ELICIT_SUPPORTED="${elicit_supported}"
			export MCPBASH_JSON_TOOL="${MCPBASH_JSON_TOOL:-}"
			export MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN:-}"
			export MCPBASH_MODE="${MCPBASH_MODE:-full}"
			if [ "${elicit_supported}" = "1" ]; then
				export MCP_ELICIT_REQUEST_FILE="${elicit_request_file}"
				export MCP_ELICIT_RESPONSE_FILE="${elicit_response_file}"
			fi
			if declare -F mcp_roots_wait_ready >/dev/null 2>&1; then
				export MCP_ROOTS_JSON="${MCP_ROOTS_JSON:-[]}"
				export MCP_ROOTS_PATHS="${MCP_ROOTS_PATHS:-}"
				export MCP_ROOTS_COUNT="${MCP_ROOTS_COUNT:-0}"
			fi
		fi

		# Helper to execute the tool with optional streaming; retries without streaming if process substitution fails.
		run_with_stderr_streaming() {
			if ! "$@"; then
				# If streaming failed (e.g., process substitution unavailable), retry without streaming and append a note.
				printf 'stream-stderr unavailable; retrying without streaming\n' >>"${stderr_file}"
				return 1
			fi
			return 0
		}

		if [ -n "${effective_timeout}" ]; then
			if [ "${tool_env_mode}" != "inherit" ]; then
				if [ "${stream_stderr}" = "true" ]; then
					if ! run_with_stderr_streaming with_timeout "${effective_timeout}" -- "${env_exec[@]}" "${tool_runner[@]}" 2> >(tee "${stderr_file}" >&2); then
						with_timeout "${effective_timeout}" -- "${env_exec[@]}" "${tool_runner[@]}" 2>"${stderr_file}"
					fi
				else
					with_timeout "${effective_timeout}" -- "${env_exec[@]}" "${tool_runner[@]}" 2>"${stderr_file}"
				fi
			else
				if [ "${stream_stderr}" = "true" ]; then
					if ! run_with_stderr_streaming with_timeout "${effective_timeout}" -- "${tool_runner[@]}" 2> >(tee "${stderr_file}" >&2); then
						with_timeout "${effective_timeout}" -- "${tool_runner[@]}" 2>"${stderr_file}"
					fi
				else
					with_timeout "${effective_timeout}" -- "${tool_runner[@]}" 2>"${stderr_file}"
				fi
			fi
		else
			if [ "${tool_env_mode}" != "inherit" ]; then
				if [ "${stream_stderr}" = "true" ]; then
					if ! run_with_stderr_streaming "${env_exec[@]}" "${tool_runner[@]}" 2> >(tee "${stderr_file}" >&2); then
						"${env_exec[@]}" "${tool_runner[@]}" 2>"${stderr_file}"
					fi
				else
					"${env_exec[@]}" "${tool_runner[@]}" 2>"${stderr_file}"
				fi
			else
				if [ "${stream_stderr}" = "true" ]; then
					if ! run_with_stderr_streaming "${tool_runner[@]}" 2> >(tee "${stderr_file}" >&2); then
						"${tool_runner[@]}" 2>"${stderr_file}"
					fi
				else
					"${tool_runner[@]}" 2>"${stderr_file}"
				fi
			fi
		fi
	) >"${stdout_file}" 2>>"${stderr_file}" || exit_code=$?
	exit_code=${exit_code:-0}

	if mcp_logging_is_enabled "debug"; then
		local stdout_size=0
		[ -f "${stdout_file}" ] && stdout_size="$(wc -c <"${stdout_file}" | tr -d ' ')"
		mcp_logging_debug "${MCP_TOOLS_LOGGER}" "Complete tool=${name} exit=${exit_code} stdout_bytes=${stdout_size}"
	fi

	# Prefer explicit tool-authored errors as early as possible.
	if [ -n "${tool_error_file}" ] && [ -s "${tool_error_file}" ]; then
		local tool_error_raw parsed_tool_error
		tool_error_raw="$(cat "${tool_error_file}" 2>/dev/null || true)"
		if [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
			parsed_tool_error="$(
				printf '%s' "${tool_error_raw}" | "${MCPBASH_JSON_TOOL_BIN}" -c '
					select(
						(.code | type) == "number"
						and (.code | floor) == (.code | tonumber)
						and (.message | type) == "string"
					)
					| {code: (.code | tonumber), message: .message, data: (.data // null)}
				' 2>/dev/null || true
			)"
		fi
		if [ -n "${parsed_tool_error}" ]; then
			local te_code te_message te_data
			te_code="$(printf '%s' "${parsed_tool_error}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.code')"
			te_message="$(printf '%s' "${parsed_tool_error}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.message')"
			te_data="$(printf '%s' "${parsed_tool_error}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.data')"
			_mcp_tools_emit_error "${te_code}" "${te_message}" "${te_data}"
		else
			_mcp_tools_emit_error -32603 "Tool failed" "$(printf '%s' "${tool_error_raw}" | "${MCPBASH_JSON_TOOL_BIN}" -Rs '.' 2>/dev/null || printf '"%s"' "${tool_error_raw//\"/\\\"}")"
		fi
		cleanup_tool_temp_files
		return 1
	fi

	set +e

	local limit="${MCPBASH_MAX_TOOL_OUTPUT_SIZE:-10485760}"
	case "${limit}" in
	'' | *[!0-9]*) limit=10485760 ;;
	esac
	local stdout_size
	stdout_size="$(wc -c <"${stdout_file}" | tr -d ' ')"
	if [ "${stdout_size}" -gt "${limit}" ]; then
		mcp_logging_error "${MCP_TOOLS_LOGGER}" "Tool ${name} output ${stdout_size} bytes exceeds limit ${limit}" || true
		_mcp_tools_emit_error -32603 "Tool output exceeded ${limit} bytes" "null"
		cleanup_tool_temp_files
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
		_mcp_tools_emit_error -32603 "Tool stderr exceeded ${stderr_limit} bytes" "null"
		cleanup_tool_temp_files
		return 1
	fi
	stderr_content="${stderr_file}"
	stdout_content="${stdout_file}"

	local cancelled_flag="false"
	if [ -n "${MCP_CANCEL_FILE:-}" ] && [ -f "${MCP_CANCEL_FILE}" ]; then
		cancelled_flag="true"
	fi

	local timed_out="false"
	if [ -n "${effective_timeout}" ]; then
		case "${exit_code}" in
		124 | 137)
			timed_out="true"
			;;
		143)
			if [ "${cancelled_flag}" != "true" ]; then
				timed_out="true"
			fi
			;;
		esac
	fi

	if [ "${cancelled_flag}" = "true" ]; then
		_mcp_tools_emit_error -32001 "Tool cancelled" "null"
		cleanup_tool_temp_files
		return 1
	fi

	if [ "${timed_out}" = "true" ]; then
		_mcp_tools_emit_error -32603 "Tool timed out" "null"
		cleanup_tool_temp_files
		return 1
	fi

	local tool_error_raw=""
	if [ -n "${tool_error_file}" ] && [ -e "${tool_error_file}" ]; then
		tool_error_raw="$(cat "${tool_error_file}" 2>/dev/null || true)"
	fi

	if [ -n "${tool_error_raw}" ]; then
		mcp_logging_debug "${MCP_TOOLS_LOGGER}" "Tool ${name} emitted structured error ${tool_error_raw}" || true
		if [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
			local parsed
			parsed="$(
				printf '%s' "${tool_error_raw}" | "${MCPBASH_JSON_TOOL_BIN}" -c '
					select(
						(.code | type) == "number"
						and (.code | floor) == (.code | tonumber)
						and (.message | type) == "string"
					)
					| {code: (.code | tonumber), message: .message, data: (.data // null)}
				' 2>/dev/null || true
			)"
			if [ -n "${parsed}" ]; then
				local tool_err_code tool_err_message tool_err_data
				tool_err_code="$(printf '%s' "${parsed}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.code')"
				tool_err_message="$(printf '%s' "${parsed}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.message')"
				tool_err_data="$(printf '%s' "${parsed}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.data')"
				_mcp_tools_emit_error "${tool_err_code}" "${tool_err_message}" "${tool_err_data}"
				cleanup_tool_temp_files
				return 1
			fi
		fi
		_mcp_tools_emit_error -32603 "Tool failed" "$(printf '%s' "${tool_error_raw}" | "${MCPBASH_JSON_TOOL_BIN}" -Rs '.' 2>/dev/null || printf '"%s"' "${tool_error_raw//\"/\\\"}")"
		cleanup_tool_temp_files
		return 1
	fi

	if [ "${exit_code}" -ne 0 ]; then
		local stderr_preview message_from_stderr data_json="" stdout_error_json="" stdout_raw=""
		if [ -s "${stdout_content}" ]; then
			stdout_raw="$(cat "${stdout_content}")"
			if [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
				stdout_error_json="$(
					printf '%s' "${stdout_raw}" | "${MCPBASH_JSON_TOOL_BIN}" -c '
						select(
							(.code | type) == "number"
							and (.code | floor) == (.code | tonumber)
							and (.message | type) == "string"
						)
						| {code: (.code | tonumber), message: .message, data: (.data // null)}
					' 2>/dev/null || true
				)"
			fi
			if [ -n "${stdout_error_json}" ]; then
				local err_code err_message err_data
				err_code="$(printf '%s' "${stdout_error_json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.code')"
				err_message="$(printf '%s' "${stdout_error_json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.message')"
				err_data="$(printf '%s' "${stdout_error_json}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.data')"
				_mcp_tools_emit_error "${err_code}" "${err_message}" "${err_data}"
				cleanup_tool_temp_files
				return 1
			fi
			if [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
				local err_code_simple err_message_simple err_data_simple
				err_code_simple="$(printf '%s' "${stdout_raw}" | "${MCPBASH_JSON_TOOL_BIN}" -r '(.code // "")' 2>/dev/null || true)"
				err_message_simple="$(printf '%s' "${stdout_raw}" | "${MCPBASH_JSON_TOOL_BIN}" -r '(.message // "")' 2>/dev/null || true)"
				err_data_simple="$(printf '%s' "${stdout_raw}" | "${MCPBASH_JSON_TOOL_BIN}" -c '(.data // null)' 2>/dev/null || true)"
				if [ -n "${err_code_simple}" ] && [ -n "${err_message_simple}" ]; then
					_mcp_tools_emit_error "${err_code_simple}" "${err_message_simple}" "${err_data_simple:-null}"
					cleanup_tool_temp_files
					return 1
				fi
			fi
			local err_code_guess err_message_guess
			err_code_guess="$(printf '%s' "${stdout_raw}" | sed -n 's/.*\"code\"[[:space:]]*:[[:space:]]*\\([-0-9]*\\).*/\\1/p' | head -n 1)"
			err_message_guess="$(printf '%s' "${stdout_raw}" | sed -n 's/.*\"message\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p' | head -n 1)"
			if [ -n "${err_code_guess}" ] && [ -n "${err_message_guess}" ]; then
				local data_escaped
				data_escaped="$(printf '%s' "${stdout_raw}" | "${MCPBASH_JSON_TOOL_BIN}" -Rs '.' 2>/dev/null || printf '"%s"' "${stdout_raw//\"/\\\"}")"
				_mcp_tools_emit_error "${err_code_guess}" "${err_message_guess}" "${data_escaped}"
				cleanup_tool_temp_files
				return 1
			fi
			if [ -n "${stdout_raw}" ]; then
				local data_escaped
				data_escaped="$(printf '%s' "${stdout_raw}" | "${MCPBASH_JSON_TOOL_BIN}" -Rs '.' 2>/dev/null || printf '"%s"' "${stdout_raw//\"/\\\"}")"
				_mcp_tools_emit_error -32603 "Tool failed" "${data_escaped}"
				cleanup_tool_temp_files
				return 1
			fi
		fi

		stderr_preview="$(head -c 2048 "${stderr_content}" | tr -d '\0')"
		message_from_stderr="$(printf '%s' "${stderr_preview}" | head -n 1 | tr -d '\r')"
		if [ -z "${message_from_stderr}" ]; then
			message_from_stderr="Tool failed"
		fi
		data_json="null"
		if [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
			data_json="$(
				"${MCPBASH_JSON_TOOL_BIN}" -n \
					--argjson code "${exit_code}" \
					--arg stderr "${stderr_preview}" \
					'
					{
						_meta: ({exitCode: $code} + (if ($stderr|length) > 0 then {stderr: $stderr} else {} end))
					}
				'
			)"
		fi
		_mcp_tools_emit_error -32603 "${message_from_stderr}" "${data_json}"
		cleanup_tool_temp_files
		return 1
	fi

	set -e

	if ! mcp_tools_validate_output_schema "${stdout_content}" "${output_schema}" "${has_json_tool}"; then
		cleanup_tool_temp_files
		return 1
	fi

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

	cleanup_tool_temp_files

	_MCP_TOOLS_RESULT="${result_json}"
}
