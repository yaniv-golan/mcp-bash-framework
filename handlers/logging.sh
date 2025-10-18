#!/usr/bin/env bash
# Spec §8 logging handler implementation.

set -euo pipefail

mcp_handle_logging() {
	local method="$1"
	local json_payload="$2"
	local id
	if ! id="$(mcp_json_extract_id "${json_payload}")"; then
		id="null"
	fi

	case "${method}" in
	logging/setLevel)
		local level
		level="$(mcp_json_extract_log_level "${json_payload}")"
		if [ -z "${level}" ]; then
			level="info"
		fi
		level="$(printf '%s' "${level}" | tr '[:upper:]' '[:lower:]')"
		if [ "$(mcp_logging_level_rank "${level}")" -ge 999 ]; then
			printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32602,"message":"Invalid log level"}}' "${id}"
			return 0
		fi
		mcp_logging_set_level "${level}"
		printf '{"jsonrpc":"2.0","id":%s,"result":{}}' "${id}"
		;;
	*)
		printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Unknown logging method"}}' "${id}"
		;;
	esac
}
