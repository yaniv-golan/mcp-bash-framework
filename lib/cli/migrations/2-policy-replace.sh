#!/usr/bin/env bash
# Migration rule; see lib/migrate_rules.sh for the contract.
# shellcheck disable=SC2034  # MIG_* are read by the engine that sources this file
MIG_ID=2-policy-replace
MIG_API=2
MIG_KIND=manual
MIG_SCOPE="server-sh"
MIG_SUMMARY="policy.sh defines mcp_tools_policy_check; 2.0 calls only mcp_tools_policy_project (after the built-in checks)"
MIG_FIX='rename to mcp_tools_policy_project; $2 is the call arguments (JSON); print the denial message to stdout and return 1'
# Auto only when the hook already starts with the default check and uses
# neither $2 (its meaning changes: tool metadata -> call arguments) nor the
# 1.x message globals (the new hook reports through stdout).
mig_detect() {
	local file="$1"
	case "${file##*/}" in policy.sh) ;; *) return 0 ;; esac
	local line
	line="$(grep -nE '^[[:space:]]*(function[[:space:]]+)?mcp_tools_policy_check[[:space:]]*(\(\))?[[:space:]]*\{?[[:space:]]*$' "${file}" | head -n 1 | cut -d: -f1)"
	[ -n "${line}" ] || return 0
	local body
	body="$(awk -v n="${line}" 'NR > n { print } NR > n && /^}/ { exit }' "${file}")"
	local first
	first="$(printf '%s\n' "${body}" | grep -vE '^[[:space:]]*(#.*)?$' | grep -vE 'declare -F mcp_tools_policy_check_default|^[[:space:]]*if[[:space:]]' | head -n 1)"
	local kind=manual
	case "${first}" in
	*'mcp_tools_policy_check_default "$@" || return 1'*)
		if ! printf '%s\n' "${body}" | grep -qE '[$][{]?2|_MCP_TOOLS_ERROR_|mcp_tools_error'; then
			kind=auto
		fi
		;;
	esac
	printf '%s\t%s\t%s\n' "${line}" "${kind}" "mcp_tools_policy_check() {"
}
