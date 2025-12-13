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
	local name="$1"
	local metadata="$2"
	local policy_context="${MCPBASH_TOOL_POLICY_CONTEXT:-}"

	local allow_default="${MCPBASH_TOOL_ALLOW_DEFAULT:-deny}"
	local allow_raw="${MCPBASH_TOOL_ALLOWLIST:-}"

	if [ -z "${allow_raw}" ]; then
		case "${allow_default}" in
		allow | all)
			allow_raw="*"
			;;
		*)
			_MCP_TOOLS_ERROR_CODE=-32602
			if [ "${policy_context}" = "run-tool" ]; then
				_MCP_TOOLS_ERROR_MESSAGE="Tool '${name}' blocked by policy. Try: mcp-bash run-tool ${name} --allow-self ..."
			else
				_MCP_TOOLS_ERROR_MESSAGE="Tool '${name}' blocked by policy. Set MCPBASH_TOOL_ALLOWLIST in your MCP client config."
			fi
			return 1
			;;
		esac
	fi

	local allowed="false"
	local entry
	local IFS=' ,'
	read -r -a _mcp_allowlist <<<"${allow_raw}"
	for entry in "${_mcp_allowlist[@]}"; do
		[ -n "${entry}" ] || continue
		case "${entry}" in
		"*" | "all")
			allowed="true"
			break
			;;
		"${name}")
			allowed="true"
			break
			;;
		esac
	done

	if [ "${allowed}" != "true" ]; then
		_MCP_TOOLS_ERROR_CODE=-32602
		if [ "${policy_context}" = "run-tool" ]; then
			_MCP_TOOLS_ERROR_MESSAGE="Tool '${name}' blocked by policy. Try: mcp-bash run-tool ${name} --allow-self ..."
		else
			_MCP_TOOLS_ERROR_MESSAGE="Tool '${name}' blocked by policy (not in MCPBASH_TOOL_ALLOWLIST)"
		fi
		return 1
	fi

	local path_rel path_abs json_bin
	json_bin="${MCPBASH_JSON_TOOL_BIN:-}"
	if [ -n "${json_bin}" ] && command -v "${json_bin}" >/dev/null 2>&1; then
		path_rel="$(printf '%s' "${metadata}" | "${json_bin}" -r '.path // ""' 2>/dev/null || printf '')"
	else
		path_rel=""
	fi
	if [ -n "${path_rel}" ]; then
		path_abs="${MCPBASH_TOOLS_DIR%/}/${path_rel}"
		if ! mcp_tools_validate_path "${path_abs}"; then
			_MCP_TOOLS_ERROR_CODE=-32602
			_MCP_TOOLS_ERROR_MESSAGE="Tool '${name}' path rejected by policy"
			return 1
		fi
	fi

	return 0
}
