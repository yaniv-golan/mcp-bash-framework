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
# permissions, a symlink, a syntax error, or a file that dies while it is
# sourced (a top-level command that fails, a syntax error in a file it
# sources, a top-level exit), tried in a fresh bash process at each start
# (its top-level code then runs one extra time); the workers reuse that
# verdict while the file's content is the same. A file it sources that breaks
# while the server runs is not seen until the next start (a worker's own load
# can't tell on bash 4+: the dispatcher's callers exempt it from errexit),
# except that a worker whose load no longer defines a hook the start check
# saw refuses the call (mcp_tools_policy_init).
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
	ok*) ;;
	syntax) printf '%s was not loaded: it has a syntax error (check it with: bash -n "%s")' "${policy_path}" "${policy_path}" ;;
	*) printf '%s was not loaded: it stops while loading (a top-level command that fails, a syntax error in a file it sources, or a top-level exit)' "${policy_path}" ;;
	esac
	return 0
}

# Whether sourcing POLICY_PATH completes, tried in a new bash process and
# cached in the state dir against the file's content: "syntax", "failed", or
# "ok" followed by the hooks it defines, as ":project" (mcp_tools_policy_project)
# and ":check" (a mcp_tools_policy_check that replaces the built-in one).
mcp_tools_policy_load_verdict() {
	local policy_path="$1" content="" cache="" cached_content="" verdict=""
	IFS= read -r -d '' content <"${policy_path}" 2>/dev/null || true
	# Kept for this server only (its state dir), so the workers don't repeat
	# it: the next start checks again, since a file policy.sh sources may
	# have changed (only policy.sh's own content is compared).
	if [ -n "${MCPBASH_STATE_DIR:-}" ] && [ -d "${MCPBASH_STATE_DIR}" ]; then
		cache="${MCPBASH_STATE_DIR}/policy.loads"
	fi
	if [ -n "${cache}" ] && [ -f "${cache}" ]; then
		{
			IFS= read -r verdict
			IFS= read -r -d '' cached_content || true
		} <"${cache}" 2>/dev/null || true
		if [ -n "${verdict}" ] && [ "${cached_content}" = "${content}" ]; then
			printf '%s' "${verdict}"
			return 0
		fi
	fi
	if ! "${BASH:-bash}" -n "${policy_path}" 2>/dev/null; then
		verdict=syntax
	else
		# A fresh bash process: a subshell would inherit an errexit exemption
		# from any || or if around this call, and then let a failing
		# top-level command through. As strict as a worker on every bash: a
		# top-level command that fails, or one in a file policy.sh sources (a
		# syntax error there), ends the probe. The status of the file as a
		# whole (its last command) is fine: the ERR trap tells that case by
		# where it fires. A new process sees only exported variables: export
		# the server paths a policy.sh may use at its top level, as a worker
		# has them (in this command substitution only).
		# shellcheck disable=SC2016  # The probe script is expanded by the new bash.
		verdict="$(
			export MCPBASH_HOME MCPBASH_PROJECT_ROOT MCPBASH_SERVER_DIR MCPBASH_TOOLS_DIR MCPBASH_STATE_DIR
			exec "${BASH:-bash}" -c '
			exec 3>&1 </dev/null >/dev/null 2>&1
			set -euo pipefail
			probe_self="${BASH_SOURCE[0]:-}"
			exited=false
			_mcp_probe_loaded() {
				local v=ok
				if declare -F mcp_tools_policy_project >/dev/null; then v="${v}:project"; fi
				if declare -F mcp_tools_policy_check >/dev/null; then v="${v}:check"; fi
				printf "%s" "${v}" >&3
			}
			trap "[ \"\${BASH_SOURCE[0]:-}\" = \"\${probe_self}\" ] && [ \"\${exited}\" = false ] && _mcp_probe_loaded" ERR
			exit() { exited=true; }
			. "$1"
			unset -f exit
			trap - ERR
			[ "${exited}" = "false" ] && _mcp_probe_loaded
		' _ "${policy_path}" 2>/dev/null
		)" || true
		[ -n "${verdict}" ] || verdict=failed
	fi
	[ -z "${cache}" ] || printf '%s\n%s' "${verdict}" "${content}" >"${cache}" 2>/dev/null || true
	printf '%s' "${verdict}"
}

# At server start (main process): tell the operator on stderr when policy.sh
# can't be loaded. The policy itself is loaded in each tool call's worker,
# whose stderr is not the server's.
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
		local check_before
		check_before="$(declare -f mcp_tools_policy_check 2>/dev/null || true)"
		# A top-level `exit` would end this worker, and the client would get no
		# answer: catch it while sourcing.
		_MCP_TOOLS_POLICY_EXITED=false
		# shellcheck disable=SC2317,SC2329  # Invoked indirectly: by a top-level exit in policy.sh.
		exit() { _MCP_TOOLS_POLICY_EXITED=true; }
		# shellcheck disable=SC1090
		. "${policy_path}" || true
		unset -f exit
		local verdict=""
		if [ "${_MCP_TOOLS_POLICY_EXITED}" = "true" ]; then
			MCP_TOOLS_POLICY_UNSAFE="${policy_path} was not loaded: it stops while loading (a top-level exit)"
		elif ! declare -F mcp_tools_policy_project >/dev/null 2>&1 \
			|| [ "$(declare -f mcp_tools_policy_check 2>/dev/null || true)" = "${check_before}" ]; then
			# A hook the start check saw is missing from this load: a file
			# policy.sh sources broke since (this load can't see a failure on
			# bash 4+: the callers exempt it from errexit).
			verdict="$(mcp_tools_policy_load_verdict "${policy_path}")"
			if { ! declare -F mcp_tools_policy_project >/dev/null 2>&1 && [ "${verdict}" != "${verdict#*:project}" ]; } \
				|| { [ "$(declare -f mcp_tools_policy_check 2>/dev/null || true)" = "${check_before}" ] && [ "${verdict}" != "${verdict#*:check}" ]; }; then
				MCP_TOOLS_POLICY_UNSAFE="${policy_path} was not loaded: it no longer defines its policy hook (a file it sources changed since the server started; restart the server)"
			fi
		fi
	fi
	return 0
}

# Default policy: deny unless explicitly allowed via MCPBASH_TOOL_ALLOWLIST or
# MCPBASH_TOOL_ALLOW_DEFAULT=allow|all (see docs/ENV_REFERENCE.md), plus tool
# path validation, then the project's restrict-only hook
# (mcp_tools_policy_project) when server.d/policy.sh defines one.
# server.d/policy.sh may instead redefine mcp_tools_policy_check(); a
# redefinition REPLACES this check, so it should call
# `mcp_tools_policy_check_default "$@" || return 1` first and add its own rules.
# Args: $1 tool name, $2 tool metadata JSON, $3 call arguments JSON.
mcp_tools_policy_check() {
	if [ -n "${MCP_TOOLS_POLICY_UNSAFE:-}" ]; then
		_MCP_TOOLS_ERROR_CODE=-32602
		_MCP_TOOLS_ERROR_MESSAGE="Tool calls are refused: server.d/policy.sh ${MCP_TOOLS_POLICY_UNSAFE#*/policy.sh }"
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

# Static check (never sources the file): does this policy.sh redefine
# mcp_tools_policy_check without calling mcp_tools_policy_check_default? Such a
# hook replaces the default deny-by-default allowlist and tool path checks.
# Returns 0 when that is the case. Used by validate and doctor; kept as one
# reusable detector.
mcp_tools_policy_hook_bypasses_default() {
	local policy_path="$1"
	[ -f "${policy_path}" ] || return 1
	# Heuristic: drop comments first so a mention in a comment does not count
	# as a call. Full-line comments and "#" after whitespace are stripped;
	# "$#" and "${#x}" survive (no whitespace before "#"). A "#" inside a
	# quoted string after whitespace is also cut, which can only cause a
	# spurious warning, never hide one.
	local code=""
	code="$(sed -e 's/^[[:space:]]*#.*//' -e 's/[[:space:]]#.*//' "${policy_path}")" || return 1
	# `mcp_tools_policy_check_default()` does not match: "_" follows "check".
	printf '%s\n' "${code}" | grep -Eq '^[[:space:]]*(function[[:space:]]+)?mcp_tools_policy_check[[:space:]]*(\(\)|\{|$)' || return 1
	if printf '%s\n' "${code}" | grep -q 'mcp_tools_policy_check_default'; then
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
