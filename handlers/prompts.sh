#!/usr/bin/env bash
# Prompts handler implementation.
# Error responses use JSON-RPC 2.0 codes (e.g., -32601 method not found,
# -32602 invalid params, -32603 internal error).

set -euo pipefail

mcp_handle_prompts() {
	local method="$1"
	local json_payload="$2"
	local id
	if ! id="$(mcp_json_extract_id "${json_payload}")"; then
		id="null"
	fi

	if mcp_runtime_is_minimal_mode; then
		local message
		message=$(mcp_json_quote_text "Prompts capability unavailable in minimal mode")
		mcp_handler_error_response "${id}" "-32601" "${message}"
		return 0
	fi

	case "${method}" in
	prompts/list)
		local limit cursor list_json
		limit="$(mcp_json_extract_limit "${json_payload}")"
		cursor="$(mcp_json_extract_cursor "${json_payload}")"
		if ! list_json="$(mcp_prompts_list "${limit}" "${cursor}")"; then
			local code
			code="$(mcp_handler_normalize_error_code "${_MCP_PROMPTS_ERROR_CODE:-}")"
			local message
			message=$(mcp_json_quote_text "${_MCP_PROMPTS_ERROR_MESSAGE:-Unable to list prompts}")
			mcp_handler_error_response "${id}" "${code}" "${message}"
			return 0
		fi
		mcp_handler_success_response "${id}" "${list_json}"
		if mcp_logging_is_enabled "debug"; then
			mcp_logging_debug "${MCP_PROMPTS_LOGGER}" "List count=${MCP_PROMPTS_TOTAL}"
		fi
		;;
	prompts/get)
		local name args_json metadata rendered
		name="$(mcp_json_extract_prompt_name "${json_payload}")"
		if [ -z "${name}" ]; then
			local message
			message=$(mcp_json_quote_text "Prompt name is required")
			mcp_handler_error_response "${id}" "-32602" "${message}"
			return 0
		fi
		args_json="$(mcp_json_extract_prompt_arguments "${json_payload}")"
		if [ -z "${args_json}" ]; then
			args_json="{}"
		fi
		mcp_prompts_refresh_registry || {
			local message
			message=$(mcp_json_quote_text "Unable to load prompts registry")
			mcp_handler_error_response "${id}" "-32603" "${message}"
			return 0
		}
		if ! metadata="$(mcp_prompts_metadata_for_name "${name}")"; then
			local message
			message=$(mcp_json_quote_text "Prompt not found")
			# Unknown prompt name is an invalid-params condition, not a missing method.
			mcp_handler_error_response "${id}" "-32602" "${message}"
			return 0
		fi
		if ! mcp_prompts_render "${metadata}" "${args_json}"; then
			local message
			message=$(mcp_json_quote_text "Unable to render prompt")
			mcp_handler_error_response "${id}" "-32603" "${message}"
			return 0
		fi
		rendered="${_MCP_PROMPTS_RESULT}"
		if mcp_logging_is_enabled "debug"; then
			mcp_logging_debug "${MCP_PROMPTS_LOGGER}" "Get name=${name}"
		fi
		mcp_handler_success_response "${id}" "${rendered}"
		;;
	*)
		local message
		message=$(mcp_json_quote_text "Unknown prompts method")
		mcp_handler_error_response "${id}" "-32601" "${message}"
		;;
	esac
}
