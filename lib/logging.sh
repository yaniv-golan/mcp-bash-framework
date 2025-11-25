#!/usr/bin/env bash
# Logging level management and stream processing.

set -euo pipefail

MCP_LOG_LEVEL_DEFAULT="${MCPBASH_LOG_LEVEL:-${MCPBASH_LOG_LEVEL_DEFAULT:-info}}"
MCP_LOG_LEVEL_CURRENT="${MCP_LOG_LEVEL_DEFAULT}"

mcp_logging_level_rank() {
	case "$1" in
	debug) echo 10 ;;
	info) echo 20 ;;
	notice) echo 25 ;;
	warning) echo 30 ;;
	error) echo 40 ;;
	critical) echo 50 ;;
	alert) echo 60 ;;
	emergency) echo 70 ;;
	*) echo 999 ;;
	esac
}

mcp_logging_set_level() {
	local level="$1"
	MCP_LOG_LEVEL_CURRENT="${level}"
}

mcp_logging_get_level() {
	printf '%s' "${MCP_LOG_LEVEL_CURRENT}"
}

mcp_logging_is_enabled() {
	local level="$1"
	local current
	current="$(mcp_logging_get_level)"
	if [ "$(mcp_logging_level_rank "${level}")" -lt "$(mcp_logging_level_rank "${current}")" ]; then
		return 1
	fi
	return 0
}

mcp_logging_quote() {
	local text="$1"
	mcp_json_quote_text "${text}"
}

mcp_logging_emit() {
	local level="$1"
	local logger="$2"
	local message="$3"
	local logger_json message_json
	[ -n "${level}" ] || level="info"
	[ -n "${logger}" ] || logger="mcp-bash"
	if ! mcp_logging_is_enabled "${level}"; then
		return 0
	fi
	logger_json="$(mcp_logging_quote "${logger}")"
	message_json="$(mcp_logging_quote "${message}")"
	rpc_send_line "$(printf '{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"%s","logger":%s,"message":{"type":"text","text":%s}}}' "${level}" "${logger_json}" "${message_json}")"
}

mcp_logging_debug() {
	mcp_logging_emit "debug" "$1" "$2"
}

mcp_logging_info() {
	mcp_logging_emit "info" "$1" "$2"
}

mcp_logging_notice() {
	mcp_logging_emit "notice" "$1" "$2"
}

mcp_logging_warning() {
	mcp_logging_emit "warning" "$1" "$2"
}

mcp_logging_error() {
	mcp_logging_emit "error" "$1" "$2"
}

mcp_logging_critical() {
	mcp_logging_emit "critical" "$1" "$2"
}
