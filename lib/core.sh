#!/usr/bin/env bash
# Lifecycle bootstrap, concurrency, cancellation, timeouts, stdout discipline.

set -euo pipefail

MCPBASH_MAIN_PGID=""
MCPBASH_SHUTDOWN_PENDING=false
MCPBASH_NO_RESPONSE="__MCP_NO_RESPONSE__"
MCPBASH_INITIALIZE_HANDSHAKE_DONE=false
MCPBASH_HANDLER_OUTPUT=""
MCPBASH_SHUTDOWN_WATCHDOG_PID=""
MCPBASH_SHUTDOWN_WATCHDOG_CANCEL=""
MCPBASH_EXIT_REQUESTED=false
MCPBASH_PROGRESS_FLUSHER_PID=""
MCPBASH_RESOURCE_POLL_PID=""
MCPBASH_LIFELINE_PID=""
# Set when a resources/subscribe is dispatched; see mcp_core_maybe_start_background_workers.
MCPBASH_RESOURCE_POLL_WANTED=false
MCPBASH_LAST_REGISTRY_POLL=""

# Zombie process mitigation (idle timeout + orphan detection)
MCPBASH_ORIGINAL_PPID=""
MCPBASH_IDLE_TIMEOUT_TRIGGERED=false
MCPBASH_ORPHAN_DETECTED=false
_MCPBASH_SIGNAL_RECEIVED=""
_MCPBASH_CLEANUP_DONE=false
# Set just before each intended `exit 0`. Bash 3.2 runs the EXIT trap with
# $? = 0 after a fatal shell error (an unbound variable under set -u, for
# example), so a zero status without this flag means the server died.
_MCPBASH_EXIT_CLEAN=false

# EXIT trap handler with idempotency guard.
# Ensures cleanup runs exactly once, whether from normal exit or signal.
_mcp_exit_handler() {
	local exit_code=$?
	# The trap runs with the IFS of whatever it interrupted (several functions
	# set a local IFS without a newline): restore the default for cleanup.
	local IFS=$' \t\n'
	if [ "${exit_code}" -eq 0 ] && [ "${_MCPBASH_EXIT_CLEAN}" != "true" ]; then
		exit_code=1
	fi
	if [ "${_MCPBASH_CLEANUP_DONE}" != "true" ]; then
		_MCPBASH_CLEANUP_DONE=true
		if declare -F mcp_io_report_stdout_gone >/dev/null 2>&1; then
			mcp_io_report_stdout_gone
		fi
		# An abnormal exit (signal, failed stdout write, fatal error): nobody
		# can receive the running workers' results, so stop them and their
		# tools instead of leaving them running on their own.
		if declare -F mcp_core_stop_all_workers >/dev/null 2>&1; then
			mcp_core_stop_all_workers 2>/dev/null || true
		fi
		mcp_runtime_cleanup 2>/dev/null || true
	fi
	exit ${exit_code}
}
MCPBASH_DEFAULT_MAX_CONCURRENT_REQUESTS="${MCPBASH_DEFAULT_MAX_CONCURRENT_REQUESTS:-16}"
MCPBASH_DEFAULT_MAX_OUTPUT_BYTES="${MCPBASH_DEFAULT_MAX_OUTPUT_BYTES:-10485760}"
MCPBASH_DEFAULT_PROGRESS_PER_MIN="${MCPBASH_DEFAULT_PROGRESS_PER_MIN:-100}"
MCPBASH_DEFAULT_TOOL_TIMEOUT="${MCPBASH_DEFAULT_TOOL_TIMEOUT:-30}"
MCPBASH_DEFAULT_SUBSCRIBE_TIMEOUT="${MCPBASH_DEFAULT_SUBSCRIBE_TIMEOUT:-120}"
MCPBASH_DEFAULT_RESOURCE_TIMEOUT="${MCPBASH_DEFAULT_RESOURCE_TIMEOUT:-120}"
MCPBASH_SHUTDOWN_TIMEOUT="${MCPBASH_SHUTDOWN_TIMEOUT:-5}"

mcp_register_tool() {
	local payload="$1"
	mcp_tools_register_manual "${payload}"
}

mcp_register_resource() {
	local payload="$1"
	mcp_resources_register_manual "${payload}"
}

mcp_register_prompt() {
	local payload="$1"
	mcp_prompts_register_manual "${payload}"
}

mcp_core_run() {
	# Args: (none) - sets up handlers, state, main read loop, and waits for workers.
	mcp_core_require_handlers
	mcp_core_bootstrap_state
	mcp_core_read_loop
	mcp_core_finish_after_read_loop
}

mcp_core_require_handlers() {
	. "${MCPBASH_HOME}/lib/handler_helpers.sh"
	. "${MCPBASH_HOME}/handlers/lifecycle.sh"
	. "${MCPBASH_HOME}/handlers/ping.sh"
	. "${MCPBASH_HOME}/handlers/logging.sh"
	. "${MCPBASH_HOME}/handlers/tools.sh"
	. "${MCPBASH_HOME}/handlers/resources.sh"
	. "${MCPBASH_HOME}/handlers/prompts.sh"
	. "${MCPBASH_HOME}/handlers/completion.sh"
	. "${MCPBASH_HOME}/handlers/roots.sh"
	. "${MCPBASH_HOME}/handlers/discover.sh"
}

mcp_core_bootstrap_state() {
	# Capture original PPID early for orphan detection (before any defaults are applied)
	mcp_core_capture_original_ppid

	# Set up EXIT trap for cleanup (runs on normal exit and signals)
	trap '_mcp_exit_handler' EXIT

	MCPBASH_INITIALIZED=false
	MCPBASH_SHUTDOWN_PENDING=false
	MCPBASH_INITIALIZE_HANDSHAKE_DONE=false
	_MCP_NOTIFICATION_PAYLOAD=""
	mcp_runtime_init_paths
	# Sync MCP logging level with MCPBASH_LOG_LEVEL (may be set by .debug file detection)
	if [ -n "${MCPBASH_LOG_LEVEL:-}" ]; then
		mcp_logging_set_level "${MCPBASH_LOG_LEVEL}"
	fi
	if ! mcp_auth_init; then
		exit 1
	fi
	mcp_runtime_load_server_meta
	mcp_meta_env_apply
	mcp_ids_init_state
	mcp_lock_init
	mcp_io_init
	mcp_runtime_enable_job_control
	. "${MCPBASH_HOME}/lib/timeout.sh"
	MCPBASH_MAIN_PGID="$(mcp_runtime_lookup_pgid "$$")"
	MCPBASH_MAX_CONCURRENT_REQUESTS="${MCPBASH_MAX_CONCURRENT_REQUESTS:-${MCPBASH_DEFAULT_MAX_CONCURRENT_REQUESTS}}"
	MCPBASH_MAX_TOOL_OUTPUT_SIZE="${MCPBASH_MAX_TOOL_OUTPUT_SIZE:-${MCPBASH_DEFAULT_MAX_OUTPUT_BYTES}}"
	MCPBASH_MAX_PROGRESS_PER_MIN="${MCPBASH_MAX_PROGRESS_PER_MIN:-${MCPBASH_DEFAULT_PROGRESS_PER_MIN}}"
	MCPBASH_MAX_LOGS_PER_MIN="${MCPBASH_MAX_LOGS_PER_MIN:-${MCPBASH_MAX_PROGRESS_PER_MIN}}"
	MCPBASH_DEFAULT_TOOL_TIMEOUT="${MCPBASH_DEFAULT_TOOL_TIMEOUT:-30}"
	MCPBASH_DEFAULT_SUBSCRIBE_TIMEOUT="${MCPBASH_DEFAULT_SUBSCRIBE_TIMEOUT:-120}"
	MCPBASH_DEFAULT_RESOURCE_TIMEOUT="${MCPBASH_DEFAULT_RESOURCE_TIMEOUT:-120}"
	MCPBASH_SHUTDOWN_TIMEOUT="${MCPBASH_SHUTDOWN_TIMEOUT:-5}"
	MCPBASH_SHUTDOWN_TIMER_STARTED=false
	MCPBASH_RESOURCE_POLL_PID=""
	MCPBASH_CLIENT_SUPPORTS_ELICITATION=0
	# shellcheck disable=SC2034  # Used by RPC helpers in lib/rpc.sh
	MCPBASH_NEXT_OUTGOING_ID=1
	printf '%s' "1" >"${MCPBASH_STATE_DIR}/next.outgoing.id" 2>/dev/null || true
	rm -f "${MCPBASH_STATE_DIR}"/elicit.*.id 2>/dev/null || true
	rm -f "${MCPBASH_STATE_DIR}"/pending.*.path 2>/dev/null || true

	# setup SDK notification streams
	MCP_PROGRESS_STREAM="${MCPBASH_STATE_DIR}/progress.ndjson"
	MCP_LOG_STREAM="${MCPBASH_STATE_DIR}/logs.ndjson"
	: >"${MCP_PROGRESS_STREAM}"
	: >"${MCP_LOG_STREAM}"
	mcp_runtime_log_startup_summary
	# Prints why policy.sh can't be loaded, if so (mcp_tools_policy_startup_check).
	mcp_core_check_policy_hook
	mcp_core_start_deprecation_notice
}

# Set once per start: true when server.d/policy.sh defines the 1.x hook
# mcp_tools_policy_check, so every tool call is refused (lib/tools_policy.sh).
# The instructions say so, and stderr says it once per start. Static and
# builtins only: the file isn't sourced here.
MCP_CORE_POLICY_LEGACY_HOOK=false
# Also set once per start: true when policy.sh exists but can't be loaded
# safely (see mcp_tools_policy_init), so every call is refused.
MCP_CORE_POLICY_BROKEN=false
mcp_core_check_policy_hook() {
	MCP_CORE_POLICY_LEGACY_HOOK=false
	MCP_CORE_POLICY_BROKEN=false
	local policy="${MCPBASH_SERVER_DIR:-}/policy.sh"
	[ -n "${MCPBASH_SERVER_DIR:-}" ] && [ -e "${policy}" ] || return 0
	declare -F mcp_tools_policy_file_has_legacy_hook >/dev/null 2>&1 || return 0
	# The same checks a call makes (the load verdict is cached in the state
	# dir, so the workers don't repeat it); stderr names the reason.
	if [ -n "$(mcp_tools_policy_unsafe_reason)" ]; then
		MCP_CORE_POLICY_BROKEN=true
		mcp_tools_policy_startup_check || true
		return 0
	fi
	mcp_tools_policy_file_has_legacy_hook "${policy}" || return 0
	MCP_CORE_POLICY_LEGACY_HOOK=true
	# shellcheck disable=SC2016  # Backticks are literal text.
	printf '%s\n' 'mcp-bash: server.d/policy.sh defines mcp_tools_policy_check, the 1.x policy hook; mcp-bash 2.0 refuses every tool call until it is renamed to mcp_tools_policy_project (run `mcp-bash migrate`)' >&2
}

# Migrate rules about SDK helpers removed in 2.0 (their findings feed the
# instructions note; lib/tools.sh blocks the tools that use them).
MCP_CORE_REMOVED_API_RULES="2-mcp-error 2-result-error 2-fail-invalid-args 2-result-success 2-emit-helpers 2-text-with-resource 2-ui-resource-uri"

# True when the startup scan can run: not for bundles (static registry),
# minimal mode or a vendored runtime without the rule engine, and only with
# a project and a writable registry dir. The instructions note relies on the
# same test: a findings file the scan can't refresh is never trusted.
mcp_core_startup_scan_possible() {
	[ "${MCPBASH_STATIC_REGISTRY:-0}" = "1" ] && return 1
	mcp_runtime_is_minimal_mode && return 1
	[ -f "${MCPBASH_HOME}/lib/migrate_rules.sh" ] || return 1
	[ -n "${MCPBASH_PROJECT_ROOT:-}" ] && [ -d "${MCPBASH_PROJECT_ROOT}" ] || return 1
	[ -n "${MCPBASH_REGISTRY_DIR:-}" ] && [ -d "${MCPBASH_REGISTRY_DIR}" ] && [ -w "${MCPBASH_REGISTRY_DIR}" ] || return 1
}

# Set by mcp_core_start_deprecation_notice, once per start: 1 when the scan
# can run, so the instructions note may trust the findings file.
MCP_CORE_REMOVED_API_NOTE_ON=0

# The instructions sent by initialize and server/discover, into
# MCP_CORE_INSTRUCTIONS: the project's server.instructions.md, then a sentence
# when the last startup scan found removed SDK helpers in the project. Reads
# the findings file only, never scans; no process is started unless the file
# has entries.
mcp_core_build_instructions() {
	MCP_CORE_INSTRUCTIONS="${MCPBASH_SERVER_INSTRUCTIONS:-}"
	# From the environment only (no registry load): the allowlist decides
	# what tools/list shows.
	if declare -F mcp_tools_policy_allowlist_effective >/dev/null 2>&1; then
		mcp_tools_policy_allowlist_effective
		if [ "${MCP_TOOLS_ALLOWLIST_ALL}" != "true" ]; then
			MCP_CORE_INSTRUCTIONS="${MCP_CORE_INSTRUCTIONS:+${MCP_CORE_INSTRUCTIONS}$'\n\n'}Tools outside the server operator's allowlist (MCPBASH_TOOL_ALLOWLIST) are not listed and can't be called."
		fi
	fi
	if [ "${MCP_CORE_POLICY_BROKEN}" = "true" ]; then
		MCP_CORE_INSTRUCTIONS="${MCP_CORE_INSTRUCTIONS:+${MCP_CORE_INSTRUCTIONS}$'\n\n'}This server's tool policy (server.d/policy.sh) can't be loaded, so every tool call is refused until the server's operator fixes it."
	elif [ "${MCP_CORE_POLICY_LEGACY_HOOK}" = "true" ]; then
		# shellcheck disable=SC2016  # Backticks are literal text.
		MCP_CORE_INSTRUCTIONS="${MCP_CORE_INSTRUCTIONS:+${MCP_CORE_INSTRUCTIONS}$'\n\n'}This server's tool policy (server.d/policy.sh) uses the mcp-bash 1.x hook, so every tool call is refused until it is migrated (\`mcp-bash migrate\`)."
	fi
	local findings="${MCPBASH_REGISTRY_DIR:-}/scan/removed-api.findings"
	[ "${MCP_CORE_REMOVED_API_NOTE_ON}" = 1 ] && [ -s "${findings}" ] || return 0
	local files="" n=0 line note
	while IFS= read -r line; do
		[ -n "${line}" ] || continue
		n=$((n + 1))
		[ "${n}" -le 3 ] && files="${files:+${files} }${line}"
	done <"${findings}"
	[ "${n}" -gt 0 ] || return 0
	[ "${n}" -gt 3 ] && files="${files} and $((n - 3)) more"
	# shellcheck disable=SC2016  # Backticks are literal text.
	note="Some of this server's scripts call mcp-bash helpers removed in 2.0 (in ${files}): tools that use them return an error until they are migrated (\`mcp-bash migrate\` lists the changes)."
	MCP_CORE_INSTRUCTIONS="${MCP_CORE_INSTRUCTIONS:+${MCP_CORE_INSTRUCTIONS}$'\n\n'}${note}"
}

# The startup scan, in the background, never on the request path:
# - removed-api.findings lists the project files that
#   call an SDK helper removed in 2.0 (the rules in
#   MCP_CORE_REMOVED_API_RULES), for the instructions note;
# - once a day it runs every rule instead and prints one line to stderr with
#   the number of uses of APIs that change in 2.0 (the stamp holds the date).
# A new framework version always rescans. Otherwise a scan is started at
# most once an hour per project (removed-api.attempt is
# touched as it starts, so a scan cut short by a server that exits doesn't
# start again on every launch), and only when the rules (lib/core.sh, the
# rule engine and the rule files) or a file under the project changed since
# the last completed one (removed-api.scan, whose mtime is the time that scan
# started). Where find compares whole seconds (BusyBox), an edit in the same
# second as a scan start waits for the next change; so do files replaced
# with an older mtime (cp -p) and tools or server dirs outside the project.
mcp_core_start_deprecation_notice() {
	MCP_CORE_REMOVED_API_NOTE_ON=0
	# MCPBASH_DEPRECATION_NOTICE=false turns the scan off, and with it the
	# stderr line and the instructions note (a findings file nothing
	# refreshes isn't trusted). Tools calling removed helpers still get
	# migration_required per call.
	case "${MCPBASH_DEPRECATION_NOTICE:-true}" in
	false | 0 | no | off) return 0 ;;
	esac
	mcp_core_startup_scan_possible || return 0
	MCP_CORE_REMOVED_API_NOTE_ON=1
	local project_root="${MCPBASH_PROJECT_ROOT}"
	local registry_dir="${MCPBASH_REGISTRY_DIR}"
	# The scan's files live in .registry/scan, which ignores itself in git
	# (projects that commit .registry don't see them as untracked).
	local scan_dir="${registry_dir}/scan"
	local stamp="${scan_dir}/deprecation-notice.stamp"
	local findings="${scan_dir}/removed-api.findings"
	local scan_meta="${scan_dir}/removed-api.scan"
	local attempt="${scan_dir}/removed-api.attempt"

	(
		set +e
		if [ ! -f "${scan_dir}/.gitignore" ]; then
			mkdir -p "${scan_dir}" 2>/dev/null && printf '*\n' >"${scan_dir}/.gitignore" 2>/dev/null || exit 0
		fi
		announce=0
		today="$(date +%Y-%m-%d 2>/dev/null)" || today=""
		last=""
		[ -f "${stamp}" ] && IFS= read -r last <"${stamp}" 2>/dev/null
		if [ -n "${today}" ] && [ "${last}" != "${today}" ] && printf '%s\n' "${today}" >"${stamp}" 2>/dev/null; then
			announce=1
		fi
		# The record names the framework version that wrote it: an upgrade
		# always rescans, whatever file times it installed.
		version=""
		recorded=""
		[ -f "${MCPBASH_HOME}/VERSION" ] && IFS= read -r version <"${MCPBASH_HOME}/VERSION" 2>/dev/null
		[ -f "${scan_meta}" ] && IFS= read -r recorded <"${scan_meta}" 2>/dev/null
		if [ "${announce}" = 0 ] && [ "${recorded}" = "${version}" ]; then
			# A scan started within the hour, finished or not: nothing to do.
			[ -f "${attempt}" ] && [ -n "$(find "${attempt}" -mmin -60 2>/dev/null)" ] && exit 0
			if [ -f "${scan_meta}" ] && [ -f "${findings}" ]; then
				changed=0
				for f in "${MCPBASH_HOME}/lib/core.sh" "${MCPBASH_HOME}/lib/migrate_rules.sh" "${MCPBASH_HOME}"/lib/cli/migrations/*.sh; do
					if [ "${f}" -nt "${scan_meta}" ]; then
						changed=1
						break
					fi
				done
				if [ "${changed}" = 0 ] && [ -z "$(find "${project_root}" \( -name .git -o -name .registry -o -name node_modules -o -name .mcp-bash \) -prune -o -newer "${scan_meta}" -print 2>/dev/null | head -n 1)" ]; then
					exit 0
				fi
			fi
		fi
		: >"${attempt}" 2>/dev/null
		started="$(mktemp "${scan_meta}.XXXXXX" 2>/dev/null)" || started=""
		# shellcheck source=lib/migrate_rules.sh disable=SC1091
		. "${MCPBASH_HOME}/lib/migrate_rules.sh" || exit 0
		# One rule at a time, stopping as soon as the server is gone ($$ is the
		# server's PID even in this subshell): background helpers must not
		# outlive a server that was killed. Only the removed-helper rules,
		# unless the stderr line is due.
		count=0
		removed_tmp="$(mktemp "${findings}.XXXXXX" 2>/dev/null)" || removed_tmp=""
		while IFS= read -r rule; do
			if ! mcp_core_server_alive; then
				rm -f "${removed_tmp}" "${started}"
				exit 0
			fi
			id="${rule##*/}"
			id="${id%.sh}"
			removed=0
			case " ${MCP_CORE_REMOVED_API_RULES} " in *" ${id} "*) removed=1 ;; esac
			[ "${removed}" = 1 ] || [ "${announce}" = 1 ] || continue
			out="$(mcp_migrate_detect "${project_root}" --validate --only "${id}" 2>/dev/null)"
			[ -n "${out}" ] || continue
			n="$(printf '%s\n' "${out}" | grep -c .)"
			case "${n}" in '' | *[!0-9]*) n=0 ;; esac
			count=$((count + n))
			if [ "${removed}" = 1 ] && [ -n "${removed_tmp}" ]; then
				printf '%s\n' "${out}" | awk -F'\t' '{ print $3 }' >>"${removed_tmp}"
			fi
		done <<EOF_RULES
$(mcp_migrate_rule_files 2>/dev/null)
EOF_RULES
		if ! mcp_core_server_alive; then
			rm -f "${removed_tmp}" "${started}"
			exit 0
		fi
		if [ -n "${removed_tmp}" ]; then
			LC_ALL=C sort -u "${removed_tmp}" >"${removed_tmp}.sorted" 2>/dev/null && mv -f "${removed_tmp}.sorted" "${findings}" 2>/dev/null
			rm -f "${removed_tmp}" "${removed_tmp}.sorted"
		fi
		if [ -n "${started}" ]; then
			# The record holds the framework version; its mtime is the time this
			# scan started.
			printf '%s\n' "${version}" >"${started}.new" 2>/dev/null \
				&& touch -r "${started}" "${started}.new" 2>/dev/null \
				&& mv -f "${started}.new" "${scan_meta}" 2>/dev/null
			rm -f "${started}" "${started}.new"
		fi
		[ "${announce}" = 1 ] && [ "${count}" -gt 0 ] || exit 0
		noun="uses"
		[ "${count}" -eq 1 ] && noun="use"
		# shellcheck disable=SC2016  # Backticks are literal text.
		printf 'mcp-bash: %s %s of APIs that change in mcp-bash 2.0; run `mcp-bash validate` for details\n' "${count}" "${noun}" >&2
	) </dev/null >/dev/null &
	# Not a worker: keep it out of `jobs -p`, so shutdown doesn't wait for it.
	disown "$!" 2>/dev/null || true
}

# Whether the server is still running, for background helpers ($$ is the
# server's PID in their subshells too). kill -0 alone also succeeds while a
# killed server is a zombie its parent has not reaped yet, so the state is
# checked too: /proc on Linux, else ps. When neither gives a clear answer
# (no ps, or a ps without -p that lists everything), kill -0 decides.
mcp_core_server_alive() {
	kill -0 "$$" 2>/dev/null || return 1
	local state=""
	if [ -r "/proc/$$/stat" ]; then
		# A builtin read: helpers call this every tick.
		IFS= read -r state <"/proc/$$/stat" 2>/dev/null || true
		state="${state##*) }"
		state="${state%% *}"
	else
		state="$(ps -o stat= -p "$$" 2>/dev/null || true)"
		case "${state}" in
		*$'\n'*) state="" ;;
		esac
		state="${state//[[:space:]]/}"
	fi
	case "${state}" in
	Z*) return 1 ;;
	esac
	return 0
}

mcp_core_has_resource_subscriptions() {
	[ -n "${MCPBASH_STATE_DIR:-}" ] || return 1
	local path
	for path in "${MCPBASH_STATE_DIR}"/resource_subscription.*; do
		if [ -f "${path}" ]; then
			return 0
		fi
	done
	return 1
}

mcp_core_maybe_start_background_workers() {
	# Start the progress flusher only when needed:
	# - live progress enabled (streams while tools run), OR
	# - elicitation supported (needed even when stdin is idle).
	if [ "${MCPBASH_ENABLE_LIVE_PROGRESS:-false}" = "true" ]; then
		mcp_core_start_progress_flusher
	elif declare -F mcp_elicitation_is_supported >/dev/null 2>&1; then
		if mcp_elicitation_is_supported; then
			mcp_core_start_progress_flusher
		fi
	fi

	# Start resource subscription polling once a subscribe has been dispatched
	# or a subscription record exists. resources/subscribe runs in a worker, so
	# its record usually does not exist yet when this runs right after dispatch;
	# waiting for the record would delay polling until the next client message.
	if [ "${MCPBASH_RESOURCE_POLL_WANTED}" = "true" ] || mcp_core_has_resource_subscriptions; then
		mcp_core_start_resource_poll
	fi
}

# Capture original PPID at startup for orphan detection.
# Must be called early in bootstrap before any defaults are applied.
mcp_core_capture_original_ppid() {
	MCPBASH_ORIGINAL_PPID="${PPID:-}"

	# Platform detection MUST run before defaults are applied.
	# Disable orphan detection on Windows/Cygwin/MSYS where PPID semantics differ.
	# Also disable in CI mode where process trees are managed differently.
	case "$(uname -s 2>/dev/null)" in
	CYGWIN* | MINGW* | MSYS*)
		MCPBASH_ORPHAN_CHECK_ENABLED="${MCPBASH_ORPHAN_CHECK_ENABLED:-false}"
		;;
	*)
		if [ "${MCPBASH_CI_MODE:-false}" = "true" ]; then
			MCPBASH_ORPHAN_CHECK_ENABLED="${MCPBASH_ORPHAN_CHECK_ENABLED:-false}"
		else
			MCPBASH_ORPHAN_CHECK_ENABLED="${MCPBASH_ORPHAN_CHECK_ENABLED:-true}"
		fi
		;;
	esac

	# If already orphaned at startup (PPID=1), disable orphan detection
	if [ "${MCPBASH_ORIGINAL_PPID}" = "1" ]; then
		MCPBASH_ORPHAN_CHECK_ENABLED="false"
	fi
}

# Check if we've been orphaned (original parent process died).
# Works regardless of whether orphans are reparented to PID 1 or a subreaper.
mcp_core_check_orphaned() {
	[ "${MCPBASH_ORPHAN_CHECK_ENABLED:-true}" = "true" ] || return 1
	[ -n "${MCPBASH_ORIGINAL_PPID:-}" ] || return 1
	[ "${MCPBASH_ORIGINAL_PPID}" != "1" ] || return 1

	# Check if original parent is still alive using multiple methods:
	# 1. /proc check (Linux) - most reliable
	# 2. kill -0 - works if we have permission
	# 3. ps fallback - handles EPERM case where kill -0 fails
	if [ -d "/proc/${MCPBASH_ORIGINAL_PPID}" ]; then
		return 1 # Parent still alive
	elif kill -0 "${MCPBASH_ORIGINAL_PPID}" 2>/dev/null; then
		return 1 # Parent still alive
	elif ps -p "${MCPBASH_ORIGINAL_PPID}" >/dev/null 2>&1; then
		return 1 # Parent still alive (handles EPERM case)
	fi

	return 0 # Parent not found - we're orphaned
}

mcp_core_handle_orphaned() {
	if [ "${MCPBASH_LOG_LEVEL:-info}" = "debug" ] || [ "${MCPBASH_CI_MODE:-false}" = "true" ]; then
		printf '%s\n' "mcp-bash: process orphaned (original parent PID ${MCPBASH_ORIGINAL_PPID} no longer exists); exiting" >&2
	fi

	if [ "${MCPBASH_INITIALIZED:-false}" = "true" ]; then
		if mcp_logging_is_enabled "warning"; then
			mcp_logging_warning "mcp.core" "Process orphaned - original parent PID ${MCPBASH_ORIGINAL_PPID} no longer exists"
		fi
	fi

	MCPBASH_ORPHAN_DETECTED=true
}

mcp_core_handle_idle_timeout() {
	local timeout="$1"

	# Always log to stderr so users understand the exit reason
	printf '%s\n' "mcp-bash: idle timeout after ${timeout}s with no client activity; exiting" >&2

	if [ "${MCPBASH_INITIALIZED:-false}" = "true" ]; then
		if mcp_logging_is_enabled "warning"; then
			mcp_logging_warning "mcp.core" "Server idle timeout (${timeout}s) - no client activity"
		fi
	fi

	MCPBASH_IDLE_TIMEOUT_TRIGGERED=true
}

mcp_core_read_loop() {
	local line
	local idle_timeout="${MCPBASH_IDLE_TIMEOUT:-3600}"
	local idle_enabled="${MCPBASH_IDLE_TIMEOUT_ENABLED:-true}"
	local orphan_interval="${MCPBASH_ORPHAN_CHECK_INTERVAL:-30}"
	local orphan_enabled="${MCPBASH_ORPHAN_CHECK_ENABLED:-true}"

	# Disable zombie mitigations in CI mode to preserve simple read loop behavior
	if [ "${MCPBASH_CI_MODE:-false}" = "true" ]; then
		idle_enabled="false"
		orphan_enabled="false"
	fi

	# Validate/normalize timeout values
	case "${idle_timeout}" in
	'' | *[!0-9]*) idle_timeout=3600 ;;
	0) idle_enabled="false" ;;
	esac
	case "${orphan_interval}" in
	'' | *[!0-9]*) orphan_interval=30 ;;
	0) orphan_interval=30 ;;
	esac
	# Minimum interval of 1 second to prevent busy loop
	if [ "${orphan_interval}" -lt 1 ]; then
		orphan_interval=1
	fi

	# Honor the enable flag
	if [ "${idle_enabled}" = "false" ]; then
		idle_timeout=0
	fi

	# Determine read timeout: use orphan interval for periodic checks,
	# but cap at idle_timeout if it's shorter and enabled
	local read_timeout="${orphan_interval}"
	if [ "${idle_timeout}" -gt 0 ] && [ "${idle_timeout}" -lt "${orphan_interval}" ]; then
		read_timeout="${idle_timeout}"
	fi

	# If both features are disabled, use blocking read (no timeout)
	local use_timeout="true"
	if [ "${idle_timeout}" -eq 0 ] && [ "${orphan_enabled}" != "true" ]; then
		use_timeout="false"
	fi

	# Exit straight from the signal trap. A trap that only records the signal
	# runs after the pending `read` returns, so TERM/INT waited out the full
	# read timeout (or, with a blocking read, the next input line). Exiting
	# here still runs the EXIT trap (_mcp_exit_handler) for cleanup.
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM

	# Track idle time using wall clock for accuracy
	local idle_start
	idle_start=$(date +%s)

	# For EOF detection heuristic: track consecutive immediate returns
	local immediate_returns=0

	# A request whose bytes straddle the read timeout must not be split or lost.
	# bash 4+ returns the bytes read so far with a timeout status; they are kept
	# here and joined with the next read. bash 3.2 discards them instead, so on
	# 3.2 only the first character is read with a timeout and the rest of the
	# line with a blocking read (a client mid-request is alive; if it goes away,
	# the read returns at end of input).
	local partial=""
	local first_char=""
	local rest_status=0

	while true; do
		# Clear line before read to prevent stale data on timeout/EOF
		line=""
		_MCPBASH_SIGNAL_RECEIVED=""

		if [ "${use_timeout}" = "true" ]; then
			local read_start read_end read_elapsed
			read_start=$(date +%s)

			# Capture exit status in a way that prevents set -e from aborting on timeout/EOF
			local read_status=0
			if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
				IFS= read -t "${read_timeout}" -r line || read_status=$?
				if [ "${read_status}" -gt 128 ]; then
					# Timed out, possibly mid-line: keep the bytes, don't answer a
					# fragment.
					partial="${partial}${line}"
					line=""
				elif [ -n "${partial}" ]; then
					# A full line, or end of input: join the kept bytes.
					line="${partial}${line}"
					partial=""
				fi
			else
				first_char=""
				IFS= read -t "${read_timeout}" -r -n 1 first_char || read_status=$?
				if [ "${read_status}" -eq 0 ] && [ -n "${first_char}" ]; then
					rest_status=0
					IFS= read -r line || rest_status=$?
					line="${first_char}${line}"
					if [ "${rest_status}" -ne 0 ]; then
						# End of input after a final line without a newline.
						[ -n "${_MCPBASH_SIGNAL_RECEIVED}" ] || mcp_core_handle_line "${line}"
						line=""
						break
					fi
				fi
			fi

			read_end=$(date +%s)
			read_elapsed=$((read_end - read_start))

			if [ ${read_status} -ne 0 ]; then
				# Check for signal first (portable - works on bash 3.2+)
				if [ -n "${_MCPBASH_SIGNAL_RECEIVED}" ]; then
					case "${_MCPBASH_SIGNAL_RECEIVED}" in
					INT) exit 130 ;;
					TERM) exit 143 ;;
					*) exit 1 ;;
					esac
				fi

				# bash >= 4 reports a read timeout as >128, so status 1 is an
				# unambiguous EOF. Answer a final line that had no newline (with
				# any bytes kept from earlier timeouts), then stop: on a FIFO whose
				# writer closed, later reads time out instead of returning EOF
				# again, which would starve the consecutive-quick-returns heuristic
				# below.
				if [ "${BASH_VERSINFO[0]}" -ge 4 ] && [ "${read_status}" -eq 1 ]; then
					[ -n "${line}" ] && mcp_core_handle_line "${line}"
					break
				fi

				# Timing heuristic for EOF detection (bash 3.2 compatibility).
				# On bash >= 4 a status > 128 is a timeout, never EOF.
				# On bash 3.2 a timeout also returns 1, but only after the full
				# timeout: whole-second `date` deltas for a read that waited
				# read_timeout seconds are >= read_timeout, while EOF returns at
				# once. So "quick" means strictly less than the timeout; a fixed
				# threshold misread 1-2s timeouts as EOF and exited idle servers.
				local quick_return=false
				if [ "${BASH_VERSINFO[0]}" -lt 4 ] && [ "${read_elapsed}" -lt "${read_timeout}" ]; then
					quick_return=true
				fi

				if [ "${quick_return}" = "true" ]; then
					immediate_returns=$((immediate_returns + 1))
					# 3 consecutive immediate returns = definitely EOF
					if [ ${immediate_returns} -ge 3 ]; then
						break
					fi
					# Backoff to prevent busy loop on EOF with short timeouts
					if [ "${read_timeout}" -le 2 ] && [ ${immediate_returns} -ge 1 ]; then
						sleep 1 2>/dev/null || true
					fi
				else
					immediate_returns=0
				fi

				# Check wall-clock idle time and orphan status
				local now idle_elapsed
				now=$(date +%s)
				idle_elapsed=$((now - idle_start))

				# Check orphan status (if enabled)
				if [ "${orphan_enabled}" = "true" ] && mcp_core_check_orphaned; then
					mcp_core_handle_orphaned
					break
				fi

				# Check idle timeout (if enabled)
				if [ "${idle_timeout}" -gt 0 ] && [ "${idle_elapsed}" -ge "${idle_timeout}" ]; then
					mcp_core_handle_idle_timeout "${idle_timeout}"
					break
				fi

				# Not at timeout yet - continue loop
				continue
			fi

			# Successful read - reset counters
			immediate_returns=0
		else
			# Both features disabled - use blocking read
			# Capture exit status in a way that prevents set -e from aborting on EOF
			local read_status=0
			IFS= read -r line || read_status=$?

			if [ ${read_status} -ne 0 ]; then
				# Check for signal (same handling as timeout branch)
				if [ -n "${_MCPBASH_SIGNAL_RECEIVED}" ]; then
					case "${_MCPBASH_SIGNAL_RECEIVED}" in
					INT) exit 130 ;;
					TERM) exit 143 ;;
					*) exit 1 ;;
					esac
				fi
				[ -n "${line}" ] && mcp_core_handle_line "${line}"
				break
			fi
		fi

		# Reset idle timer on activity
		idle_start=$(date +%s)
		[ -z "${line}" ] && continue
		mcp_core_handle_line "${line}"
	done

	# Keep the exit traps: a signal while waiting for workers must still exit
	# through the EXIT trap (cleanup). The default action would kill the server
	# without removing its state directory.
}

mcp_core_finish_after_read_loop() {
	local shutdown_pending="${MCPBASH_SHUTDOWN_PENDING:-false}"
	local exit_requested="${MCPBASH_EXIT_REQUESTED:-false}"
	local idle_timeout="${MCPBASH_IDLE_TIMEOUT_TRIGGERED:-false}"
	local orphan_detected="${MCPBASH_ORPHAN_DETECTED:-false}"

	if [ "${shutdown_pending}" = true ]; then
		mcp_core_cancel_shutdown_watchdog
		MCPBASH_SHUTDOWN_TIMER_STARTED=false
	fi

	# The parent is gone: nobody can receive the workers' results.
	if [ "${orphan_detected}" = true ]; then
		mcp_core_stop_all_workers
	fi

	# Clean exit on: explicit exit, shutdown, idle timeout, OR orphan detected
	if [ "${exit_requested}" = true ] || [ "${shutdown_pending}" = true ] \
		|| [ "${idle_timeout}" = true ] || [ "${orphan_detected}" = true ]; then
		mcp_core_wait_for_workers
		mcp_runtime_cleanup
		_MCPBASH_CLEANUP_DONE=true # Prevent double cleanup in EXIT trap
		_MCPBASH_EXIT_CLEAN=true
		exit 0
	fi

	# EOF without explicit shutdown: still exit cleanly
	mcp_core_wait_for_workers
	mcp_runtime_cleanup
	_MCPBASH_CLEANUP_DONE=true
	_MCPBASH_EXIT_CLEAN=true
	exit 0
}

# Stop every running worker and the tools it started: TERM now, KILL after up
# to 1s. For exits where nobody can receive their results.
mcp_core_stop_all_workers() {
	[ -n "${MCPBASH_STATE_DIR:-}" ] || return 0
	# Loops read line by line, so they do not depend on IFS (called from the
	# exit trap, which runs with the IFS of whatever it interrupted).
	local keys key info pid pgid rest identity targets="" alive tries=0
	keys="$(mcp_ids_list_active_workers 2>/dev/null || true)"
	[ -n "${keys}" ] || return 0
	while IFS= read -r key; do
		[ -n "${key}" ] || continue
		info="$(mcp_ids_worker_info "${key}" 2>/dev/null)" || continue
		pid="" pgid=""
		IFS=' ' read -r pid pgid rest <<<"${info}"
		case "${pid}" in '' | *[!0-9]*) continue ;; esac
		case "${pgid}" in *[!0-9]*) pgid="" ;; esac
		if [ "${MCPBASH_SKIP_PROCESS_GROUP_LOOKUP:-0}" = "1" ]; then
			pgid=""
		fi
		# Who leads the group at the TERM, for the KILL below
		# (mcp_runtime_signal_checked); last on the line, as it may hold spaces.
		identity="$(mcp_runtime_group_snapshot "${pgid}")"
		mcp_core_send_signal_chain "${pid}" "${pgid}" TERM
		targets="${targets}${pid} ${pgid:--} ${identity}"$'\n'
	done <<<"${keys}"
	[ -n "${targets}" ] || return 0
	while [ "${tries}" -lt 10 ]; do
		alive=false
		while IFS=' ' read -r pid pgid identity; do
			[ -n "${pid}" ] || continue
			[ "${pgid}" != "-" ] || pgid=""
			if mcp_core_process_alive "${pid}" || mcp_core_group_alive "${pgid}"; then
				alive=true
				break
			fi
		done <<<"${targets}"
		[ "${alive}" = true ] || return 0
		sleep 0.1
		tries=$((tries + 1))
	done
	while IFS=' ' read -r pid pgid identity; do
		[ -n "${pid}" ] || continue
		[ "${pgid}" != "-" ] || pgid=""
		mcp_runtime_signal_checked KILL "${pgid}" "${pid}" "${MCPBASH_MAIN_PGID}" "${identity}"
	done <<<"${targets}"
}

mcp_core_wait_for_workers() {
	local pid
	local exit_code
	local pids

	pids="$(mcp_core_list_worker_pids)"
	if [ -z "${pids}" ]; then
		return 0
	fi

	for pid in ${pids}; do
		# A cancelled or timed-out worker ends with a signal status (143, 137).
		# Under set -e a bare wait would end the drain there, dropping the
		# results of the workers still running.
		exit_code=0
		wait "${pid}" || exit_code=$?
		# Ignore normal exits and missing jobs (127) to avoid noisy logs on shells without full job control.
		if [ "${exit_code}" -ne 0 ] && [ "${exit_code}" -ne 127 ]; then
			printf '%s\n' "mcp-bash: background worker ${pid} exited with status ${exit_code}" >&2
		fi
	done
}

mcp_core_state_worker_pids() {
	local keys key info pid state_pids=""

	keys="$(mcp_ids_list_active_workers 2>/dev/null || true)"
	[ -n "${keys}" ] || return 0

	while IFS= read -r key || [ -n "${key}" ]; do
		[ -n "${key}" ] || continue
		info="$(mcp_ids_worker_info "${key}" 2>/dev/null || true)"
		pid="$(printf '%s' "${info}" | awk '{print $1}')"
		[ -n "${pid}" ] || continue
		if kill -0 "${pid}" 2>/dev/null; then
			if [ -z "${state_pids}" ]; then
				state_pids="${pid}"
			else
				state_pids="${state_pids}"$'\n'"${pid}"
			fi
		else
			mcp_core_clear_inputs "$(mcp_core_inputs_tag_of "${info}")"
			mcp_ids_clear_worker "${key}"
		fi
	done <<<"${keys}"$'\n'

	printf '%s' "${state_pids}"
}

mcp_core_list_worker_pids() {
	local pids filtered pid
	pids="$(jobs -p 2>/dev/null || true)"
	if [ -z "${pids}" ]; then
		filtered="$(mcp_core_state_worker_pids)"
		printf '%s' "${filtered}"
		return 0
	fi
	filtered=""
	for pid in ${pids}; do
		if [ -n "${MCPBASH_PROGRESS_FLUSHER_PID:-}" ] && [ "${pid}" = "${MCPBASH_PROGRESS_FLUSHER_PID}" ]; then
			continue
		fi
		if [ -n "${MCPBASH_RESOURCE_POLL_PID:-}" ] && [ "${pid}" = "${MCPBASH_RESOURCE_POLL_PID}" ]; then
			continue
		fi
		filtered="${filtered:+${filtered}$'\n'}${pid}"
	done
	# Merge any workers tracked via pid files (needed on platforms without job control).
	local state_pids
	state_pids="$(mcp_core_state_worker_pids)"
	if [ -n "${state_pids}" ]; then
		while IFS= read -r pid || [ -n "${pid}" ]; do
			[ -n "${pid}" ] || continue
			case $'\n'"${filtered}"$'\n' in
			*$'\n'"${pid}"$'\n'*) continue ;;
			esac
			filtered="${filtered:+${filtered}$'\n'}${pid}"
		done <<<"${state_pids}"$'\n'
	fi
	printf '%s' "${filtered}"
}

mcp_core_wait_for_one_worker() {
	local pids pid status
	while :; do
		pids="$(mcp_core_list_worker_pids)"
		if [ -z "${pids}" ]; then
			sleep 0.05
			return 0
		fi
		for pid in ${pids}; do
			if ! kill -0 "${pid}" 2>/dev/null; then
				if ! wait "${pid}"; then
					status=$?
					printf '%s\n' "mcp-bash: background worker ${pid} exited with status ${status}" >&2
				fi
				return 0
			fi
		done
		sleep 0.05
	done
}

mcp_core_active_worker_count() {
	local pids
	pids="$(mcp_core_list_worker_pids)"
	if [ -z "${pids}" ]; then
		printf '0'
		return 0
	fi
	printf '%s' "$(printf '%s\n' "${pids}" | wc -l | tr -d ' ')"
}

mcp_core_wait_for_available_slot() {
	local max="${MCPBASH_MAX_CONCURRENT_REQUESTS:-16}"
	local active
	case "${max}" in
	'' | *[!0-9]*) max=16 ;;
	0) max=1 ;;
	esac
	while :; do
		active="$(mcp_core_active_worker_count)"
		if [ "${active}" -lt "${max}" ]; then
			break
		fi
		mcp_core_wait_for_one_worker
	done
}

mcp_core_start_shutdown_watchdog() {
	local timeout="${MCPBASH_SHUTDOWN_TIMEOUT:-5}"
	case "${timeout}" in
	'' | *[!0-9]*) timeout=5 ;;
	0) timeout=5 ;;
	esac
	if [ -n "${MCPBASH_SHUTDOWN_WATCHDOG_PID}" ]; then
		if kill -0 "${MCPBASH_SHUTDOWN_WATCHDOG_PID}" 2>/dev/null; then
			return 0
		fi
		MCPBASH_SHUTDOWN_WATCHDOG_PID=""
	fi
	# Use a cancel file for reliable cross-platform cancellation (Windows signals are flaky)
	local cancel_file="${MCPBASH_STATE_DIR}/shutdown_watchdog.cancel"
	rm -f "${cancel_file}"
	MCPBASH_SHUTDOWN_WATCHDOG_CANCEL="${cancel_file}"
	local parent_pid="$$"
	(
		# Poll in small increments so we can check the cancel file
		local elapsed=0
		while [ "${elapsed}" -lt "${timeout}" ]; do
			sleep 1
			elapsed=$((elapsed + 1))
			# Check if cancellation was requested via file (more reliable than signals on Windows)
			if [ -f "${cancel_file}" ]; then
				rm -f "${cancel_file}" 2>/dev/null || true
				exit 0
			fi
		done
		printf '%s\n' "mcp-bash: shutdown timeout (${timeout}s) elapsed; terminating." >&2
		kill -TERM "${parent_pid}" 2>/dev/null || true
		sleep 1
		kill -KILL "${parent_pid}" 2>/dev/null || true
	) &
	MCPBASH_SHUTDOWN_WATCHDOG_PID=$!
}

mcp_core_cancel_shutdown_watchdog() {
	if [ -z "${MCPBASH_SHUTDOWN_WATCHDOG_PID}" ]; then
		return 0
	fi
	local pid="${MCPBASH_SHUTDOWN_WATCHDOG_PID}"
	# Signal cancellation via file (reliable on Windows where kill may not interrupt sleep)
	if [ -n "${MCPBASH_SHUTDOWN_WATCHDOG_CANCEL:-}" ]; then
		touch "${MCPBASH_SHUTDOWN_WATCHDOG_CANCEL}" 2>/dev/null || true
	fi
	# Also try to kill directly (works on Unix, may fail on Windows)
	kill "${pid}" 2>/dev/null || true
	# Wait for the watchdog to exit. On Windows, `wait` may not work for subshells in
	# non-interactive mode, so we poll with kill -0. The watchdog checks the cancel file
	# every second, so we wait up to 3 seconds for it to notice and exit.
	local attempts=0
	while [ "${attempts}" -lt 30 ] && kill -0 "${pid}" 2>/dev/null; do
		sleep 0.1 2>/dev/null || sleep 1
		attempts=$((attempts + 1))
	done
	# Avoid a potentially blocking wait on Git Bash (wait can hang for background subshells).
	# Only attempt to reap if the watchdog has already exited.
	if ! kill -0 "${pid}" 2>/dev/null; then
		wait "${pid}" 2>/dev/null || true
	fi
	MCPBASH_SHUTDOWN_WATCHDOG_PID=""
	MCPBASH_SHUTDOWN_WATCHDOG_CANCEL=""
}

mcp_core_process_legacy_batch() {
	local array_json="$1"
	local tool="$MCPBASH_JSON_TOOL"
	local bin="$MCPBASH_JSON_TOOL_BIN"
	local item
	local batch_output=""

	case "${tool}" in
	gojq | jq)
		if ! batch_output="$(printf '%s' "${array_json}" | "${bin}" -c '.[]' 2>/dev/null)"; then
			return 1
		fi
		;;
	*)
		return 1
		;;
	esac

	while IFS= read -r item; do
		[ -z "${item}" ] && continue
		mcp_core_handle_line "${item}"
	done <<<"${batch_output}"$'\n'

	return 0
}

mcp_core_response_size_limit() {
	local method="$1"
	local limit=""

	case "${method}" in
	tools/list | resources/list | prompts/list | resources/templates/list)
		if command -v mcp_registry_global_max_bytes >/dev/null 2>&1; then
			limit="$(mcp_registry_global_max_bytes 2>/dev/null || true)"
		fi
		;;
	esac

	if [ -z "${limit}" ]; then
		limit="${MCPBASH_MAX_TOOL_OUTPUT_SIZE:-10485760}"
	fi

	case "${limit}" in
	'' | *[!0-9]*) limit=10485760 ;;
	esac

	printf '%s' "${limit}"
}

mcp_core_guard_response_size() {
	local id_json="$1"
	local payload="$2"
	local method="$3"
	local limit
	local size

	limit="$(mcp_core_response_size_limit "${method}")"

	if [ -z "${payload}" ]; then
		printf '%s' "${payload}"
		return 0
	fi

	size="$(LC_ALL=C printf '%s' "${payload}" | wc -c | tr -d ' ')"
	if [ "${size}" -le "${limit}" ]; then
		printf '%s' "${payload}"
		return 0
	fi

	printf '%s\n' "mcp-bash: response exceeded ${limit} bytes for id ${id_json:-null}" >&2
	mcp_core_build_error_response "${id_json:-null}" -32603 "Response exceeded response size limit" ""
}

mcp_core_rate_limit() {
	local key="$1"
	local kind="$2"
	local limit
	local file
	local now
	local preserved=""
	local line
	local count=0
	local lock_name
	local result=0

	[ -z "${key}" ] && return 0

	# Simple sliding window: track timestamps per key/kind in a local file and drop
	# events once the per-minute quota is exhausted. Uses coarse locking because
	# rate limiting is best-effort and should not block the main loop for long.
	case "${kind}" in
	progress) limit="${MCPBASH_MAX_PROGRESS_PER_MIN:-100}" ;;
	log) limit="${MCPBASH_MAX_LOGS_PER_MIN:-${MCPBASH_MAX_PROGRESS_PER_MIN:-100}}" ;;
	*) limit=100 ;;
	esac

	case "${limit}" in
	'' | *[!0-9]*) limit=100 ;;
	0) return 0 ;;
	esac

	file="${MCPBASH_STATE_DIR}/rate.${kind}.${key}.log"
	lock_name="rate.${kind}.${key}"
	mcp_lock_acquire "${lock_name}"
	now="$(date +%s)"

	if [ -f "${file}" ]; then
		while IFS= read -r line; do
			[ -z "${line}" ] && continue
			if [ $((now - line)) -lt 60 ]; then
				preserved="${preserved}${line}"$'\n'
				count=$((count + 1))
			fi
		done <"${file}"
	fi

	if [ "${count}" -ge "${limit}" ]; then
		printf '%s' "${preserved}" >"${file}"
		result=1
		mcp_lock_release "${lock_name}"
		return "${result}"
	fi

	printf '%s%s\n' "${preserved}" "${now}" >"${file}"
	mcp_lock_release "${lock_name}"
	return "${result}"
}

mcp_core_handle_line() {
	local raw_line="$1"
	local normalized_line
	local method

	# Args:
	#   raw_line - raw JSON-RPC line from stdin (may contain arrays or responses).
	# Log incoming request for debugging
	if mcp_io_debug_enabled; then
		mcp_io_debug_log "request" "-" "recv" "${raw_line}"
	fi

	normalized_line="$(mcp_json_normalize_line "${raw_line}")" || {
		mcp_core_emit_parse_error "Parse error" -32700 "Failed to normalize input"
		return
	}

	if [ -z "${normalized_line}" ]; then
		return
	fi

	if mcp_json_is_array "${normalized_line}"; then
		if ! mcp_runtime_batches_enabled; then
			local protocol="${MCPBASH_NEGOTIATED_PROTOCOL_VERSION:-${MCPBASH_PROTOCOL_VERSION}}"
			case "${protocol}" in
			2025-06-18 | 2025-11-25)
				mcp_core_emit_parse_error "Invalid Request" -32600 "Batch arrays are not allowed for protocol ${protocol}"
				;;
			*)
				mcp_core_emit_parse_error "Invalid Request" -32600 "Batch arrays are disabled"
				;;
			esac
			return
		fi
		if ! mcp_core_process_legacy_batch "${normalized_line}"; then
			mcp_core_emit_parse_error "Parse error" -32700 "Unable to process batch array"
		fi
		return
	fi

	# Route responses (result/error) before method extraction
	if { mcp_json_has_key "${normalized_line}" "result" || mcp_json_has_key "${normalized_line}" "error"; } && ! mcp_json_has_key "${normalized_line}" "method"; then
		mcp_rpc_handle_response "${normalized_line}"
		mcp_core_emit_registry_notifications
		if declare -F mcp_elicitation_process_requests >/dev/null 2>&1; then
			mcp_elicitation_process_requests
		fi
		mcp_core_maybe_start_background_workers
		return
	fi

	method="$(mcp_json_extract_method "${normalized_line}")" || {
		mcp_core_emit_parse_error "Invalid Request" -32600 "Missing method"
		return
	}

	mcp_core_dispatch_object "${normalized_line}" "${method}"

	mcp_core_emit_registry_notifications
	if declare -F mcp_elicitation_process_requests >/dev/null 2>&1; then
		mcp_elicitation_process_requests
	fi
	mcp_core_maybe_start_background_workers

	if [ "${MCPBASH_EXIT_REQUESTED}" = true ]; then
		mcp_core_wait_for_workers
		mcp_runtime_cleanup
		_MCPBASH_EXIT_CLEAN=true
		exit 0
	fi
}

mcp_core_dispatch_object() {
	local json_line="$1"
	local method="$2"
	local handler=""
	local async="false"
	local id_json
	local is_notification="false"

	# Args:
	#   json_line - normalized JSON-RPC object (single request/notification).
	#   method    - extracted method name used to resolve handler.
	if [ "${method}" = "notifications/cancelled" ]; then
		if ! id_json="$(mcp_json_extract_id "${json_line}")"; then
			id_json="null"
		fi
		if ! mcp_auth_guard_request "${json_line}" "${method}" "${id_json}"; then
			return
		fi
		mcp_core_handle_cancel_notification "${json_line}"
		return
	fi

	if [ "${method}" = "notifications/message" ]; then
		mcp_core_emit_parse_error "Invalid Request" -32601 "notifications/message is server-originated"
		return
	fi

	if ! id_json="$(mcp_json_extract_id "${json_line}")"; then
		mcp_core_emit_parse_error "Invalid Request" -32600 "Unable to extract id"
		return
	fi
	if ! mcp_json_has_key "${json_line}" "id"; then
		is_notification="true"
	fi

	if ! mcp_auth_guard_request "${json_line}" "${method}" "${id_json}"; then
		return
	fi

	if mcp_logging_is_enabled "debug"; then
		mcp_logging_debug "mcp.core" "Dispatch method=${method} id=${id_json}"
	fi

	# A modern (2026-07-28) request is served on its own terms: no initialize
	# gate, and never in the main process (see mcp_core_dispatch_modern).
	# initialize selects legacy semantics whatever _meta it carries. Only
	# requests are modern: a notification has no result to shape, and one
	# such as notifications/initialized belongs to the legacy session.
	if [ "${method}" != "initialize" ] && [ "${is_notification}" != "true" ]; then
		mcp_modern_classify "${json_line}"
	fi
	if [ "${MCPBASH_REQUEST_ERA}" = "modern" ]; then
		mcp_core_dispatch_modern "${json_line}" "${method}" "${id_json}" "${is_notification}"
		MCPBASH_REQUEST_ERA="legacy"
		# shellcheck disable=SC2034  # Read by lib/modern.sh
		MCPBASH_REQUEST_META=""
		return
	fi

	if [ "${MCPBASH_INITIALIZED}" != true ] && ! mcp_core_method_allowed_preinit "${method}"; then
		if [ "${is_notification}" != "true" ]; then
			# A method the server doesn't have is "not found" whatever the
			# lifecycle state. Clients that probe with server/discover before
			# initialize then see an unambiguous -32601 and fall back.
			if mcp_core_resolve_handler "${method}"; then
				mcp_core_emit_not_initialized "${id_json}"
			else
				mcp_core_emit_method_not_found "${id_json}"
			fi
		fi
		return
	fi

	if [ "${MCPBASH_SHUTDOWN_PENDING}" = true ] && ! mcp_core_method_allowed_during_shutdown "${method}"; then
		if [ "${is_notification}" != "true" ]; then
			mcp_core_emit_shutting_down "${id_json}"
		fi
		return
	fi

	if ! mcp_core_resolve_handler "${method}"; then
		if [ "${is_notification}" != "true" ]; then
			mcp_core_emit_method_not_found "${id_json}"
		fi
		return
	fi

	handler="${MCPBASH_RESOLVED_HANDLER}"
	async="${MCPBASH_RESOLVED_ASYNC}"

	if [ "${method}" = "resources/subscribe" ]; then
		MCPBASH_RESOURCE_POLL_WANTED=true
	fi
	case "${method}" in
	resources/subscribe | resources/unsubscribe)
		# Runs here, in request order, before either worker starts; see
		# mcp_resources_subscription_note_dispatch.
		mcp_resources_subscription_note_dispatch "${method}" "${json_line}" "${id_json}" || true
		;;
	esac

	if [ "${async}" = "true" ]; then
		mcp_core_spawn_worker "${handler}" "${method}" "${json_line}" "${id_json}"
	else
		mcp_core_execute_handler "${handler}" "${method}" "${json_line}" "${id_json}"
	fi
}

# Serve one modern request. Stateless: it needs no initialize, and it never
# runs in the main process, which holds the legacy session's state; a worker
# gets a fork, where the request's own capabilities replace that state
# (mcp_modern_apply_worker_context).
mcp_core_dispatch_modern() {
	local json_line="$1"
	local method="$2"
	local id_json="$3"
	local is_notification="$4"
	local refusal

	refusal="$(mcp_modern_refusal "${method}" "${id_json}")"
	if [ -n "${refusal}" ]; then
		[ "${is_notification}" = "true" ] || rpc_send_line "${refusal}"
		return 0
	fi
	if [ "${is_notification}" = "true" ]; then
		return 0
	fi
	# Legacy codes such as -32003 don't exist on this path.
	if [ "${MCPBASH_SHUTDOWN_PENDING}" = true ]; then
		rpc_send_line "$(mcp_core_build_error_response "${id_json}" -32603 "Server shutting down" "")"
		return 0
	fi
	if ! mcp_core_resolve_handler "${method}"; then
		mcp_core_emit_method_not_found "${id_json}"
		return 0
	fi
	# server/discover reads only static data, so it is answered at once.
	if [ "${method}" = "server/discover" ]; then
		mcp_core_execute_handler "${MCPBASH_RESOLVED_HANDLER}" "${method}" "${json_line}" "${id_json}"
		return 0
	fi
	mcp_core_spawn_worker "${MCPBASH_RESOLVED_HANDLER}" "${method}" "${json_line}" "${id_json}"
}

mcp_core_resolve_handler() {
	local method="$1"
	MCPBASH_RESOLVED_HANDLER=""
	MCPBASH_RESOLVED_ASYNC="false"

	case "${method}" in
	initialize | shutdown | exit | initialized | notifications/initialized)
		MCPBASH_RESOLVED_HANDLER="mcp_handle_lifecycle"
		;;
	ping)
		MCPBASH_RESOLVED_HANDLER="mcp_handle_ping"
		;;
	logging/*)
		MCPBASH_RESOLVED_HANDLER="mcp_handle_logging"
		;;
	tools/*)
		MCPBASH_RESOLVED_HANDLER="mcp_handle_tools"
		MCPBASH_RESOLVED_ASYNC="true"
		;;
	resources/*)
		MCPBASH_RESOLVED_HANDLER="mcp_handle_resources"
		MCPBASH_RESOLVED_ASYNC="true"
		;;
	prompts/get)
		MCPBASH_RESOLVED_HANDLER="mcp_handle_prompts"
		MCPBASH_RESOLVED_ASYNC="true"
		;;
	prompts/*)
		MCPBASH_RESOLVED_HANDLER="mcp_handle_prompts"
		;;
	completion/complete)
		MCPBASH_RESOLVED_HANDLER="mcp_handle_completion"
		MCPBASH_RESOLVED_ASYNC="true"
		;;
	completion/*)
		MCPBASH_RESOLVED_HANDLER="mcp_handle_completion"
		;;
	roots/* | notifications/roots/*)
		MCPBASH_RESOLVED_HANDLER="mcp_handle_roots"
		;;
	server/discover)
		# Unknown ("Method not found") unless modern requests are switched on.
		mcp_modern_enabled || return 1
		MCPBASH_RESOLVED_HANDLER="mcp_handle_discover"
		;;
	*)
		return 1
		;;
	esac

	return 0
}

mcp_core_execute_handler() {
	local handler="$1"
	local method="$2"
	local json_line="$3"
	local id_json="$4"
	local response

	if ! mcp_core_invoke_handler "${handler}" "${method}" "${json_line}"; then
		response="$(mcp_core_build_error_response "${id_json}" -32601 "Handler not implemented" "")"
	else
		response="${MCPBASH_HANDLER_OUTPUT}"
		if [ "${response}" = "${MCPBASH_NO_RESPONSE}" ]; then
			return 0
		fi
		if [ -z "${response}" ]; then
			response="$(mcp_core_build_error_response "${id_json}" -32603 "Empty handler response" "")"
		fi
	fi

	if mcp_logging_is_enabled "debug"; then
		if [ "${response}" != "${MCPBASH_NO_RESPONSE}" ]; then
			mcp_logging_debug "mcp.core" "Response id=${id_json} bytes=${#response}"
		else
			mcp_logging_debug "mcp.core" "NoResponse id=${id_json}"
		fi
	fi

	response="$(mcp_core_guard_response_size "${id_json}" "${response}" "${method}")"
	rpc_send_line "${response}"
}

# Numbers each worker's input files (mcp_runtime_input_file), so a request
# that reuses a running request's id can't clear that request's files.
MCP_CORE_SPAWN_SEQ=0

# Remove the input files one worker's children were given
# (mcp_runtime_input_file), by its inputs tag (<request key>.<spawn number>).
# Keys are base64url and the number ends at a dot, so the glob matches only
# that worker's files.
mcp_core_clear_inputs() {
	local tag="$1"
	[ -n "${tag}" ] && [ -n "${MCPBASH_STATE_DIR:-}" ] || return 0
	rm -f "${MCPBASH_STATE_DIR}/inputs.${tag}."* 2>/dev/null || true
}

# The inputs tag at the end of a pid file line (mcp_ids_track_worker), or
# nothing when the line has none.
mcp_core_inputs_tag_of() {
	local tag="${1##* }"
	local key="${tag%.*}" num="${tag##*.}"
	[ "${key}" != "${tag}" ] && [ -n "${key}" ] && [ -n "${num}" ] || return 0
	case "${key}" in *[!A-Za-z0-9_-]*) return 0 ;; esac
	case "${num}" in *[!0-9]*) return 0 ;; esac
	printf '%s' "${tag}"
}
mcp_core_spawn_worker() {
	local handler="$1"
	local method="$2"
	local json_line="$3"
	local id_json="$4"
	local key
	local stderr_file=""
	local timeout=""

	mcp_core_wait_for_available_slot
	mcp_core_start_lifeline

	# Each async request runs in its own background worker with dedicated stderr
	# capture, optional timeout wrapper, and isolated progress/log streams so
	# cancellation or noisy tools cannot interfere with other requests.
	key="$(mcp_core_get_id_key "${id_json}")"

	if [ -n "${key}" ]; then
		stderr_file="${MCPBASH_STATE_DIR}/stderr.${key}.log"
	else
		stderr_file="${MCPBASH_STATE_DIR}/stderr.${BASHPID:-$$}.${RANDOM}.log"
	fi

	timeout="$(mcp_core_timeout_for_method "${method}" "${json_line}")"
	timeout="$(mcp_core_normalize_timeout "${timeout}")"

	local progress_stream="${MCPBASH_STATE_DIR}/progress.${key:-main}.ndjson"
	local log_stream="${MCPBASH_STATE_DIR}/logs.${key:-main}.ndjson"
	: >"${progress_stream}"
	: >"${log_stream}"
	local cancel_file
	cancel_file="$(mcp_ids_state_path "cancelled" "${key}")"
	rm -f "${cancel_file}"
	# A modern request's log level for the live flusher; a worker killed
	# before its cleanup must not leave one for a later request with this id.
	[ -z "${key}" ] || rm -f "${MCPBASH_STATE_DIR}/loglevel.${key}"
	MCP_CORE_SPAWN_SEQ=$((MCP_CORE_SPAWN_SEQ + 1))
	local inputs_tag=""
	# The counter alone: it runs in the read loop, so it never repeats while the
	# server runs (and each server has its own state dir).
	[ -z "${key}" ] || inputs_tag="${key}.${MCP_CORE_SPAWN_SEQ}"
	local progress_token
	progress_token="$(mcp_json_extract_progress_token "${json_line}")"
	local handled_file=""
	if [ -n "${key}" ]; then
		handled_file="${MCPBASH_STATE_DIR}/handled.${key}"
		rm -f "${handled_file}"
	fi

	(
		exec 2>"${stderr_file}"
		# shellcheck disable=SC2030
		export MCPBASH_WORKER_INPUTS="${inputs_tag}"
		# shellcheck disable=SC2030
		export MCP_PROGRESS_STREAM="${progress_stream}"
		# shellcheck disable=SC2030
		export MCP_LOG_STREAM="${log_stream}"
		export MCP_PROGRESS_TOKEN="${progress_token}"
		export MCP_CANCEL_FILE="${cancel_file}"
		if [ "${MCPBASH_REQUEST_ERA:-legacy}" = "modern" ]; then
			mcp_modern_apply_worker_context "${key}"
		fi
		if [ -n "${timeout}" ]; then
			local timeout_status=0
			with_timeout "${timeout}" -- mcp_core_worker_entry "${handler}" "${method}" "${json_line}" "${id_json}" "${key}" "${stderr_file}" || timeout_status=$?
			# The handler was killed before it could answer: answer for it, or
			# the client waits forever. A worker that had already answered and
			# was killed while delivering its streams leaves the handled marker.
			# (Cancelled requests get no response; mcp_io_send_response drops
			# them.)
			if [ "${timeout_status}" -eq 124 ] && [ -n "${id_json}" ] && [ "${id_json}" != "null" ] \
				&& { [ -z "${handled_file}" ] || [ ! -e "${handled_file}" ]; }; then
				mcp_core_worker_emit "${key}" "$(mcp_core_build_error_response "${id_json}" -32603 "${method} timed out after ${timeout}s" "")"
			fi
			if [ -n "${handled_file}" ]; then
				rm -f "${handled_file}"
			fi
			# A killed worker never ran its cleanup.
			mcp_core_clear_inputs "${inputs_tag}"
		else
			mcp_core_worker_entry "${handler}" "${method}" "${json_line}" "${id_json}" "${key}" "${stderr_file}"
		fi
	) &

	local pid=$!

	local pgid
	pgid="$(mcp_runtime_lookup_pgid "${pid}")"

	mcp_ids_track_worker "${key}" "${pid}" "${pgid}" "${stderr_file}" "${inputs_tag}"
	if [ -n "${key}" ] && ! mcp_core_process_alive "${pid}"; then
		wait "${pid}" 2>/dev/null || true
		mcp_ids_clear_worker "${key}"
	fi
}

mcp_core_timeout_for_method() {
	local method="$1"
	local json_line="$2"
	local timeout_value=""

	# Args:
	#   method     - JSON-RPC method name (tools/*, resources/*, etc.).
	#   json_line  - full request payload for extracting per-call timeout.
	case "${method}" in
	tools/call)
		# Tool-level timeouts are enforced inside mcp_tools_call; avoid double-wrapping
		printf ''
		return 0
		;;
	tools/* | resources/* | prompts/get | completion/complete)
		if mcp_runtime_is_minimal_mode; then
			printf ''
			return 0
		fi
		case "${MCPBASH_JSON_TOOL}" in
		gojq | jq)
			timeout_value="$(printf '%s' "${json_line}" | "${MCPBASH_JSON_TOOL_BIN}" -er '.params.timeoutSecs // empty' 2>/dev/null || true)"
			;;
		*)
			timeout_value=""
			;;
		esac
		;;
	*)
		printf ''
		return 0
		;;
	esac

	if [ -z "${timeout_value}" ]; then
		case "${method}" in
		tools/*)
			timeout_value="${MCPBASH_DEFAULT_TOOL_TIMEOUT:-30}"
			;;
		resources/subscribe)
			timeout_value="${MCPBASH_DEFAULT_SUBSCRIBE_TIMEOUT:-120}"
			;;
		resources/read)
			# A provider that never finishes (a slow backend, a FIFO) would
			# otherwise hold a worker slot forever.
			timeout_value="${MCPBASH_DEFAULT_RESOURCE_TIMEOUT:-120}"
			;;
		esac
	fi

	printf '%s' "${timeout_value}"
}

mcp_core_worker_entry() {
	local handler="$1"
	local method="$2"
	local json_line="$3"
	local id_json="$4"
	local key="$5"
	local stderr_file="$6"
	local response
	# shellcheck disable=SC2031
	local progress_stream="${MCP_PROGRESS_STREAM:-}"
	# shellcheck disable=SC2031
	local log_stream="${MCP_LOG_STREAM:-}"

	MCPBASH_WORKER_KEY="${key}"
	export MCPBASH_WORKER_KEY

	trap 'mcp_core_worker_cleanup "${key}" "${stderr_file}"' EXIT

	# Worker functions emit their response via stdout into a temp file; this shim
	# folds empty/no-response cases into JSON-RPC errors and handles stream flush
	# so handlers stay minimal.
	if ! mcp_core_invoke_handler "${handler}" "${method}" "${json_line}"; then
		response="$(mcp_core_build_error_response "${id_json}" -32601 "Handler not implemented" "")"
	else
		response="${MCPBASH_HANDLER_OUTPUT}"
		if [ "${response}" = "${MCPBASH_NO_RESPONSE}" ]; then
			response=""
		elif [ -z "${response}" ]; then
			response="$(mcp_core_build_error_response "${id_json}" -32603 "Empty handler response" "")"
		fi
	fi

	# A modern (2026-07-28) request's progress and log notifications go out
	# before its result: progress MUST stop once the request completes.
	if [ "${MCPBASH_REQUEST_ERA:-legacy}" = "modern" ]; then
		mcp_core_worker_deliver_streams "${key}" "${progress_stream}" "${log_stream}"
	fi

	if [ -n "${response}" ]; then
		if [ "${MCPBASH_REQUEST_ERA:-legacy}" = "modern" ]; then
			response="$(mcp_modern_decorate_response "${method}" "${response}")"
		fi
		response="$(mcp_core_guard_response_size "${id_json}" "${response}" "${method}")"
		mcp_core_worker_emit "${key}" "${response}"
	fi
	# The request is now answered (or deliberately left unanswered). A timeout
	# during the stream delivery below must not answer it a second time; see
	# mcp_core_spawn_worker.
	if [ -n "${key}" ]; then
		: >"${MCPBASH_STATE_DIR}/handled.${key}" 2>/dev/null || true
	fi

	if [ "${MCPBASH_REQUEST_ERA:-legacy}" != "modern" ]; then
		mcp_core_worker_deliver_streams "${key}" "${progress_stream}" "${log_stream}"
	fi
}

# Progress/log delivery for one worker:
# - When live progress is disabled, emit all buffered progress/log lines here.
# - When live progress is enabled, a background flusher streams lines while the
#   worker runs, but Git Bash/CI scheduling can cause the worker to exit and
#   delete its stream files before the flusher observes the final writes.
#   Do a final best-effort flush before cleanup so at least one progress event
#   is emitted when tools report progress (avoids flaky CI on Windows).
mcp_core_worker_deliver_streams() {
	local key="$1"
	local progress_stream="$2"
	local log_stream="$3"
	if [ "${MCPBASH_ENABLE_LIVE_PROGRESS:-false}" = "true" ] && [ -n "${key}" ]; then
		mcp_core_flush_stream "${key}" "progress" || true
		mcp_core_flush_stream "${key}" "log" || true
	fi

	if [ "${MCPBASH_ENABLE_LIVE_PROGRESS:-false}" != "true" ] && [ -n "${progress_stream}" ]; then
		mcp_core_emit_progress_stream "${key}" "${progress_stream}"
	fi
	rm -f "${progress_stream}"
	rm -f "${MCPBASH_STATE_DIR}/rate.progress.${key}.log"
	rm -f "${progress_stream}.offset"

	if [ "${MCPBASH_ENABLE_LIVE_PROGRESS:-false}" != "true" ] && [ -n "${log_stream}" ]; then
		mcp_core_emit_log_stream "${key}" "${log_stream}"
	fi
	rm -f "${log_stream}"
	rm -f "${MCPBASH_STATE_DIR}/rate.log.${key}.log"
	rm -f "${log_stream}.offset"
}

mcp_core_worker_emit() {
	local key="$1"
	local payload="$2"
	if [ "${MCPBASH_DEBUG_PAYLOADS:-}" = "true" ] && [ -n "${MCPBASH_STATE_DIR:-}" ]; then
		local length="${#payload}"
		mcp_io_debug_log "worker" "${key}" "emit_len=${length}" "${payload}"
	fi
	mcp_io_send_response "${key}" "${payload}"
}

mcp_core_worker_cleanup() {
	local key="$1"
	local stderr_file="$2"

	if [ -n "${key}" ]; then
		if declare -F mcp_elicitation_cleanup_for_worker >/dev/null 2>&1; then
			mcp_elicitation_cleanup_for_worker "${key}"
		fi
		mcp_ids_clear_worker "${key}"
		# shellcheck disable=SC2031  # Set for this worker by mcp_core_spawn_worker.
		mcp_core_clear_inputs "${MCPBASH_WORKER_INPUTS:-}"
		rm -f "${MCPBASH_STATE_DIR}/rate.progress.${key}.log"
		rm -f "${MCPBASH_STATE_DIR}/rate.log.${key}.log"
		rm -f "${MCPBASH_STATE_DIR}/progress.${key}.ndjson.offset"
		rm -f "${MCPBASH_STATE_DIR}/logs.${key}.ndjson.offset"
		rm -f "${MCPBASH_STATE_DIR}/loglevel.${key}"
	fi

	if [ -n "${stderr_file}" ] && [ -f "${stderr_file}" ]; then
		# Preserve worker stderr when explicitly requested (useful for CI/debugging).
		if [ "${MCPBASH_PRESERVE_STATE:-false}" != "true" ]; then
			rm -f "${stderr_file}"
		fi
	fi
}

mcp_core_invoke_handler() {
	local handler="$1"
	local method="$2"
	local json_line="$3"
	local tmp_file=""
	local status=0

	if ! declare -f "${handler}" >/dev/null 2>&1; then
		return 127
	fi

	tmp_file="$(mktemp "${MCPBASH_STATE_DIR}/handler.${BASHPID:-$$}.XXXXXX")"
	MCPBASH_HANDLER_OUTPUT=""

	# Initialize notification queue to buffer log notifications during handler
	# execution. This avoids fd corruption when logging inside command substitutions.
	mcp_notification_queue_init

	if MCPBASH_DIRECT_FD=3 "${handler}" "${method}" "${json_line}" 3>&1 >"${tmp_file}"; then
		status=0
	else
		status=$?
	fi
	MCPBASH_HANDLER_OUTPUT="$(mcp_io_read_file_exact "${tmp_file}")"

	# Flush queued notifications now that we're outside the handler's stdout capture.
	# This ensures notifications go to the real stdout without fd inheritance issues.
	mcp_notification_queue_flush

	if [ "${MCPBASH_DEBUG_PAYLOADS:-}" = "true" ] && [ -n "${MCPBASH_STATE_DIR:-}" ]; then
		mcp_io_debug_log "handler" "${method}" "exit=${status}" "${MCPBASH_HANDLER_OUTPUT}"
	fi
	rm -f "${tmp_file}"
	return "${status}"
}

mcp_core_handle_cancel_notification() {
	local json_line="$1"
	local cancel_id

	# Modern (2026-07-28) requests need no initialize, so neither does
	# cancelling them.
	if [ "${MCPBASH_INITIALIZED}" = "false" ] && ! mcp_modern_enabled; then
		return 0
	fi

	# The extractor fails when there is no usable id (missing, null or false
	# requestId, non-object params) and always in minimal mode. A notification
	# gets no response, so such a cancel is dropped; under set -e an unguarded
	# failure here would end the server.
	cancel_id="$(mcp_json_extract_cancel_id "${json_line}")" || cancel_id=""
	if [ -z "${cancel_id}" ]; then
		return 0
	fi

	mcp_core_cancel_request "${cancel_id}"
}

mcp_core_cancel_request() {
	local id_json="$1"
	local key
	local info
	local pid=""
	local pgid=""

	key="$(mcp_core_get_id_key "${id_json}")"
	if [ -z "${key}" ]; then
		return 0
	fi

	mcp_ids_mark_cancelled "${key}"

	if ! info="$(mcp_ids_worker_info "${key}")"; then
		return 0
	fi

	pid="$(printf '%s' "${info}" | awk '{print $1}')"
	pgid="$(printf '%s' "${info}" | awk '{print $2}')"
	local inputs_tag
	inputs_tag="$(mcp_core_inputs_tag_of "${info}")"

	if [ -z "${pid}" ]; then
		return 0
	fi

	# Allow environments without reliable process groups to opt into PID-only signals.
	if [ "${MCPBASH_SKIP_PROCESS_GROUP_LOOKUP:-0}" = "1" ]; then
		pgid=""
	fi

	# Who leads the group now, so the KILL a second later skips a group
	# recreated by then (mcp_runtime_signal_checked).
	local identity=""
	identity="$(mcp_runtime_group_snapshot "${pgid}")"
	mcp_core_send_signal_chain "${pid}" "${pgid}" TERM
	# Escalate from a helper so the main loop isn't held up: waiting here
	# stalled all request handling for 1s per cancel, one cancel at a time.
	# The double fork keeps the helper out of the job table, so it never
	# counts as a worker; stdout goes to /dev/null so it can't hold the
	# client's pipe open.
	(
		(
			set +e
			sleep 1
			mcp_core_cancel_escalate "${key}" "${pid}" "${pgid}" "${inputs_tag}" "${identity}"
		) >/dev/null </dev/null &
	)
}

mcp_core_cancel_escalate() {
	local key="$1"
	local pid="$2"
	local pgid="$3"
	local inputs_tag="${4:-}"
	local identity="${5:-}"

	# The worker usually exits on TERM at once; the tool and the processes it
	# started can outlive it in the same group, so check the group too.
	if mcp_core_process_alive "${pid}" || mcp_core_group_alive "${pgid}"; then
		mcp_runtime_signal_checked KILL "${pgid}" "${pid}" "${MCPBASH_MAIN_PGID}" "${identity}"
	fi
	# A worker stopped by KILL never ran its cleanup.
	mcp_core_clear_inputs "${inputs_tag}"
	# If the worker died while holding the stdout lock, force-release it using the tracked pid.
	mcp_lock_release_owned "${MCPBASH_STDOUT_LOCK_NAME}" "${pid}"
	# Fallback for environments where kill -0 cannot verify ownership (e.g., some Windows shells).
	local stdout_lock
	stdout_lock="$(mcp_lock_path "${MCPBASH_STDOUT_LOCK_NAME}")"
	if [ -d "${stdout_lock}" ]; then
		local lock_owner
		lock_owner="$(cat "${stdout_lock}/pid" 2>/dev/null || true)"
		if [ -n "${lock_owner}" ] && [ "${lock_owner}" = "${pid}" ]; then
			rm -rf "${stdout_lock}" 2>/dev/null || true
		fi
	fi

	if declare -F mcp_elicitation_cancel_for_worker >/dev/null 2>&1; then
		mcp_elicitation_cancel_for_worker "${key}"
	fi
}

mcp_core_send_signal_chain() {
	local pid="$1"
	local pgid="$2"
	local signal="$3"

	mcp_runtime_signal_group "${pgid}" "${signal}" "${pid}" "${MCPBASH_MAIN_PGID}"
}

mcp_core_process_alive() {
	local pid="$1"
	kill -0 "${pid}" 2>/dev/null
}

mcp_core_group_alive() {
	local pgid="$1"
	if [ "${MCPBASH_SKIP_PROCESS_GROUP_LOOKUP:-0}" = "1" ] || [ -z "${pgid}" ]; then
		return 1
	fi
	# Never probe (and so never signal) the server's own group.
	if [ -n "${MCPBASH_MAIN_PGID:-}" ] && [ "${pgid}" = "${MCPBASH_MAIN_PGID}" ]; then
		return 1
	fi
	kill -0 "-${pgid}" 2>/dev/null
}

mcp_core_get_id_key() {
	local id_json="$1"
	mcp_ids_key_from_json "${id_json}"
}

mcp_core_method_allowed_preinit() {
	case "$1" in
	initialize | notifications/initialized | notifications/cancelled | ping | shutdown | exit)
		return 0
		;;
	server/discover)
		# Probed before initialize; answered -32602 without the modern _meta.
		mcp_modern_enabled
		return
		;;
	*)
		return 1
		;;
	esac
}

mcp_core_method_allowed_during_shutdown() {
	case "$1" in
	exit | shutdown | notifications/cancelled | notifications/initialized)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

mcp_core_emit_not_initialized() {
	local id_json="$1"
	case "${id_json}" in
	null | '') return 0 ;;
	esac
	if [ -z "${id_json}" ]; then
		id_json="null"
	fi
	# MCP reserves -32002 for resources/read "Resource not found" (spec 2025-11-25).
	# Use a distinct server error for pre-init gating.
	rpc_send_line "$(mcp_core_build_error_response "${id_json}" -32000 "Server not initialized" "")"
}

mcp_core_emit_shutting_down() {
	local id_json="$1"
	case "${id_json}" in
	null | '') return 0 ;;
	esac
	if [ -z "${id_json}" ]; then
		id_json="null"
	fi
	rpc_send_line "$(mcp_core_build_error_response "${id_json}" -32003 "Server shutting down" "")"
}

# JSON-RPC 2.0 reserves these literal codes; keep them numeric for clients:
# -32700 parse error, -32600 invalid request, -32601 method not found,
# -32602 invalid params, -32603 internal error.
# We also use the server-reserved range (-32000..-32099) for MCP-specific states:
# -32000 not initialized, -32003 shutting down, -32005 exit before shutdown.
# A request that times out gets -32603. A cancelled request gets no response
# (lib/io.sh drops it), and a tool's own failures are error results, not codes.
mcp_core_build_error_response() {
	local id_json="$1"
	local code="$2"
	local message="$3"
	local data="$4"
	local id_kv
	local data_json
	local message_json

	# MCP requires request IDs MUST NOT be null. For error responses where the
	# request ID is unknown/unreadable (e.g. parse errors), omit `id` entirely
	# rather than emitting `"id": null`.
	case "${id_json:-}" in
	null | '')
		id_kv=''
		;;
	*)
		id_kv=',"id":'"${id_json}"
		;;
	esac
	message_json="$(mcp_json_quote_text "${message}")"

	if [ -n "${data}" ]; then
		case "${data}" in
		"{"* | "["*)
			data_json="${data}"
			;;
		*)
			data_json="$(mcp_json_quote_text "${data}")"
			;;
		esac
		printf '{"jsonrpc":"2.0"%s,"error":{"code":%s,"message":%s,"data":%s}}' "${id_kv}" "${code}" "${message_json}" "${data_json}"
	else
		printf '{"jsonrpc":"2.0"%s,"error":{"code":%s,"message":%s}}' "${id_kv}" "${code}" "${message_json}"
	fi
}

mcp_core_emit_parse_error() {
	local message="$1"
	local code="$2"
	local details="$3"
	rpc_send_line "$(mcp_core_build_error_response "null" "${code}" "${message}" "${details}")"
}

mcp_core_emit_method_not_found() {
	local id_json="$1"
	case "${id_json}" in
	null | '') return 0 ;;
	esac
	rpc_send_line "$(mcp_core_build_error_response "${id_json}" -32601 "Method not found" "")"
}

mcp_core_normalize_timeout() {
	local value="$1"
	value="$(printf '%s' "${value}" | tr -d '\r\n')"
	case "${value}" in
	'') printf '' ;;
	*[!0-9]*) printf '' ;;
	0) printf '' ;;
	*) printf '%s' "${value}" ;;
	esac
}

mcp_core_emit_progress_stream() {
	local key="$1"
	local stream="$2"
	[ -n "${stream}" ] || return 0
	[ -f "${stream}" ] || return 0
	while IFS= read -r line || [ -n "${line}" ]; do
		[ -z "${line}" ] && continue
		if mcp_core_rate_limit "${key}" "progress"; then
			rpc_send_line "${line}"
		fi
	done <"${stream}"
}

mcp_core_extract_log_level() {
	local line="$1"
	local level
	level="$(mcp_json_extract_log_level "${line}" | tr '[:upper:]' '[:lower:]')"
	[ -z "${level}" ] && level="info"
	printf '%s' "${level}"
}

mcp_core_emit_log_stream() {
	local key="$1"
	local stream="$2"
	[ -n "${stream}" ] || return 0
	[ -f "${stream}" ] || return 0
	while IFS= read -r line || [ -n "${line}" ]; do
		[ -z "${line}" ] && continue
		local level
		level="$(mcp_core_extract_log_level "${line}")"
		if mcp_logging_is_enabled "${level}"; then
			if mcp_core_rate_limit "${key}" "log"; then
				rpc_send_line "${line}"
			fi
		fi
	done <"${stream}"
}

mcp_core_emit_registry_notifications() {
	if [ "${MCPBASH_INITIALIZED}" != true ]; then
		return 0
	fi
	# During shutdown, avoid polling registries or emitting list_changed notifications.
	# Registry refresh can run project hooks and touch the filesystem; doing so after
	# a shutdown request can delay processing of the subsequent `exit` and trigger
	# the shutdown watchdog in slow/loaded CI environments.
	if [ "${MCPBASH_SHUTDOWN_PENDING:-false}" = true ]; then
		return 0
	fi

	local allow_list_changed="true"
	case "${MCPBASH_NEGOTIATED_PROTOCOL_VERSION:-${MCPBASH_PROTOCOL_VERSION}}" in
	2025-03-26)
		allow_list_changed="false"
		;;
	2024-11-05)
		allow_list_changed="false"
		;;
	esac

	# Outermost frame for the registry rebuilds: warnings they log inside
	# $(...) captures are queued and flushed here.
	mcp_notification_queue_run mcp_core_poll_registries_once

	if [ "${allow_list_changed}" = "true" ]; then
		mcp_tools_consume_notification true
		if [ -n "${_MCP_NOTIFICATION_PAYLOAD}" ]; then
			rpc_send_line "${_MCP_NOTIFICATION_PAYLOAD}"
		fi
		mcp_resources_consume_notification true
		if [ -n "${_MCP_NOTIFICATION_PAYLOAD}" ]; then
			rpc_send_line "${_MCP_NOTIFICATION_PAYLOAD}"
		fi
		mcp_prompts_consume_notification true
		if [ -n "${_MCP_NOTIFICATION_PAYLOAD}" ]; then
			rpc_send_line "${_MCP_NOTIFICATION_PAYLOAD}"
		fi
	fi
}

mcp_core_poll_registries_once() {
	local now
	now="$(date +%s)"
	if [ "${MCPBASH_LAST_REGISTRY_POLL:-}" = "${now}" ]; then
		return 0
	fi
	MCPBASH_LAST_REGISTRY_POLL="${now}"
	mcp_tools_poll
	mcp_resources_poll
	mcp_prompts_poll
}

# Send the lines of a worker's progress or log stream that were not sent yet.
# Two processes flush the same stream: the background flusher and the
# worker's own final flush. Each reads the offset file, sends from there and
# then writes the new offset, so without a lock both could send the same
# lines. A flush that can't get the lock in time is skipped: the holder is
# sending those lines.
mcp_core_flush_stream() {
	local lock_name="flush.$2.$1"
	# Cheap check first: the background flusher calls this for every stream on
	# every pass, and most have nothing new.
	local stream size offset=""
	stream="$(_mcp_core_stream_path "$1" "$2")"
	[ -f "${stream}" ] || return 0
	size="$(wc -c <"${stream}" 2>/dev/null | tr -d ' ')"
	[ -f "${stream}.offset" ] && offset="$(cat "${stream}.offset" 2>/dev/null)"
	if [ -n "${size}" ] && [ "${size}" = "${offset}" ]; then
		return 0
	fi
	if declare -F mcp_lock_acquire_timeout >/dev/null 2>&1 && [ -n "${MCPBASH_LOCK_ROOT:-}" ]; then
		mcp_lock_acquire_timeout "${lock_name}" 5 || return 0
		_mcp_core_flush_stream_unlocked "$1" "$2"
		local rc=$?
		mcp_lock_release "${lock_name}"
		return "${rc}"
	fi
	_mcp_core_flush_stream_unlocked "$1" "$2"
}

# The worker's streams are progress.<key>.ndjson and logs.<key>.ndjson.
_mcp_core_stream_path() {
	if [ "$2" = "log" ]; then
		printf '%s' "${MCPBASH_STATE_DIR}/logs.$1.ndjson"
	else
		printf '%s' "${MCPBASH_STATE_DIR}/$2.$1.ndjson"
	fi
}

_mcp_core_flush_stream_unlocked() {
	local key="$1"
	local kind="$2"
	local stream
	stream="$(_mcp_core_stream_path "${key}" "${kind}")"
	local request_level=""
	# A modern request's own log level (lib/modern.sh), when it set one.
	if [ "${kind}" = "log" ] && [ -f "${MCPBASH_STATE_DIR}/loglevel.${key}" ]; then
		request_level="$(cat "${MCPBASH_STATE_DIR}/loglevel.${key}" 2>/dev/null || true)"
	fi
	local offset_file="${stream}.offset"
	[ -f "${stream}" ] || return 0
	local last_offset=0
	if [ -f "${offset_file}" ]; then
		last_offset="$(cat "${offset_file}")"
	fi
	local size
	size="$(wc -c <"${stream}" 2>/dev/null | tr -d ' ')"
	case "${size}" in '' | *[!0-9]*) size=0 ;; esac
	case "${last_offset}" in '' | *[!0-9]*) last_offset=0 ;; esac
	if [ "${size}" -lt "${last_offset}" ]; then
		last_offset=0
	fi
	if [ "${size}" -eq "${last_offset}" ]; then
		return 0
	fi
	# The tool may still be appending, so read exactly the bytes measured
	# (reading on to the end of the file would send lines past ${size} and
	# then send them again on the next flush), and send only complete lines:
	# an incomplete last line is sent once it is complete.
	# Git Bash/coreutils `tail -c +N` has been observed to be flaky in CI; use dd
	# for a more portable byte-offset reader.
	local chunk
	chunk="$(mktemp "${MCPBASH_STATE_DIR}/flush.${kind}.${key}.XXXXXX" 2>/dev/null)" || return 0
	dd if="${stream}" of="${chunk}" bs=1 skip="${last_offset}" count=$((size - last_offset)) 2>/dev/null || true
	local complete_lines complete_bytes
	complete_lines="$(LC_ALL=C tr -cd '\n' <"${chunk}" | wc -c | tr -d ' ')"
	if [ "${complete_lines:-0}" -eq 0 ] 2>/dev/null; then
		rm -f "${chunk}"
		return 0
	fi
	complete_bytes="$(head -n "${complete_lines}" "${chunk}" | wc -c | tr -d ' ')"
	head -n "${complete_lines}" "${chunk}" \
		| while IFS= read -r line; do
			[ -z "${line}" ] && continue
			if [ "${kind}" = "log" ]; then
				local level
				level="$(mcp_core_extract_log_level "${line}")"
				if [ -n "${request_level}" ]; then
					if [ "$(mcp_logging_level_rank "${level}")" -lt "$(mcp_logging_level_rank "${request_level}")" ]; then
						continue
					fi
				elif ! mcp_logging_is_enabled "${level}"; then
					continue
				fi
			fi
			if mcp_core_rate_limit "${key}" "${kind}"; then
				rpc_send_line "${line}"
			fi
		done
	rm -f "${chunk}"
	echo "$((last_offset + complete_bytes))" >"${offset_file}"
}

mcp_core_flush_worker_streams_once() {
	local listing key
	listing="$(mcp_ids_list_active_workers 2>/dev/null || true)"
	[ -z "${listing}" ] && return 0
	while IFS= read -r key || [ -n "${key}" ]; do
		[ -z "${key}" ] && continue
		mcp_core_flush_stream "${key}" "progress"
		mcp_core_flush_stream "${key}" "log"
	done <<<"${listing}"
}

mcp_core_start_progress_flusher() {
	if [ -n "${MCPBASH_PROGRESS_FLUSHER_PID:-}" ]; then
		return 0
	fi
	(
		# Keep this loop resilient on platforms where individual iterations may
		# fail (e.g., Git Bash background quirks).
		set +e
		while :; do
			# $$ is the server's PID even in this subshell. Exit with it: a server
			# killed without cleanup (SIGKILL, crash) cannot stop this loop.
			mcp_core_server_alive || exit 0
			if [ "${MCPBASH_ENABLE_LIVE_PROGRESS:-false}" = "true" ]; then
				mcp_core_flush_worker_streams_once || true
			fi
			# Polling tick drives live progress/log emission and pending elicitation
			# prompts without blocking request handlers. Elicitation uses a
			# lock-backed shared counter to avoid ID reuse across processes.
			if declare -F mcp_elicitation_process_requests >/dev/null 2>&1; then
				mcp_elicitation_process_requests || true
			fi
			# Windows Git Bash may reject fractional sleep intervals; fall back to
			# a 1s tick instead of exiting the flusher.
			sleep "${MCPBASH_PROGRESS_FLUSH_INTERVAL:-0.5}" 2>/dev/null || sleep 1
		done
	) &
	MCPBASH_PROGRESS_FLUSHER_PID=$!
}

# A helper that outlives a server killed without cleanup (SIGKILL, a crash):
# once the server is gone it does what the server's exit trap would have
# done, stopping the workers and the tools they started and removing the
# server's state dir. Started with the first request that runs in a worker
# (tools/call, tools/list, resources/read, ...). Its own process, not in
# the job table (so it never counts as a worker), with none of the server's
# stdio (it must not hold the client's pipes open).
mcp_core_start_lifeline() {
	[ -z "${MCPBASH_LIFELINE_PID:-}" ] || return 0
	[ -n "${MCPBASH_STATE_DIR:-}" ] || return 0
	(
		set +e
		trap - EXIT
		# Stopped on a normal exit: take the tick's sleep along.
		tick=""
		trap '[ -z "${tick}" ] || kill "${tick}" 2>/dev/null; exit 0' TERM
		# $$ is the server's PID here too; a zombie counts as gone. Every 5s:
		# on macOS each check runs ps, for as long as the server lives.
		while mcp_core_server_alive; do
			sleep 5 &
			tick=$!
			wait "${tick}"
			tick=""
		done
		mcp_core_stop_all_workers
		mcp_runtime_remove_state_dirs
		mcp_runtime_cleanup_bootstrap
	) </dev/null >/dev/null 2>&1 &
	MCPBASH_LIFELINE_PID=$!
	disown "${MCPBASH_LIFELINE_PID}" 2>/dev/null || true
}

mcp_core_stop_lifeline() {
	local pid="${MCPBASH_LIFELINE_PID:-}"
	[ -n "${pid}" ] || return 0
	MCPBASH_LIFELINE_PID=""
	# Still ours: it exits only after the server is gone.
	kill "${pid}" 2>/dev/null || true
}

mcp_core_stop_progress_flusher() {
	if [ -z "${MCPBASH_PROGRESS_FLUSHER_PID:-}" ]; then
		return 0
	fi
	local pid="${MCPBASH_PROGRESS_FLUSHER_PID}"
	kill "${pid}" 2>/dev/null || true
	# Git Bash can hang on `wait` even after signaling; poll and only reap if exited.
	local attempts=0
	while [ "${attempts}" -lt 30 ] && kill -0 "${pid}" 2>/dev/null; do
		sleep 0.1 2>/dev/null || sleep 1
		attempts=$((attempts + 1))
	done
	if ! kill -0 "${pid}" 2>/dev/null; then
		wait "${pid}" 2>/dev/null || true
	fi
	MCPBASH_PROGRESS_FLUSHER_PID=""
}

mcp_core_start_resource_poll() {
	local interval="${MCPBASH_RESOURCES_POLL_INTERVAL_SECS:-2}"
	case "${interval}" in
	'' | *[!0-9]*) interval=2 ;;
	esac

	if [ "${interval}" -le 0 ]; then
		return 0
	fi
	if mcp_runtime_is_minimal_mode; then
		return 0
	fi

	if [ -n "${MCPBASH_RESOURCE_POLL_PID:-}" ] && kill -0 "${MCPBASH_RESOURCE_POLL_PID}" 2>/dev/null; then
		return 0
	fi

	(
		# Like the flusher: one failed iteration (for example a record removed
		# by an unsubscribe mid-poll) must not end polling for the session.
		set +e
		# Defensive: never append to another frame's notification queue. Each
		# iteration below owns its own.
		# shellcheck disable=SC2034  # read by mcp_notification_queue_active (lib/io.sh)
		MCP_NOTIFICATION_QUEUE_FILE=""
		while :; do
			# Exit with the server ($$ is its PID here too); see the flusher.
			mcp_core_server_alive || exit 0
			mcp_resources_poll_subscriptions_queued || true
			sleep "${interval}"
		done
	) &
	MCPBASH_RESOURCE_POLL_PID=$!
}

mcp_core_stop_resource_poll() {
	if [ -z "${MCPBASH_RESOURCE_POLL_PID:-}" ]; then
		return 0
	fi
	local pid="${MCPBASH_RESOURCE_POLL_PID}"
	kill "${pid}" 2>/dev/null || true
	# Git Bash can hang on `wait` even after signaling; poll and only reap if exited.
	local attempts=0
	while [ "${attempts}" -lt 30 ] && kill -0 "${pid}" 2>/dev/null; do
		sleep 0.1 2>/dev/null || sleep 1
		attempts=$((attempts + 1))
	done
	if ! kill -0 "${pid}" 2>/dev/null; then
		wait "${pid}" 2>/dev/null || true
	fi
	MCPBASH_RESOURCE_POLL_PID=""
}
