#!/usr/bin/env bash
# Spec §4: ensure single-line JSON emission with stdout discipline.

set -euo pipefail

rpc_send_line() {
	local payload="$1"
	mcp_io_send_line "${payload}"
}

rpc_send_line_direct() {
	local payload="$1"
	if [ -z "${payload}" ]; then
		return 0
	fi
	if [ -z "${MCPBASH_DIRECT_FD:-}" ]; then
		rpc_send_line "${payload}"
		return 0
	fi
	(
		exec 1>&"${MCPBASH_DIRECT_FD}"
		rpc_send_line "${payload}"
	)
}
