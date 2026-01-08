#!/usr/bin/env bash
# Completion handler implementation.
# Error responses use JSON-RPC 2.0 codes (e.g., -32601 method not found,
# -32602 invalid params, -32603 internal error).

set -euo pipefail

mcp_handle_completion() {
	local method="$1"
	local json_payload="$2"
	local id
	if ! id="$(mcp_json_extract_id "${json_payload}")"; then
		id="null"
	fi

	if mcp_runtime_is_minimal_mode; then
		local message
		message=$(mcp_json_quote_text "Completion capability unavailable in minimal mode")
		mcp_handler_error_response "${id}" "-32601" "${message}"
		return 0
	fi

	case "${method}" in
	completion/complete)
		# MCP 2025-11-25 shape: params.ref + params.argument (no legacy support).
		# Normalize to an internal "name" for provider selection/cursor binding.
		local name ref_type
		ref_type="$(mcp_json_extract_completion_ref_type "${json_payload}")"
		if [ -z "${ref_type}" ]; then
			local message
			message=$(mcp_json_quote_text "Completion ref is required")
			mcp_handler_error_response "${id}" "-32602" "${message}"
			return 0
		fi
		case "${ref_type}" in
		ref/prompt)
			name="$(mcp_json_extract_completion_ref_name "${json_payload}")"
			;;
		ref/resource)
			local ref_uri
			ref_uri="$(mcp_json_extract_completion_ref_uri "${json_payload}")"
			if [ -n "${ref_uri}" ]; then
				# Try to resolve the resource registry entry by URI and use its name
				# so resource completion providers can be selected by metadata.
				local metadata resolved
				metadata="$(mcp_resources_metadata_for_uri "${ref_uri}" 2>/dev/null || true)"
				resolved=""
				if [ -n "${metadata}" ]; then
					resolved="$(printf '%s' "${metadata}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.name // ""' 2>/dev/null || true)"
				fi
				if [ -n "${resolved}" ]; then
					name="${resolved}"
				else
					# Fall back to the URI; this still enables builtin completion
					# and keeps cursor binding stable across pages.
					name="${ref_uri}"
				fi
			fi
			;;
		*)
			name=""
			;;
		esac
		if [ -z "${name}" ]; then
			local message
			message=$(mcp_json_quote_text "Completion ref is invalid")
			mcp_handler_error_response "${id}" "-32602" "${message}"
			return 0
		fi

		local arg_name
		arg_name="$(mcp_json_extract_completion_argument_name "${json_payload}")"
		if [ -z "${arg_name}" ]; then
			local message
			message=$(mcp_json_quote_text "Completion argument name is required")
			mcp_handler_error_response "${id}" "-32602" "${message}"
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
		local args_json args_hash query_value
		args_json="$(mcp_json_extract_completion_arguments "${json_payload}")"
		if [ -z "${args_json}" ]; then
			args_json="{}"
		fi
		query_value="$(mcp_json_extract_completion_query "${json_payload}")"
		if ! args_hash="$(mcp_completion_args_hash "${args_json}")" || [ -z "${args_hash}" ]; then
			local message
			message=$(mcp_json_quote_text "Completion requires JSON tooling")
			mcp_handler_error_response "${id}" "-32603" "${message}"
			return 0
		fi
		local cursor start_offset cursor_script_key
		cursor="$(mcp_json_extract_cursor "${json_payload}")"
		start_offset=0
		cursor_script_key=""
		if [ -n "${cursor}" ]; then
			if ! mcp_completion_decode_cursor "${cursor}" "${name}" "${args_hash}" "true"; then
				local message
				message=$(mcp_json_quote_text "Invalid cursor")
				mcp_handler_error_response "${id}" "-32602" "${message}"
				return 0
			fi
			start_offset="${MCP_COMPLETION_CURSOR_OFFSET}"
			cursor_script_key="${MCP_COMPLETION_CURSOR_SCRIPT_KEY}"
		fi
		if ! mcp_completion_select_provider "${name}" "${args_json}"; then
			local message
			message=$(mcp_json_quote_text "Completion not found")
			mcp_handler_error_response "${id}" "-32601" "${message}"
			return 0
		fi
		if [ -n "${cursor_script_key}" ] && [ -n "${MCP_COMPLETION_PROVIDER_SCRIPT_KEY}" ] && [ "${cursor_script_key}" != "${MCP_COMPLETION_PROVIDER_SCRIPT_KEY}" ]; then
			local message
			message=$(mcp_json_quote_text "Cursor no longer valid")
			mcp_handler_error_response "${id}" "-32602" "${message}"
			return 0
		fi
		if ! mcp_completion_run_provider "${name}" "${args_json}" "${query_value}" "${limit}" "${start_offset}" "${args_hash}"; then
			local message
			message=$(mcp_json_quote_text "${MCP_COMPLETION_PROVIDER_RESULT_ERROR:-Unable to complete request}")
			mcp_handler_error_response "${id}" "-32603" "${message}"
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
		mcp_handler_success_response "${id}" "${result_json}"
		;;
	*)
		local message
		message=$(mcp_json_quote_text "Unknown completion method")
		mcp_handler_error_response "${id}" "-32601" "${message}"
		;;
	esac
}
