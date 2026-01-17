#!/usr/bin/env bash
# Tools handler implementation.
# Error responses use JSON-RPC 2.0 codes (for example, -32601 method not found,
# -32602 invalid params, -32603 internal error).

set -euo pipefail

mcp_tools_extract_call_fields() {
	# Extract name, arguments (compact JSON), timeoutSecs, and _meta.
	# Uses separate jq calls to avoid @tsv double-escaping backslashes which
	# corrupts JSON containing escaped quotes (e.g., Status in ["New", "Intro"]).
	# See: docs/internal/PLAN-silent-args-parsing-failures.md
	local json_payload="$1"
	local name args_json timeout_override meta_json

	name="$(printf '%s' "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.params.name // ""' 2>/dev/null)" || name=""
	args_json="$(printf '%s' "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.params.arguments // {}' 2>/dev/null)" || args_json="{}"
	timeout_override="$(printf '%s' "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r '(.params.timeoutSecs // null) | tostring' 2>/dev/null)" || timeout_override="null"
	meta_json="$(printf '%s' "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.params._meta // {}' 2>/dev/null)" || meta_json="{}"

	# Output tab-separated (no @tsv escaping - direct printf)
	printf '%s\t%s\t%s\t%s' "${name}" "${args_json}" "${timeout_override}" "${meta_json}"
}

mcp_handle_tools() {
	local method="$1"
	local json_payload="$2"
	local id
	if ! id="$(mcp_json_extract_id "${json_payload}")"; then
		id="null"
	fi

	if mcp_runtime_is_minimal_mode; then
		local message
		message=$(mcp_json_quote_text "Tools capability unavailable in minimal mode")
		mcp_handler_error_response "${id}" "-32601" "${message}"
		return 0
	fi

	case "${method}" in
	tools/list)
		local limit cursor
		limit="$(mcp_json_extract_limit "${json_payload}")"
		cursor="$(mcp_json_extract_cursor "${json_payload}")"
		local list_json
		if ! list_json="$(mcp_tools_list "${limit}" "${cursor}")"; then
			local code
			code="$(mcp_handler_normalize_error_code "${_MCP_TOOLS_ERROR_CODE:-}")"
			local message
			message=$(mcp_json_quote_text "${_MCP_TOOLS_ERROR_MESSAGE:-Unable to list tools}")
			local data="${_MCP_TOOLS_ERROR_DATA:-}"
			mcp_handler_error_response "${id}" "${code}" "${message}" "${data}"
			return 0
		fi
		mcp_handler_success_response "${id}" "${list_json}"
		if mcp_logging_is_enabled "debug"; then
			mcp_logging_debug "${MCP_TOOLS_LOGGER}" "List count=${MCP_TOOLS_TOTAL}"
		fi
		;;
	tools/call)
		local name args_json timeout_override meta_json
		# Extract fields in one JSON-tool pass; keep args and _meta as compact JSON
		extraction="$(mcp_tools_extract_call_fields "${json_payload}")"
		IFS=$'\t' read -r name args_json timeout_override meta_json <<<"${extraction}"
		[ -z "${args_json}" ] && args_json="{}"
		[ -z "${meta_json}" ] && meta_json="{}"
		# Normalize "null" placeholders to empty strings
		[ "${timeout_override}" = "null" ] && timeout_override=""

		if [ -z "${name}" ]; then
			local message
			message=$(mcp_json_quote_text "Tool name is required")
			mcp_handler_error_response "${id}" "-32602" "${message}"
			return 0
		fi
		local result_json
		if ! mcp_tools_call "${name}" "${args_json}" "${timeout_override}" "${meta_json}"; then
			result_json="${_MCP_TOOLS_RESULT:-}"
			# Parse error info from stdout (mcp_tools_call emits error JSON on failure)
			local code=-32603 message_raw="Tool execution failed" data="null"
			if [ -n "${result_json}" ] && [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
				# Check if it's a tool error object with _mcpToolError marker
				local is_tool_error
				is_tool_error="$(printf '%s' "${result_json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '._mcpToolError // empty' 2>/dev/null || true)"
				if [ "${is_tool_error}" = "true" ]; then
					code="$(printf '%s' "${result_json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.code // -32603')"
					message_raw="$(printf '%s' "${result_json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.message // "Tool execution failed"')"
					data="$(printf '%s' "${result_json}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.data // null')"
				fi
			fi
			# Normalize code
			code="$(mcp_handler_normalize_error_code "${code}")"
			local message
			message=$(mcp_json_quote_text "${message_raw}")
			mcp_logging_debug "${MCP_TOOLS_LOGGER}" "tools/call error code=${code} message=${message_raw} data=${data:-<unset>}" || true
			mcp_handler_error_response "${id}" "${code}" "${message}" "${data}"
			return 0
		fi
		result_json="${_MCP_TOOLS_RESULT}"
		mcp_handler_success_response "${id}" "${result_json}"
		;;
	*)
		local message
		message=$(mcp_json_quote_text "Unknown tools method")
		mcp_handler_error_response "${id}" "-32601" "${message}"
		;;
	esac
}
