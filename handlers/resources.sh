#!/usr/bin/env bash
# Resources handler implementation.
# Error responses use JSON-RPC 2.0 codes (e.g., -32601 method not found,
# -32602 invalid params, -32603 internal error).

set -euo pipefail

# Sanitize a string for safe debug log output (escape newlines/carriage returns
# to prevent log injection attacks via malicious resource names/URIs).
_mcp_resources_sanitize_for_log() {
	local value="$1"
	value="${value//$'\n'/\\n}"
	value="${value//$'\r'/\\r}"
	printf '%s' "${value}"
}

mcp_resources_generate_subscription_id() {
	if command -v uuidgen >/dev/null 2>&1; then
		printf '%s' "sub-$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')"
		return
	fi
	printf 'sub-%s-%04d%04d' "$(date +%s)" "$RANDOM" "$RANDOM"
}

mcp_handle_resources() {
	local method="$1"
	local json_payload="$2"
	local id
	local logger="mcp.resources"
	if ! id="$(mcp_json_extract_id "${json_payload}")"; then
		id="null"
	fi

	if mcp_runtime_is_minimal_mode; then
		local message
		message=$(mcp_json_quote_text "Resources capability unavailable in minimal mode")
		mcp_handler_error_response "${id}" "-32601" "${message}"
		return 0
	fi

	case "${method}" in
	resources/list)
		local limit cursor list_json
		limit="$(mcp_json_extract_limit "${json_payload}")"
		cursor="$(mcp_json_extract_cursor "${json_payload}")"
		if ! list_json="$(mcp_resources_list "${limit}" "${cursor}")"; then
			local code
			code="$(mcp_handler_normalize_error_code "${_MCP_RESOURCES_ERROR_CODE:-}")"
			local message
			message=$(mcp_json_quote_text "${_MCP_RESOURCES_ERROR_MESSAGE:-Unable to list resources}")
			mcp_handler_error_response "${id}" "${code}" "${message}"
			return 0
		fi
		mcp_handler_success_response "${id}" "${list_json}"
		;;
	resources/read)
		local name uri result_json
		name="$(mcp_json_extract_resource_name "${json_payload}")"
		uri="$(mcp_json_extract_resource_uri "${json_payload}")"
		if [ -z "${name}" ] && [ -z "${uri}" ]; then
			local message
			message=$(mcp_json_quote_text "Resource name or uri required")
			mcp_handler_error_response "${id}" "-32602" "${message}"
			return 0
		fi
		if ! mcp_resources_read "${name}" "${uri}"; then
			local code
			code="$(mcp_handler_normalize_error_code "${_MCP_RESOURCES_ERROR_CODE:-}")"
			local message
			message=$(mcp_json_quote_text "${_MCP_RESOURCES_ERROR_MESSAGE:-Unable to read resource}")
			mcp_handler_error_response "${id}" "${code}" "${message}"
			return 0
		fi
		result_json="${_MCP_RESOURCES_RESULT}"
		mcp_handler_success_response "${id}" "${result_json}"
		;;
	resources/subscribe)
		local name uri subscription_id result_json
		name="$(mcp_json_extract_resource_name "${json_payload}")"
		uri="$(mcp_json_extract_resource_uri "${json_payload}")"
		mcp_logging_debug "${logger}" "Subscribe request name=${name:-<none>} uri=${uri:-<none>}"
		if [ -n "${MCPBASH_STATE_DIR:-}" ]; then
			# Sanitize name/uri to prevent log injection via newlines
			local safe_name safe_uri
			safe_name="$(_mcp_resources_sanitize_for_log "${name:-<none>}")"
			safe_uri="$(_mcp_resources_sanitize_for_log "${uri:-<none>}")"
			printf '%s %s\n' "subscribe-start" "${safe_name}:${safe_uri}" >>"${MCPBASH_STATE_DIR}/resources.debug.log"
		fi
		if [ -z "${name}" ] && [ -z "${uri}" ]; then
			local message
			message=$(mcp_json_quote_text "Resource name or uri required")
			mcp_handler_error_response "${id}" "-32602" "${message}"
			return 0
		fi
		subscription_id="$(mcp_resources_generate_subscription_id)"
		if ! mcp_resources_read "${name}" "${uri}"; then
			mcp_logging_error "${logger}" "Initial read failed code=${_MCP_RESOURCES_ERROR_CODE:-?} msg=${_MCP_RESOURCES_ERROR_MESSAGE:-?}"
			local code
			code="$(mcp_handler_normalize_error_code "${_MCP_RESOURCES_ERROR_CODE:-}")"
			local message
			message=$(mcp_json_quote_text "${_MCP_RESOURCES_ERROR_MESSAGE:-Unable to read resource}")
			mcp_handler_error_response "${id}" "${code}" "${message}"
			return 0
		fi
		result_json="${_MCP_RESOURCES_RESULT}"
		mcp_logging_debug "${logger}" "Subscribe initial read ok subscription=${subscription_id}"
		if [ -n "${MCPBASH_STATE_DIR:-}" ]; then
			printf '%s %s\n' "subscribe-read-ok" "${subscription_id}" >>"${MCPBASH_STATE_DIR}/resources.debug.log"
		fi
		local effective_uri
		effective_uri="$(printf '%s' "${result_json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.contents[0].uri // ""')" || effective_uri=""
		if [ -z "${effective_uri}" ]; then
			effective_uri="${uri}"
		fi
		mcp_resources_subscription_store_payload "${subscription_id}" "${name}" "${effective_uri}" "${result_json}"
		local key
		key="$(mcp_ids_key_from_json "${id}")"
		if [ -n "${key}" ] && mcp_ids_is_cancelled_key "${key}"; then
			mcp_logging_debug "${logger}" "Subscribe cancelled before response subscription=${subscription_id}"
			if [ -n "${MCPBASH_STATE_DIR:-}" ]; then
				rm -f "${MCPBASH_STATE_DIR}/resource_subscription.${subscription_id}"
			fi
			printf '%s' "${MCPBASH_NO_RESPONSE}"
			return 0
		fi
		local response_payload response
		# MCP 2025-11-25: resources/subscribe returns only {subscriptionId}.
		response_payload="$("${MCPBASH_JSON_TOOL_BIN}" -n -c --arg sub "${subscription_id}" '{subscriptionId: $sub}')"
		response="$(mcp_handler_success_response "${id}" "${response_payload}")"
		mcp_logging_debug "${logger}" "Subscribe emitting response subscription=${subscription_id}"
		rpc_send_line_direct "${response}"
		if [ -n "${MCPBASH_STATE_DIR:-}" ]; then
			printf '%s %s\n' "subscribe-response" "${subscription_id}" >>"${MCPBASH_STATE_DIR}/resources.debug.log"
		fi
		printf '%s' "${MCPBASH_NO_RESPONSE}"
		;;
	resources/unsubscribe)
		local subscription_id
		subscription_id="$(mcp_json_extract_subscription_id "${json_payload}")"
		if [ -z "${subscription_id}" ]; then
			local message
			message=$(mcp_json_quote_text "subscriptionId required")
			mcp_handler_error_response "${id}" "-32602" "${message}"
			return 0
		fi
		rm -f "${MCPBASH_STATE_DIR}/resource_subscription.${subscription_id}"
		mcp_handler_success_response "${id}" "{}"
		;;
	resources/templates/list)
		local limit cursor list_json
		limit="$(mcp_json_extract_limit "${json_payload}")"
		cursor="$(mcp_json_extract_cursor "${json_payload}")"
		if ! list_json="$(mcp_resources_templates_list "${limit}" "${cursor}")"; then
			local code="${_MCP_RESOURCES_ERROR_CODE:--32603}"
			# Special case: code 0 with cursor means invalid cursor, otherwise internal error
			if [ "${code}" = "0" ]; then
				if [ -n "${cursor}" ]; then
					code="-32602"
				else
					code="-32603"
				fi
			fi
			local message
			local err_text="${_MCP_RESOURCES_ERROR_MESSAGE:-Unable to list resource templates}"
			if [ "${code}" = "-32602" ] && [ -z "${_MCP_RESOURCES_ERROR_MESSAGE:-}" ]; then
				err_text="Invalid cursor"
			fi
			message=$(mcp_json_quote_text "${err_text}")
			mcp_handler_error_response "${id}" "${code}" "${message}"
			return 0
		fi
		mcp_handler_success_response "${id}" "${list_json}"
		;;
	*)
		local message
		message=$(mcp_json_quote_text "Unknown resources method")
		mcp_handler_error_response "${id}" "-32601" "${message}"
		;;
	esac
}
