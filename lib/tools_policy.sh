#!/usr/bin/env bash
# Tool-level policy hook (default allow-all; override via server.d/policy.sh).

set -euo pipefail

: "${MCP_TOOLS_POLICY_LOADED:=false}"

# Initialize tool policy by sourcing server.d/policy.sh once per process.
mcp_tools_policy_init() {
	if [ "${MCP_TOOLS_POLICY_LOADED}" = "true" ]; then
		return 0
	fi
	MCP_TOOLS_POLICY_LOADED="true"

	# Project override lives in server.d/policy.sh; source if present/readable.
	local policy_path="${MCPBASH_SERVER_DIR:-}/policy.sh"
	if [ -n "${policy_path}" ] && [ -f "${policy_path}" ]; then
		# shellcheck disable=SC1090
		. "${policy_path}"
	fi
	return 0
}

# Default policy: allow all tools. Projects can override by defining the same
# function in server.d/policy.sh (sourced by mcp_tools_policy_init()).
mcp_tools_policy_check() {
	# $1: tool name; $2: tool metadata JSON string
	return 0
}
