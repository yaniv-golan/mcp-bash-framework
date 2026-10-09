#!/usr/bin/env bash
# Tool-level policy hook (deny-by-default; override via server.d/policy.sh).

set -euo pipefail

: "${MCP_TOOLS_POLICY_LOADED:=false}"

# Security: server.d/policy.sh is full shell code execution. Unlike
# server.d/register.sh (which is opt-in and permission-checked), policy.sh is
# loaded automatically when tool policy initializes. To prevent trivial local
# privilege escalation in shared/writable project directories, require that
# policy.sh (and its parent dirs) are owned by the current user, not symlinks,
# and not group/world writable.
#
# NOTE: This check must live in this file (not lib/registry.sh) because
# bin/mcp-bash sources tools_policy.sh before registry.sh.
mcp_tools_policy_stat_perm_mask() {
	local path="$1"
	local perm_mask=""
	if command -v stat >/dev/null 2>&1; then
		perm_mask="$(stat -c '%a' "${path}" 2>/dev/null || true)"
		if [ -z "${perm_mask}" ]; then
			perm_mask="$(stat -f '%Lp' "${path}" 2>/dev/null || true)"
		fi
	fi
	[ -n "${perm_mask}" ] || return 1
	printf '%s' "${perm_mask}"
}

mcp_tools_policy_stat_uid_gid() {
	local path="$1"
	local uid_gid=""
	if command -v stat >/dev/null 2>&1; then
		uid_gid="$(stat -c '%u:%g' "${path}" 2>/dev/null || true)"
		if [ -z "${uid_gid}" ]; then
			uid_gid="$(stat -f '%u:%g' "${path}" 2>/dev/null || true)"
		fi
	fi
	[ -n "${uid_gid}" ] || return 1
	printf '%s' "${uid_gid}"
}

mcp_tools_policy_check_secure_path() {
	local target="$1"
	[ -n "${target}" ] || return 1
	# Accept files and directories (we validate ownership/perms for both).
	[ -f "${target}" ] || [ -d "${target}" ] || return 1
	# Never source symlinks.
	[ ! -L "${target}" ] || return 1

	local perm_mask perm_bits
	if ! perm_mask="$(mcp_tools_policy_stat_perm_mask "${target}")"; then
		return 1
	fi
	perm_bits=$((8#${perm_mask}))
	# Reject group/world writable.
	if [ $((perm_bits & 0020)) -ne 0 ] || [ $((perm_bits & 0002)) -ne 0 ]; then
		return 1
	fi

	local uid_gid cur_uid cur_gid
	if ! uid_gid="$(mcp_tools_policy_stat_uid_gid "${target}")"; then
		return 1
	fi
	cur_uid="$(id -u 2>/dev/null || printf '0')"
	cur_gid="$(id -g 2>/dev/null || printf '0')"
	case "${uid_gid}" in
	"${cur_uid}:${cur_gid}" | "${cur_uid}:"*) ;;
	*) return 1 ;;
	esac
	return 0
}

mcp_tools_policy_check_secure_tree() {
	local policy_path="$1"
	if ! mcp_tools_policy_check_secure_path "${policy_path}"; then
		return 1
	fi
	local policy_dir
	policy_dir="$(dirname "${policy_path}")"
	if [ -n "${policy_dir}" ] && [ -d "${policy_dir}" ]; then
		if [ -L "${policy_dir}" ]; then
			return 1
		fi
		if ! mcp_tools_policy_check_secure_path "${policy_dir}/."; then
			# Best-effort: some platforms dislike stat on dir/.; fall back to dir.
			if ! mcp_tools_policy_check_secure_path "${policy_dir}"; then
				return 1
			fi
		fi
	fi
	if [ -n "${MCPBASH_PROJECT_ROOT:-}" ] && [ -d "${MCPBASH_PROJECT_ROOT}" ]; then
		if [ -L "${MCPBASH_PROJECT_ROOT}" ]; then
			return 1
		fi
		if ! mcp_tools_policy_check_secure_path "${MCPBASH_PROJECT_ROOT}/."; then
			if ! mcp_tools_policy_check_secure_path "${MCPBASH_PROJECT_ROOT}"; then
				return 1
			fi
		fi
	fi
	return 0
}

# Initialize tool policy by sourcing server.d/policy.sh once per process.
mcp_tools_policy_init() {
	if [ "${MCP_TOOLS_POLICY_LOADED}" = "true" ]; then
		return 0
	fi
	MCP_TOOLS_POLICY_LOADED="true"

	# Project override lives in server.d/policy.sh; source if present/readable.
	local policy_path="${MCPBASH_SERVER_DIR:-}/policy.sh"
	if [ -n "${policy_path}" ] && [ -f "${policy_path}" ]; then
		if ! mcp_tools_policy_check_secure_tree "${policy_path}"; then
			if command -v mcp_logging_warning >/dev/null 2>&1; then
				mcp_logging_warning "mcp.tools.policy" "Refusing to source insecure policy.sh (check ownership/perms/symlink): ${policy_path}"
			else
				printf '%s\n' "mcp-bash: refusing to source insecure policy.sh: ${policy_path}" >&2
			fi
			return 0
		fi
		# shellcheck disable=SC1090
		. "${policy_path}"
	fi
	return 0
}

# Default policy: deny unless explicitly allowed via MCPBASH_TOOL_ALLOWLIST or
# MCPBASH_TOOL_ALLOW_DEFAULT=allow|all (see docs/ENV_REFERENCE.md), plus tool
# path validation. server.d/policy.sh may redefine mcp_tools_policy_check(); a
# redefinition REPLACES this check, so it should call
# `mcp_tools_policy_check_default "$@" || return 1` first and add its own rules.
mcp_tools_policy_check() {
	mcp_tools_policy_check_default "$@"
}

# Static check (never sources the file): does this policy.sh redefine
# mcp_tools_policy_check without calling mcp_tools_policy_check_default? Such a
# hook replaces the default deny-by-default allowlist and tool path checks.
# Returns 0 when that is the case. Used by validate and doctor; kept as one
# reusable detector.
mcp_tools_policy_hook_bypasses_default() {
	local policy_path="$1"
	[ -f "${policy_path}" ] || return 1
	# `mcp_tools_policy_check_default()` does not match: "_" follows "check".
	grep -Eq '^[[:space:]]*(function[[:space:]]+)?mcp_tools_policy_check[[:space:]]*(\(\)|\{|$)' "${policy_path}" || return 1
	if grep -q 'mcp_tools_policy_check_default' "${policy_path}"; then
		return 1
	fi
	return 0
}

mcp_tools_policy_check_default() {
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
