#!/usr/bin/env bash
# Spec §10 tool runtime SDK helpers.

set -euo pipefail

MCP_TOOL_CANCELLATION_FILE="${MCP_CANCEL_FILE:-}"
MCP_PROGRESS_STREAM="${MCP_PROGRESS_STREAM:-}"
MCP_LOG_STREAM="${MCP_LOG_STREAM:-}"
MCP_PROGRESS_TOKEN="${MCP_PROGRESS_TOKEN:-}"

mcp_args_raw() {
	printf '%s' "${MCP_TOOL_ARGS_JSON:-{}}"
}

mcp_args_get() {
	local filter="$1"
	if [ "${MCPBASH_MODE:-full}" = "minimal" ]; then
		printf ''
		return 1
	fi
	if command -v "${MCPBASH_JSON_TOOL_BIN:-}" >/dev/null 2>&1; then
		printf '%s' "${MCP_TOOL_ARGS_JSON:-{}}" | "${MCPBASH_JSON_TOOL_BIN}" -c "${filter}" 2>/dev/null
	else
		printf ''
		return 1
	fi
}

mcp_is_cancelled() {
	if [ -z "${MCP_TOOL_CANCELLATION_FILE}" ]; then
		return 1
	fi
	if [ -f "${MCP_TOOL_CANCELLATION_FILE}" ]; then
		return 0
	fi
	return 1
}

mcp_progress() {
	local percent="$1"
	local message="$2"
	if [ -z "${MCP_PROGRESS_TOKEN}" ] || [ -z "${MCP_PROGRESS_STREAM}" ]; then
		return 0
	fi
	printf '{"jsonrpc":"2.0","method":"notifications/progress","params":{"token":"%s","percent":%s,"message":"%s"}}\n' "${MCP_PROGRESS_TOKEN}" "${percent}" "${message}" >>"${MCP_PROGRESS_STREAM}" 2>/dev/null || true
}

mcp_log() {
	local level="$1"
	local logger="$2"
	local json_payload="$3"
	if [ -z "${MCP_LOG_STREAM}" ]; then
		return 0
	fi
	printf '{"jsonrpc":"2.0","method":"notifications/log","params":{"level":"%s","logger":"%s","message":%s}}\n' "${level}" "${logger}" "${json_payload}" >>"${MCP_LOG_STREAM}" 2>/dev/null || true
}

mcp_emit_text() {
	local text="$1"
	printf '%s' "${text}"
}

mcp_emit_json() {
	local json="$1"
	printf '%s' "${json}"
}
