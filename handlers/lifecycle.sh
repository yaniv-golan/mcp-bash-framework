#!/usr/bin/env bash
# Lifecycle handler: initialize/initialized/shutdown workflow.
# Error responses use JSON-RPC 2.0 codes (e.g., -32600 invalid request,
# -32601 method not found, -32602 invalid params).

set -euo pipefail

mcp_handle_lifecycle() {
	local method="$1"
	local json_payload="$2"
	local id
	if ! id="$(mcp_json_extract_id "${json_payload}")"; then
		id="null"
	fi

	case "${method}" in
	initialize)
		if [ "${MCPBASH_INITIALIZE_HANDSHAKE_DONE}" = true ]; then
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32600,"message":"Server already initialized"}}' "${id}"
			return 0
		fi

		local requested_version=""
		requested_version="$(mcp_json_extract_protocol_version "${json_payload}")"
		local negotiated_version=""
		if ! negotiated_version="$(mcp_spec_resolve_protocol_version "${requested_version}")"; then
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32602,"message":"Unsupported protocol version"}}' "${id}"
			return 0
		fi

		# shellcheck disable=SC2034
		MCPBASH_NEGOTIATED_PROTOCOL_VERSION="${negotiated_version}"

		if [ -n "${requested_version}" ] && [ "${requested_version}" != "${negotiated_version}" ]; then
			printf '%s\n' "Degraded protocol to ${negotiated_version} per client request." >&2
		fi

		local capabilities
		capabilities="$(mcp_spec_capabilities_for_runtime "${negotiated_version}")"

		MCPBASH_INITIALIZE_HANDSHAKE_DONE=true
		MCPBASH_INITIALIZED=false

		if mcp_logging_is_enabled "debug"; then
			mcp_logging_debug "mcp.lifecycle" "Initialize requested=${requested_version} negotiated=${negotiated_version}"
		fi

		printf '%s' "$(mcp_spec_build_initialize_response "${id}" "${capabilities}" "${negotiated_version}")"
		;;
	notifications/initialized | initialized)
		# shellcheck disable=SC2034
		MCPBASH_INITIALIZED=true
		if mcp_logging_is_enabled "debug"; then
			mcp_logging_debug "mcp.lifecycle" "Initialized handshake complete"
		fi
		printf '%s' "${MCPBASH_NO_RESPONSE}"
		;;
	shutdown)
		MCPBASH_SHUTDOWN_PENDING=true
		if [ "${MCPBASH_SHUTDOWN_TIMER_STARTED:-false}" != "true" ]; then
			MCPBASH_SHUTDOWN_TIMER_STARTED=true
			mcp_core_start_shutdown_watchdog
		fi
		if mcp_logging_is_enabled "debug"; then
			mcp_logging_debug "mcp.lifecycle" "Shutdown requested"
		fi
		printf '{"jsonrpc":"2.0","id":%s,"result":{}}' "${id}"
		;;
	exit)
		if [ "${MCPBASH_SHUTDOWN_PENDING}" != "true" ]; then
			if [ "${id}" = "null" ]; then
				printf '%s' "${MCPBASH_NO_RESPONSE}"
				return 0
			fi
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32005,"message":"Shutdown not requested"}}' "${id}"
			return 0
		fi
		mcp_core_cancel_shutdown_watchdog
		MCPBASH_SHUTDOWN_TIMER_STARTED=false
		# shellcheck disable=SC2034
		MCPBASH_EXIT_REQUESTED=true
		if [ "${id}" = "null" ]; then
			printf '%s' "${MCPBASH_NO_RESPONSE}"
		else
			printf '{"jsonrpc":"2.0","id":%s,"result":{}}' "${id}"
		fi
		;;
	*)
		printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Unknown lifecycle method"}}' "${id}"
		;;
	esac
}
