#!/usr/bin/env bash
# Resources handler implementation.
# Error responses use JSON-RPC 2.0 codes (e.g., -32601 method not found,
# -32602 invalid params, -32603 internal error).

set -euo pipefail

mcp_resources_generate_subscription_id() {
	if command -v uuidgen >/dev/null 2>&1; then
		printf '%s' "sub-$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')"
		return
	fi
	printf 'sub-%s-%04d%04d' "$(date +%s)" "$RANDOM" "$RANDOM"
}

mcp_resources_quote() {
	local text="$1"
	mcp_json_quote_text "${text}"
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
		message=$(mcp_resources_quote "Resources capability unavailable in minimal mode")
		printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":%s}}' "${id}" "${message}"
		return 0
	fi

	case "${method}" in
	resources/list)
		local limit cursor list_json
		limit="$(mcp_json_extract_limit "${json_payload}")"
		cursor="$(mcp_json_extract_cursor "${json_payload}")"
		if ! list_json="$(mcp_resources_list "${limit}" "${cursor}")"; then
			local code="${_MCP_RESOURCES_ERR_CODE:--32603}"
			local message
			message=$(mcp_resources_quote "${_MCP_RESOURCES_ERR_MESSAGE:-Unable to list resources}")
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%s,"message":%s}}' "${id}" "${code}" "${message}"
			return 0
		fi
		printf '{"jsonrpc":"2.0","id":%s,"result":%s}' "${id}" "${list_json}"
		;;
	resources/read)
		local name uri result_json
		name="$(mcp_json_extract_resource_name "${json_payload}")"
		uri="$(mcp_json_extract_resource_uri "${json_payload}")"
		if [ -z "${name}" ] && [ -z "${uri}" ]; then
			local message
			message=$(mcp_resources_quote "Resource name or uri required")
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32602,"message":%s}}' "${id}" "${message}"
			return 0
		fi
		if ! mcp_resources_read "${name}" "${uri}"; then
			local code="${_MCP_RESOURCES_ERR_CODE:--32603}"
			case "${code}" in
			"" | "0") code="-32603" ;;
			esac
			local message
			message=$(mcp_resources_quote "${_MCP_RESOURCES_ERR_MESSAGE:-Unable to read resource}")
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%s,"message":%s}}' "${id}" "${code}" "${message}"
			return 0
		fi
		result_json="${_MCP_RESOURCES_RESULT}"
		printf '{"jsonrpc":"2.0","id":%s,"result":%s}' "${id}" "${result_json}"
		;;
	resources/subscribe)
		local name uri subscription_id result_json
		name="$(mcp_json_extract_resource_name "${json_payload}")"
		uri="$(mcp_json_extract_resource_uri "${json_payload}")"
		mcp_logging_debug "${logger}" "Subscribe request name=${name:-<none>} uri=${uri:-<none>}"
		if [ -n "${MCPBASH_STATE_DIR:-}" ]; then
			printf '%s %s\n' "subscribe-start" "${name:-<none>}:${uri:-<none>}" >>"${MCPBASH_STATE_DIR}/resources.debug.log"
		fi
		if [ -z "${name}" ] && [ -z "${uri}" ]; then
			local message
			message=$(mcp_resources_quote "Resource name or uri required")
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32602,"message":%s}}' "${id}" "${message}"
			return 0
		fi
		subscription_id="$(mcp_resources_generate_subscription_id)"
		if ! mcp_resources_read "${name}" "${uri}"; then
			mcp_logging_error "${logger}" "Initial read failed code=${_MCP_RESOURCES_ERR_CODE:-?} msg=${_MCP_RESOURCES_ERR_MESSAGE:-?}"
			local code="${_MCP_RESOURCES_ERR_CODE:--32603}"
			case "${code}" in
			"" | "0") code="-32603" ;;
			esac
			local message
			message=$(mcp_resources_quote "${_MCP_RESOURCES_ERR_MESSAGE:-Unable to read resource}")
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%s,"message":%s}}' "${id}" "${code}" "${message}"
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
		response="$(printf '{"jsonrpc":"2.0","id":%s,"result":%s}' "${id}" "${response_payload}")"
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
			message=$(mcp_resources_quote "subscriptionId required")
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32602,"message":%s}}' "${id}" "${message}"
			return 0
		fi
		rm -f "${MCPBASH_STATE_DIR}/resource_subscription.${subscription_id}"
		printf '{"jsonrpc":"2.0","id":%s,"result":{}}' "${id}"
		;;
	resources/templates/list)
		local limit cursor list_json
		limit="$(mcp_json_extract_limit "${json_payload}")"
		cursor="$(mcp_json_extract_cursor "${json_payload}")"
		if ! list_json="$(mcp_resources_templates_list "${limit}" "${cursor}")"; then
			local code="${_MCP_RESOURCES_ERR_CODE:--32603}"
			if [ "${code}" = "0" ] && [ -n "${cursor}" ]; then
				code="-32602"
			fi
			local message
			local err_text="${_MCP_RESOURCES_ERR_MESSAGE:-Unable to list resource templates}"
			if [ "${code}" = "-32602" ] && [ -z "${_MCP_RESOURCES_ERR_MESSAGE:-}" ]; then
				err_text="Invalid cursor"
			fi
			message=$(mcp_resources_quote "${err_text}")
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%s,"message":%s}}' "${id}" "${code}" "${message}"
			return 0
		fi
		printf '{"jsonrpc":"2.0","id":%s,"result":%s}' "${id}" "${list_json}"
		;;
	*)
		local message
		message=$(mcp_resources_quote "Unknown resources method")
		printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":%s}}' "${id}" "${message}"
		;;
	esac
}
