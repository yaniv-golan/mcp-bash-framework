#!/usr/bin/env bash
# Logging level management and stream processing.

set -euo pipefail

# Track whether env var was explicitly set (for conditional re-export)
_MCPBASH_LOG_LEVEL_WAS_SET="${MCPBASH_LOG_LEVEL:+1}"

MCP_LOG_LEVEL_DEFAULT="${MCPBASH_LOG_LEVEL:-${MCPBASH_LOG_LEVEL_DEFAULT:-info}}"

# Normalize to lowercase for case-insensitive boolean matching
# Bash 3.2 compatible (no ${var,,})
MCP_LOG_LEVEL_DEFAULT=$(printf '%s' "${MCP_LOG_LEVEL_DEFAULT}" | tr '[:upper:]' '[:lower:]')

# Normalize boolean-like values AND invalid values to canonical level names
# This ensures re-export always produces a valid RFC-5424 level
# Supports UI toggles that map boolean debug settings to MCPBASH_LOG_LEVEL
case "${MCP_LOG_LEVEL_DEFAULT}" in
true | 1) MCP_LOG_LEVEL_DEFAULT="debug" ;;
false | 0) MCP_LOG_LEVEL_DEFAULT="info" ;;
debug | info | notice | warning | error | critical | alert | emergency) ;; # valid, pass through
*) MCP_LOG_LEVEL_DEFAULT="info" ;;                                         # invalid fallback
esac

# Re-export normalized value ONLY if originally set
# This preserves .debug file mechanism when env var is unset
if [ -n "${_MCPBASH_LOG_LEVEL_WAS_SET}" ]; then
	export MCPBASH_LOG_LEVEL="${MCP_LOG_LEVEL_DEFAULT}"
fi
unset _MCPBASH_LOG_LEVEL_WAS_SET

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

mcp_logging_verbose_enabled() {
	[ "${MCPBASH_LOG_VERBOSE:-false}" = "true" ]
}

mcp_logging_quote() {
	local text="$1"
	mcp_json_quote_text "${text}"
}

mcp_logging_emit() {
	local level="$1"
	local logger="$2"
	local message="$3"
	local logger_json message_json notification_json
	[ -n "${level}" ] || level="info"
	[ -n "${logger}" ] || logger="mcp-bash"
	if ! mcp_logging_is_enabled "${level}"; then
		return 0
	fi
	if [ "${MCPBASH_LOG_TIMESTAMP:-false}" = "true" ]; then
		local ts=""
		ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || printf '')"
		if [ -n "${ts}" ]; then
			message="[${ts}] ${message}"
		fi
	fi
	logger_json="$(mcp_logging_quote "${logger}")" || logger_json='""'
	message_json="$(mcp_logging_quote "${message}")" || message_json='""'
	# Defensive: ensure quoted strings are non-empty to avoid malformed JSON
	[ -n "${logger_json}" ] || logger_json='""'
	[ -n "${message_json}" ] || message_json='""'
	notification_json="$(printf '{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"%s","logger":%s,"data":%s}}' "${level}" "${logger_json}" "${message_json}")"

	# If notification queue is active (inside handler context), defer emission
	# to avoid fd corruption in nested command substitutions. Otherwise emit directly.
	if mcp_notification_queue_active; then
		mcp_notification_queue_append "${notification_json}"
	else
		rpc_send_line_direct "${notification_json}"
	fi
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

mcp_logging_alert() {
	mcp_logging_emit "alert" "$1" "$2"
}

mcp_logging_emergency() {
	mcp_logging_emit "emergency" "$1" "$2"
}
