#!/usr/bin/env bash
# Tool-level policy hook (deny-by-default; override via server.d/policy.sh).

set -euo pipefail

: "${MCP_TOOLS_POLICY_LOADED:=false}"
: "${MCP_TOOLS_POLICY_UNSAFE:=}"

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

# Why server.d/policy.sh can't be loaded safely: prints the reason, or
# nothing when there is no policy.sh or it is fine. Insecure ownership or
# permissions, a symlink, or a syntax error (checked with bash -n first: bash
# 3.2 stops the whole shell on a syntax error in a sourced file). Then, from
# 2.0, a file that dies while it is sourced (a failing command under set -e,
# a top-level exit), tried in a subshell; that verdict is cached in the state
# dir with the file's content, so it runs once per server and version of the
# file, and the file's top-level code then runs twice.
mcp_tools_policy_unsafe_reason() {
	[ -n "${MCPBASH_SERVER_DIR:-}" ] || return 0
	local policy_path="${MCPBASH_SERVER_DIR}/policy.sh"
	[ -e "${policy_path}" ] || [ -L "${policy_path}" ] || return 0
	if ! mcp_tools_policy_check_secure_tree "${policy_path}"; then
		printf '%s was not loaded: it, server.d or the project root is writable by group or other users, is a symlink, or is not owned by you. Fix it, for example: chmod go-w "%s" "%s" "%s"' \
			"${policy_path}" "${policy_path}" "${MCPBASH_SERVER_DIR}" "${MCPBASH_PROJECT_ROOT:-.}"
		return 0
	fi
	case "$(mcp_tools_policy_load_verdict "${policy_path}")" in
	ok) ;;
	syntax) printf '%s was not loaded: it has a syntax error (check it with: bash -n "%s")' "${policy_path}" "${policy_path}" ;;
	*) printf '%s was not loaded: it stops while loading (a failing command under set -e, or a top-level exit)' "${policy_path}" ;;
	esac
	return 0
}

# ok, syntax or failed: whether sourcing POLICY_PATH completes, tried in a
# subshell, cached in the state dir against the file's content.
mcp_tools_policy_load_verdict() {
	local policy_path="$1" content="" cache="" cached_content="" verdict=""
	IFS= read -r -d '' content <"${policy_path}" 2>/dev/null || true
	if [ -n "${MCPBASH_STATE_DIR:-}" ] && [ -d "${MCPBASH_STATE_DIR}" ]; then
		cache="${MCPBASH_STATE_DIR}/policy.loads"
		if [ -f "${cache}" ]; then
			{
				IFS= read -r verdict
				IFS= read -r -d '' cached_content || true
			} <"${cache}" 2>/dev/null || true
			if [ -n "${verdict}" ] && [ "${cached_content}" = "${content}" ]; then
				printf '%s' "${verdict}"
				return 0
			fi
		fi
	fi
	if ! "${BASH:-bash}" -n "${policy_path}" 2>/dev/null; then
		verdict=syntax
	else
		# shellcheck disable=SC1090,SC2034
		verdict="$(
			# fd 3 is this capture; everything the file prints is discarded.
			exec 3>&1 </dev/null >/dev/null 2>&1
			exited=false
			# shellcheck disable=SC2329  # Called by a top-level exit in policy.sh.
			exit() { exited=true; }
			. "${policy_path}" || true
			unset -f exit
			[ "${exited}" = "false" ] && printf ok >&3
		)" || true
		[ -n "${verdict}" ] || verdict=failed
	fi
	[ -z "${cache}" ] || printf '%s\n%s' "${verdict}" "${content}" >"${cache}" 2>/dev/null || true
	printf '%s' "${verdict}"
}

# At server start (main process): tell the operator on stderr when policy.sh
# can't be loaded. The policy itself is loaded in each tool call's worker,
# whose stderr is not the server's. Also warms the load verdict's cache.
mcp_tools_policy_startup_check() {
	local reason
	reason="$(mcp_tools_policy_unsafe_reason)"
	[ -n "${reason}" ] || return 0
	printf 'mcp-bash: %s. Every tool call is refused until it can be loaded.\n' "${reason}" >&2
	return 0
}

# Initialize tool policy by sourcing server.d/policy.sh once per process.
# A policy.sh that exists but can't be loaded safely is not sourced, and every
# tool call is refused until it is fixed (MCP_TOOLS_POLICY_UNSAFE holds the
# reason): running without it would drop the project's own restrictions.
mcp_tools_policy_init() {
	if [ "${MCP_TOOLS_POLICY_LOADED}" = "true" ]; then
		return 0
	fi
	MCP_TOOLS_POLICY_LOADED="true"
	MCP_TOOLS_POLICY_UNSAFE="$(mcp_tools_policy_unsafe_reason)"
	if [ -n "${MCP_TOOLS_POLICY_UNSAFE}" ]; then
		if command -v mcp_logging_warning >/dev/null 2>&1; then
			mcp_logging_warning "mcp.tools.policy" "${MCP_TOOLS_POLICY_UNSAFE}" || true
		fi
		return 0
	fi
	local policy_path="${MCPBASH_SERVER_DIR:-}/policy.sh"
	if [ -n "${MCPBASH_SERVER_DIR:-}" ] && [ -f "${policy_path}" ]; then
		# A top-level `exit` would end this worker, and the client would get no
		# answer: catch it while sourcing.
		_MCP_TOOLS_POLICY_EXITED=false
		# shellcheck disable=SC2329  # Called by a top-level exit in policy.sh.
		exit() { _MCP_TOOLS_POLICY_EXITED=true; }
		# shellcheck disable=SC1090
		. "${policy_path}" || true
		unset -f exit
		if [ "${_MCP_TOOLS_POLICY_EXITED}" = "true" ]; then
			MCP_TOOLS_POLICY_UNSAFE="${policy_path} was not loaded: it stops while loading (a top-level exit)"
		fi
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
	if [ -n "${MCP_TOOLS_POLICY_UNSAFE:-}" ]; then
		_MCP_TOOLS_ERROR_CODE=-32602
		_MCP_TOOLS_ERROR_MESSAGE="Tool calls are refused: server.d/policy.sh ${MCP_TOOLS_POLICY_UNSAFE#*/policy.sh }"
		_MCP_TOOLS_ERROR_DATA=""
		return 1
	fi
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

# The operator's allowlist as the policy applies it, builtins only. Sets
# MCP_TOOLS_ALLOWLIST_ALL=true when every tool is allowed ("*"/"all", or
# MCPBASH_TOOL_ALLOW_DEFAULT=allow|all with no list); otherwise false, with
# MCP_TOOLS_ALLOWLIST_NAMES the allowed names, space-separated (empty: deny
# by default, nothing allowed).
# shellcheck disable=SC2034  # The two results are read by the callers.
mcp_tools_policy_allowlist_effective() {
	local raw="${MCPBASH_TOOL_ALLOWLIST:-}" entry
	MCP_TOOLS_ALLOWLIST_ALL=false
	MCP_TOOLS_ALLOWLIST_NAMES=""
	if [ -z "${raw}" ]; then
		case "${MCPBASH_TOOL_ALLOW_DEFAULT:-deny}" in
		allow | all) MCP_TOOLS_ALLOWLIST_ALL=true ;;
		esac
		return 0
	fi
	local IFS=$' ,\t\n' noglob=0
	case $- in *f*) noglob=1 ;; esac
	set -f
	# shellcheck disable=SC2086  # Word splitting on " ," is the point.
	for entry in ${raw}; do
		case "${entry}" in
		'') ;;
		'*' | all)
			MCP_TOOLS_ALLOWLIST_ALL=true
			MCP_TOOLS_ALLOWLIST_NAMES=""
			break
			;;
		*) MCP_TOOLS_ALLOWLIST_NAMES="${MCP_TOOLS_ALLOWLIST_NAMES:+${MCP_TOOLS_ALLOWLIST_NAMES} }${entry}" ;;
		esac
	done
	[ "${noglob}" = 1 ] || set +f
}

mcp_tools_policy_check_default() {
	# $1: tool name; $2: tool metadata JSON string
	local name="$1"
	local metadata="$2"
	local policy_context="${MCPBASH_TOOL_POLICY_CONTEXT:-}"

	# One parser for the listing and the call (mcp_tools_policy_allowlist_effective).
	local allowed="false"
	mcp_tools_policy_allowlist_effective
	if [ "${MCP_TOOLS_ALLOWLIST_ALL}" = "true" ]; then
		allowed="true"
	elif [ -z "${MCPBASH_TOOL_ALLOWLIST:-}" ]; then
		_MCP_TOOLS_ERROR_CODE=-32602
		if [ "${policy_context}" = "run-tool" ]; then
			_MCP_TOOLS_ERROR_MESSAGE="Tool '${name}' blocked by policy. Try: mcp-bash run-tool ${name} --allow-self ..."
		else
			_MCP_TOOLS_ERROR_MESSAGE="Tool '${name}' blocked by policy. Set MCPBASH_TOOL_ALLOWLIST in your MCP client config."
		fi
		return 1
	else
		case " ${MCP_TOOLS_ALLOWLIST_NAMES} " in *" ${name} "*) allowed="true" ;; esac
	fi

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
