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

# The tool policy, run by the dispatcher before every call: the operator's
# allowlist (deny unless MCPBASH_TOOL_ALLOWLIST or
# MCPBASH_TOOL_ALLOW_DEFAULT=allow|all, see docs/ENV_REFERENCE.md) and the
# tool path validation always run first, then the project's restrict-only
# hook (mcp_tools_policy_project) when server.d/policy.sh defines one. The
# project can only narrow access, never widen it.
# A policy.sh that still defines mcp_tools_policy_check, the 1.x hook that
# replaced the built-in check, fails closed: every call is refused (sets
# MCP_TOOLS_POLICY_LEGACY_HOOK=true). Skipping it instead would silently drop
# the project's own restrictions.
# Args: $1 tool name, $2 tool metadata JSON, $3 call arguments JSON.
mcp_tools_policy_enforce() {
	# shellcheck disable=SC2034  # Read by mcp_tools_call (lib/tools.sh).
	MCP_TOOLS_POLICY_LEGACY_HOOK=false
	if declare -F mcp_tools_policy_check >/dev/null 2>&1; then
		# shellcheck disable=SC2034  # Read by mcp_tools_call (lib/tools.sh).
		MCP_TOOLS_POLICY_LEGACY_HOOK=true
		_MCP_TOOLS_ERROR_CODE=-32602
		# shellcheck disable=SC2016  # $2 and $3 are literal text.
		_MCP_TOOLS_ERROR_MESSAGE='server.d/policy.sh defines mcp_tools_policy_check, the mcp-bash 1.x policy hook, so mcp-bash 2.0 refuses every tool call. In server.d/policy.sh: rename the function to mcp_tools_policy_project; remove its call to mcp_tools_policy_check_default (the built-in checks now run first); read the call arguments from $2 (they were $3; there is no metadata argument); to deny, print the reason and return 1.'
		_MCP_TOOLS_ERROR_DATA=""
		return 1
	fi
	mcp_tools_policy_check_default "$@" || return 1
	mcp_tools_policy_run_project_hook "$@"
}

# Run the project's restrict-only hook, if server.d/policy.sh defines one:
#   mcp_tools_policy_project TOOL_NAME ARGS_JSON
# Exit 0 allows the call; any other status denies it, and what the hook printed
# on stdout becomes the denial message the model and the user see. The hook runs
# inside $(...): the server's stdout is the protocol channel, so the hook must
# never write to it, and variables it sets don't survive the call (keep any
# state in files). On allow its output is discarded. On deny trailing newlines
# are dropped and the message is capped at 1 KiB; an empty message becomes
# "Tool '<name>' denied by server policy".
mcp_tools_policy_run_project_hook() {
	declare -F mcp_tools_policy_project >/dev/null 2>&1 || return 0
	local name="$1"
	local args_json="${3:-}"
	[ -n "${args_json}" ] || args_json='{}'
	local hook_out=""
	local hook_rc=0
	hook_out="$(mcp_tools_policy_project "${name}" "${args_json}")" || hook_rc=$?
	[ "${hook_rc}" -ne 0 ] || return 0

	local message="${hook_out}"
	local byte_len
	byte_len="$(printf '%s' "${message}" | LC_ALL=C wc -c | tr -d ' ')"
	if [ "${byte_len:-0}" -gt 1024 ]; then
		# Cut at 1 KiB, then drop a character the cut split, so the message
		# stays valid UTF-8 (the server drops non-UTF-8 output).
		message="$(printf '%s' "${message}" | head -c 1024)"
		if command -v iconv >/dev/null 2>&1; then
			message="$(printf '%s' "${message}" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null)" || true
		fi
	fi
	if [ -z "${message}" ]; then
		message="Tool '${name}' denied by server policy"
	fi
	_MCP_TOOLS_ERROR_CODE=-32602
	_MCP_TOOLS_ERROR_MESSAGE="${message}"
	_MCP_TOOLS_ERROR_DATA=""
	return 1
}

# Static check (never sources the file; builtins only): does this policy.sh
# define mcp_tools_policy_check, the 1.x hook? The 2.0 dispatcher then
# refuses every tool call. Comment lines don't count; a definition on a line
# with other code does. Used at startup (instructions and stderr), by
# validate and by doctor.
mcp_tools_policy_file_has_legacy_hook() {
	local policy_path="$1" line
	local def='^[[:space:]]*(function[[:space:]]+)?mcp_tools_policy_check[[:space:]]*([(]|[{]|$)'
	[ -f "${policy_path}" ] && [ -r "${policy_path}" ] || return 1
	while IFS= read -r line || [ -n "${line}" ]; do
		[[ ${line} =~ ^[[:space:]]*# ]] && continue
		[[ ${line} =~ ${def} ]] && return 0
	done <"${policy_path}"
	return 1
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
			# A broken install, not a decision about the call: reported as a
			# JSON-RPC error, not as a policy_denied tool result.
			_MCP_TOOLS_POLICY_REFUSAL="config"
			_MCP_TOOLS_ERROR_CODE=-32602
			_MCP_TOOLS_ERROR_MESSAGE="Tool '${name}' path rejected by policy"
			return 1
		fi
	fi

	return 0
}
