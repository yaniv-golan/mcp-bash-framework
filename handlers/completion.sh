#!/usr/bin/env bash
# Spec §8 completion handler implementation.

set -euo pipefail

mcp_completion_quote() {
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

mcp_handle_completion() {
	local method="$1"
	local json_payload="$2"
	local id
	if ! id="$(mcp_json_extract_id "${json_payload}")"; then
		id="null"
	fi

	if mcp_runtime_is_minimal_mode; then
		local message
		message=$(mcp_completion_quote "Completion capability unavailable in minimal mode")
		printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":%s}}' "${id}" "${message}"
		return 0
	fi

	case "${method}" in
	completion/complete)
		local name
		name="$(mcp_json_extract_completion_name "${json_payload}")"
		if [ -z "${name}" ]; then
			local message
			message=$(mcp_completion_quote "Completion name is required")
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32602,"message":%s}}' "${id}" "${message}"
			return 0
		fi
		mcp_completion_reset
		local limit
		limit="$(mcp_json_extract_limit "${json_payload}")"
		case "${limit}" in
		'' | *[!0-9]*) limit=5 ;;
		0) limit=5 ;;
		esac
		if [ "${limit}" -gt 100 ]; then
			limit=100
		fi
		local args_json args_hash
		args_json="$(mcp_json_extract_completion_arguments "${json_payload}")"
		if [ -z "${args_json}" ]; then
			args_json="{}"
		fi
		if ! args_hash="$(mcp_completion_args_hash "${args_json}")" || [ -z "${args_hash}" ]; then
			local message
			message=$(mcp_completion_quote "Completion requires JSON tooling")
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32603,"message":%s}}' "${id}" "${message}"
			return 0
		fi
		local cursor start_offset cursor_script_key
		cursor="$(mcp_json_extract_cursor "${json_payload}")"
		start_offset=0
		cursor_script_key=""
		if [ -n "${cursor}" ]; then
			if ! mcp_completion_decode_cursor "${cursor}" "${name}" "${args_hash}"; then
				local message
				message=$(mcp_completion_quote "Invalid cursor")
				printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32602,"message":%s}}' "${id}" "${message}"
				return 0
			fi
			start_offset="${MCP_COMPLETION_CURSOR_OFFSET}"
			cursor_script_key="${MCP_COMPLETION_CURSOR_SCRIPT_KEY}"
		fi
		if ! mcp_completion_select_provider "${name}" "${args_json}"; then
			local message
			message=$(mcp_completion_quote "Completion not found")
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":%s}}' "${id}" "${message}"
			return 0
		fi
		if [ -n "${cursor_script_key}" ] && [ -n "${MCP_COMPLETION_PROVIDER_SCRIPT_KEY}" ] && [ "${cursor_script_key}" != "${MCP_COMPLETION_PROVIDER_SCRIPT_KEY}" ]; then
			local message
			message=$(mcp_completion_quote "Cursor no longer valid")
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32602,"message":%s}}' "${id}" "${message}"
			return 0
		fi
		if ! mcp_completion_run_provider "${name}" "${args_json}" "${limit}" "${start_offset}" "${args_hash}"; then
			local message
			message=$(mcp_completion_quote "${MCP_COMPLETION_PROVIDER_RESULT_ERROR:-Unable to complete request}")
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32603,"message":%s}}' "${id}" "${message}"
			return 0
		fi
		mcp_completion_reset
		# shellcheck disable=SC2034
		mcp_completion_suggestions="${MCP_COMPLETION_PROVIDER_RESULT_SUGGESTIONS}"
		if [ "${MCP_COMPLETION_PROVIDER_RESULT_HAS_MORE}" = "true" ]; then
			mcp_completion_has_more=true
		fi
		if [ "${mcp_completion_has_more}" = true ]; then
			local next_offset="${MCP_COMPLETION_PROVIDER_RESULT_NEXT}"
			local cursor_value="${MCP_COMPLETION_PROVIDER_RESULT_CURSOR}"
			if [ -n "${cursor_value}" ]; then
				# shellcheck disable=SC2034
				mcp_completion_cursor="${cursor_value}"
			else
				if [ -z "${next_offset}" ]; then
					local count
					count="$(mcp_completion_suggestions_count)"
					next_offset=$((start_offset + count))
				fi
				if [ -n "${next_offset}" ]; then
					local encoded_cursor
					encoded_cursor="$(mcp_completion_encode_cursor "${name}" "${args_hash}" "${next_offset}" "${MCP_COMPLETION_PROVIDER_SCRIPT_KEY}")"
					if [ -n "${encoded_cursor}" ]; then
						# shellcheck disable=SC2034
						mcp_completion_cursor="${encoded_cursor}"
					fi
				fi
			fi
		fi
		local result_json
		result_json="$(mcp_completion_finalize)"
		printf '{"jsonrpc":"2.0","id":%s,"result":%s}' "${id}" "${result_json}"
		;;
	*)
		local message
		message=$(mcp_completion_quote "Unknown completion method")
		printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":%s}}' "${id}" "${message}"
		;;
	esac
}
