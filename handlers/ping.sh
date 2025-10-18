#!/usr/bin/env bash
# Spec §3/§8 ping handler.

set -euo pipefail

mcp_handle_ping() {
	local _method="$1"
	local json_payload="$2"
	local id
	if ! id="$(mcp_json_extract_id "${json_payload}")"; then
		id="null"
	fi
	printf '{"jsonrpc":"2.0","id":%s,"result":{}}' "${id}"
}
