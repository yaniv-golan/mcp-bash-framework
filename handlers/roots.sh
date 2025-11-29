#!/usr/bin/env bash
# Roots notifications handler.

set -euo pipefail

mcp_handle_roots() {
	local method="$1"
	local json_payload="$2"

	case "${method}" in
	notifications/roots/list_changed)
		mcp_roots_request_from_client
		printf '%s' "${MCPBASH_NO_RESPONSE}"
		;;
	*)
		local id
		id="$(mcp_json_extract_id "${json_payload}")"
		printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Unknown roots method"}}' "${id}"
		;;
	esac
}
