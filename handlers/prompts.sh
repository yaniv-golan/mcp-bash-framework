#!/usr/bin/env bash
# Prompts handler implementation.

set -euo pipefail

mcp_prompts_quote() {
	local text="$1"
	mcp_json_quote_text "${text}"
}

mcp_handle_prompts() {
	local method="$1"
	local json_payload="$2"
	local id
	if ! id="$(mcp_json_extract_id "${json_payload}")"; then
		id="null"
	fi

	if mcp_runtime_is_minimal_mode; then
		local message
		message=$(mcp_prompts_quote "Prompts capability unavailable in minimal mode")
		printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":%s}}' "${id}" "${message}"
		return 0
	fi

	case "${method}" in
	prompts/list)
		local limit cursor list_json
		limit="$(mcp_json_extract_limit "${json_payload}")"
		cursor="$(mcp_json_extract_cursor "${json_payload}")"
		if ! list_json="$(mcp_prompts_list "${limit}" "${cursor}")"; then
			local code="${MCP_PROMPTS_ERR_CODE:--32603}"
			local message
			message=$(mcp_prompts_quote "${MCP_PROMPTS_ERR_MESSAGE:-Unable to list prompts}")
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%s,"message":%s}}' "${id}" "${code}" "${message}"
			return 0
		fi
		printf '{"jsonrpc":"2.0","id":%s,"result":%s}' "${id}" "${list_json}"
		;;
	prompts/get)
		local name args_json metadata rendered
		name="$(mcp_json_extract_prompt_name "${json_payload}")"
		if [ -z "${name}" ]; then
			local message
			message=$(mcp_prompts_quote "Prompt name is required")
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32602,"message":%s}}' "${id}" "${message}"
			return 0
		fi
		args_json="$(mcp_json_extract_prompt_arguments "${json_payload}")"
		if [ -z "${args_json}" ]; then
			args_json="{}"
		fi
		mcp_prompts_refresh_registry || {
			local message
			message=$(mcp_prompts_quote "Unable to load prompts registry")
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32603,"message":%s}}' "${id}" "${message}"
			return 0
		}
		if ! metadata="$(mcp_prompts_metadata_for_name "${name}")"; then
			local message
			message=$(mcp_prompts_quote "Prompt not found")
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":%s}}' "${id}" "${message}"
			return 0
		fi
		if ! rendered="$(mcp_prompts_render "${metadata}" "${args_json}")"; then
			local message
			message=$(mcp_prompts_quote "Unable to render prompt")
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32603,"message":%s}}' "${id}" "${message}"
			return 0
		fi
		printf '{"jsonrpc":"2.0","id":%s,"result":%s}' "${id}" "${rendered}"
		;;
	*)
		local message
		message=$(mcp_prompts_quote "Unknown prompts method")
		printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":%s}}' "${id}" "${message}"
		;;
	esac
}
