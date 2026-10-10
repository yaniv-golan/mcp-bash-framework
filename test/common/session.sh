#!/usr/bin/env bash
# Minimal session helper for sequential tool calls in tests.
# Notifications are skipped, EXIT traps are overwritten, and error handling is minimal.

set -euo pipefail

MCP_SESSION_PID=""
MCP_SESSION_IN=""
MCP_SESSION_OUT=""
MCP_SESSION_DIR=""
MCP_SESSION_ID=0

mcp_session_start() {
	local workspace="${1:-${MCPBASH_PROJECT_ROOT:-$PWD}}"
	local mcp_bin="${MCPBASH_BIN:-mcp-bash}"
	local protocol_version="${MCPBASH_PROTOCOL_VERSION:-2025-11-25}"

	MCP_SESSION_DIR="$(mktemp -d)"
	mkfifo "${MCP_SESSION_DIR}/in" "${MCP_SESSION_DIR}/out"

	MCPBASH_PROJECT_ROOT="${workspace}" "${mcp_bin}" \
		<"${MCP_SESSION_DIR}/in" >"${MCP_SESSION_DIR}/out" 2>"${MCP_SESSION_DIR}/err" &
	MCP_SESSION_PID=$!

	exec 3>"${MCP_SESSION_DIR}/in" 4<"${MCP_SESSION_DIR}/out"
	MCP_SESSION_IN=3 MCP_SESSION_OUT=4

	trap 'mcp_session_end' EXIT

	_mcp_send "$(printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"%s","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' "${protocol_version}")"
	_mcp_recv >/dev/null
	_mcp_send '{"jsonrpc":"2.0","method":"notifications/initialized"}'
	MCP_SESSION_ID=10
}

mcp_session_call() {
	local no_args='{}'
	local name="$1" args="${2:-${no_args}}"
	((MCP_SESSION_ID++))
	_mcp_send "{\"jsonrpc\":\"2.0\",\"id\":${MCP_SESSION_ID},\"method\":\"tools/call\",\"params\":{\"name\":\"${name}\",\"arguments\":${args}}}"
	_mcp_recv_response "${MCP_SESSION_ID}"
}

mcp_session_end() {
	exec 3>&- 2>/dev/null || true
	if [ -n "${MCP_SESSION_PID}" ]; then
		wait "${MCP_SESSION_PID}" 2>/dev/null || true
	fi
	exec 4<&- 2>/dev/null || true
	if [ -n "${MCP_SESSION_DIR}" ]; then
		rm -rf "${MCP_SESSION_DIR}" 2>/dev/null || true
	fi
	MCP_SESSION_PID=""
	MCP_SESSION_DIR=""
	trap - EXIT
}

_mcp_send() { printf '%s\n' "$1" >&"${MCP_SESSION_IN}"; }

_mcp_recv() {
	local line
	IFS= read -r line <&"${MCP_SESSION_OUT}"
	printf '%s\n' "${line}"
}

_mcp_recv_response() {
	# Read lines until we get a response with matching id.
	# Notifications (no id) are skipped.
	local expected_id="$1" line
	while IFS= read -r line <&"${MCP_SESSION_OUT}"; do
		if printf '%s' "${line}" | grep -q "\"id\":${expected_id}[,}]"; then
			printf '%s\n' "${line}"
			return 0
		fi
		# else: notification, skip it
	done
	return 1
}
