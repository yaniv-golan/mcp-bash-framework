#!/usr/bin/env bash
# Spec §8 resources handler implementation.

set -euo pipefail

mcp_resources_quote() {
	local text="$1"
	local py
	if py="$(mcp_resources_python 2>/dev/null)"; then
		TEXT="${text}" "${py}" <<'PY'
import json, os
print(json.dumps(os.environ.get("TEXT", "")))
PY
	else
		printf '"%s"' "$(printf '%s' "${text}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
	fi
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
			local code="${MCP_RESOURCES_ERR_CODE:- -32603}"
			local message
			message=$(mcp_resources_quote "${MCP_RESOURCES_ERR_MESSAGE:-Unable to list resources}")
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
		if ! result_json="$(mcp_resources_read "${name}" "${uri}")"; then
			local code="${MCP_RESOURCES_ERR_CODE:- -32603}"
			local message
			message=$(mcp_resources_quote "${MCP_RESOURCES_ERR_MESSAGE:-Unable to read resource}")
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%s,"message":%s}}' "${id}" "${code}" "${message}"
			return 0
		fi
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
		subscription_id="sub-$(uuidgen 2>/dev/null || date +%s%N)"
		if ! result_json="$(mcp_resources_read "${name}" "${uri}")"; then
			mcp_logging_error "${logger}" "Initial read failed code=${MCP_RESOURCES_ERR_CODE:-?} msg=${MCP_RESOURCES_ERR_MESSAGE:-?}"
			local code="${MCP_RESOURCES_ERR_CODE:- -32603}"
			local message
			message=$(mcp_resources_quote "${MCP_RESOURCES_ERR_MESSAGE:-Unable to read resource}")
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%s,"message":%s}}' "${id}" "${code}" "${message}"
			return 0
		fi
		mcp_logging_debug "${logger}" "Subscribe initial read ok subscription=${subscription_id}"
		if [ -n "${MCPBASH_STATE_DIR:-}" ]; then
			printf '%s %s\n' "subscribe-read-ok" "${subscription_id}" >>"${MCPBASH_STATE_DIR}/resources.debug.log"
		fi
		local effective_uri
		local py
		py="$(mcp_resources_python 2>/dev/null)" || py=""
		if [ -n "${py}" ]; then
			effective_uri="$(
				RESULT="${result_json}" "${py}" <<'PY'
import json, os
print(json.loads(os.environ["RESULT"]).get("uri", ""))
PY
			)"
		else
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
		local response
		response="$(printf '{"jsonrpc":"2.0","id":%s,"result":{"subscriptionId":"%s"}}' "${id}" "${subscription_id}")"
		mcp_logging_debug "${logger}" "Subscribe emitting response subscription=${subscription_id}"
		rpc_send_line_direct "${response}"
		if [ -n "${MCPBASH_STATE_DIR:-}" ]; then
			printf '%s %s\n' "subscribe-response" "${subscription_id}" >>"${MCPBASH_STATE_DIR}/resources.debug.log"
		fi
		mcp_resources_emit_update "${subscription_id}" "${result_json}"
		if [ -n "${MCPBASH_STATE_DIR:-}" ]; then
			printf '%s %s\n' "subscribe-emit-update" "${subscription_id}" >>"${MCPBASH_STATE_DIR}/resources.debug.log"
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
	*)
		local message
		message=$(mcp_resources_quote "Unknown resources method")
		printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":%s}}' "${id}" "${message}"
		;;
	esac
}
