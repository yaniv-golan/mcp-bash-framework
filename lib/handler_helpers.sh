#!/usr/bin/env bash
# Shared helper functions for MCP handlers.
# Reduces duplication of error formatting and response building across handlers.

set -euo pipefail

# Normalize error codes: convert 0, empty, or "null" to default JSON-RPC internal error.
# Usage: code="$(mcp_handler_normalize_error_code "${code}" "${default:-32603}")"
mcp_handler_normalize_error_code() {
	local code="${1:-}"
	local default="${2:--32603}"
	case "${code}" in
	0 | "" | "null") printf '%s' "${default}" ;;
	*) printf '%s' "${code}" ;;
	esac
}

# Format a JSON-RPC 2.0 error response.
# Usage: mcp_handler_error_response "${id}" "${code}" "${quoted_message}" ["${data}"]
# Note: message must already be JSON-quoted (use mcp_json_quote_text).
mcp_handler_error_response() {
	local id="$1"
	local code="$2"
	local message="$3"
	local data="${4:-}"
	if [ -n "${data}" ] && [ "${data}" != "null" ]; then
		printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%s,"message":%s,"data":%s}}' \
			"${id}" "${code}" "${message}" "${data}"
	else
		printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%s,"message":%s}}' \
			"${id}" "${code}" "${message}"
	fi
}

# Format a JSON-RPC 2.0 success response.
# Usage: mcp_handler_success_response "${id}" "${result_json}"
mcp_handler_success_response() {
	local id="$1"
	local result="$2"
	printf '{"jsonrpc":"2.0","id":%s,"result":%s}' "${id}" "${result}"
}
