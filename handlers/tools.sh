#!/usr/bin/env bash
# Spec §8/§9 tools handler implementation.

set -euo pipefail

mcp_tools_quote() {
	local text="$1"
	local py
	if py="$(mcp_tools_python 2>/dev/null)"; then
		TEXT="${text}" "${py}" <<'PY'
import json, os
print(json.dumps(os.environ.get("TEXT", "")))
PY
	else
		printf '"%s"' "$(printf '%s' "${text}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
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
			local code="${MCP_TOOLS_ERROR_CODE:- -32603}"
			local message
			message=$(mcp_tools_quote "${MCP_TOOLS_ERROR_MESSAGE:-Unable to list tools}")
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%s,"message":%s}}' "${id}" "${code}" "${message}"
			return 0
		fi
		printf '{"jsonrpc":"2.0","id":%s,"result":%s}' "${id}" "${list_json}"
		;;
	tools/call)
		local name args_json timeout_override
		name="$(mcp_json_extract_tool_name "${json_payload}")"
		if [ -z "${name}" ]; then
			local message
			message=$(mcp_tools_quote "Tool name is required")
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32602,"message":%s}}' "${id}" "${message}"
			return 0
		fi
		args_json="$(mcp_json_extract_arguments "${json_payload}")"
		timeout_override="$(mcp_json_extract_timeout_override "${json_payload}")"
		local result_json
		if ! result_json="$(mcp_tools_call "${name}" "${args_json}" "${timeout_override}")"; then
			local code="${MCP_TOOLS_ERROR_CODE:- -32603}"
			local message
			message=$(mcp_tools_quote "${MCP_TOOLS_ERROR_MESSAGE:-Tool execution failed}")
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%s,"message":%s}}' "${id}" "${code}" "${message}"
			return 0
		fi
		printf '{"jsonrpc":"2.0","id":%s,"result":%s}' "${id}" "${result_json}"
		;;
	*)
		local message
		message=$(mcp_tools_quote "Unknown tools method")
		printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":%s}}' "${id}" "${message}"
		;;
	esac
}
