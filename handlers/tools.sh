#!/usr/bin/env bash
# Tools handler implementation.
# Error responses use JSON-RPC 2.0 codes (for example, -32601 method not found,
# -32602 invalid params, -32603 internal error).

set -euo pipefail

mcp_tools_quote() {
	local text="$1"
	mcp_json_quote_text "${text}"
}

mcp_tools_extract_call_fields() {
	# Extract name, arguments (compact JSON), and timeoutSecs in a single jq/gojq pass.
	local json_payload="$1"
	local extraction
	if extraction="$(
		{ printf '%s' "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r '
			[
				(.params.name // ""),
				((.params.arguments // {}) | tojson),
				((.params.timeoutSecs // "") | tostring)
			] | @tsv
		'; } 2>/dev/null
	)"; then
		printf '%s' "${extraction}"
	else
		# Fallback: empty fields so caller can apply defaults/validation.
		printf '\t\t'
	fi
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
		message=$(mcp_tools_quote "Tools capability unavailable in minimal mode")
		printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":%s}}' "${id}" "${message}"
		return 0
	fi

	case "${method}" in
	tools/list)
		local limit cursor
		limit="$(mcp_json_extract_limit "${json_payload}")"
		cursor="$(mcp_json_extract_cursor "${json_payload}")"
		local list_json
		if ! list_json="$(mcp_tools_list "${limit}" "${cursor}")"; then
			local code="${_MCP_TOOLS_ERROR_CODE:--32603}"
			case "${code}" in
			0 | "") code=-32603 ;;
			esac
			local message
			message=$(mcp_tools_quote "${_MCP_TOOLS_ERROR_MESSAGE:-Unable to list tools}")
			local data="${_MCP_TOOLS_ERROR_DATA:-}"
			if [ -n "${data}" ]; then
				printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%s,"message":%s,"data":%s}}' "${id}" "${code}" "${message}" "${data}"
			else
				printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%s,"message":%s}}' "${id}" "${code}" "${message}"
			fi
			return 0
		fi
		printf '{"jsonrpc":"2.0","id":%s,"result":%s}' "${id}" "${list_json}"
		if mcp_logging_is_enabled "debug"; then
			mcp_logging_debug "${MCP_TOOLS_LOGGER}" "List count=${MCP_TOOLS_TOTAL}"
		fi
		;;
	tools/call)
		local name args_json timeout_override
		# Extract fields in one JSON-tool pass; keep args as compact JSON
		extraction="$(mcp_tools_extract_call_fields "${json_payload}")"
		IFS=$'\t' read -r name args_json timeout_override <<<"${extraction}"
		[ -z "${args_json}" ] && args_json="{}"

		if [ -z "${name}" ]; then
			local message
			message=$(mcp_tools_quote "Tool name is required")
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32602,"message":%s}}' "${id}" "${message}"
			return 0
		fi
		local result_json
		if ! mcp_tools_call "${name}" "${args_json}" "${timeout_override}"; then
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
			case "${code}" in
			0 | "" | "null") code=-32603 ;;
			esac
			local message
			message=$(mcp_tools_quote "${message_raw}")
			mcp_logging_debug "${MCP_TOOLS_LOGGER}" "tools/call error code=${code} message=${message_raw} data=${data:-<unset>}" || true
			if [ -n "${data}" ] && [ "${data}" != "null" ]; then
				printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%s,"message":%s,"data":%s}}' "${id}" "${code}" "${message}" "${data}"
			else
				printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%s,"message":%s}}' "${id}" "${code}" "${message}"
			fi
			return 0
		fi
		result_json="${_MCP_TOOLS_RESULT}"
		printf '{"jsonrpc":"2.0","id":%s,"result":%s}' "${id}" "${result_json}"
		;;
	*)
		local message
		message=$(mcp_tools_quote "Unknown tools method")
		printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":%s}}' "${id}" "${message}"
		;;
	esac
}
