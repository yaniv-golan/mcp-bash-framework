#!/usr/bin/env bash
# Spec §13: logging level management and stream processing.

set -euo pipefail

MCP_LOG_LEVEL_DEFAULT="${MCPBASH_LOG_LEVEL_DEFAULT:-info}"
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
