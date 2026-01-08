#!/usr/bin/env bash
# Timeout orchestration via watchdog processes.
# Supports progress-aware timeout extension when MCPBASH_PROGRESS_EXTENDS_TIMEOUT=true.

set -euo pipefail

# Install debug EXIT trap if MCPBASH_DEBUG=true (helps diagnose set -e exits)
if declare -f mcp_runtime_install_debug_trap >/dev/null 2>&1; then
	mcp_runtime_install_debug_trap
fi

# Cross-platform stat mtime detection (run once at load time)
# Using array for robustness with the variable-as-command pattern
# Note: Use ${BASH_SOURCE[0]} instead of /dev/null for Windows/MSYS2 compatibility
# Note: Redirect stdout to /dev/null to prevent output pollution when sourced
MCPBASH_STAT_MTIME_ARGS=()
if stat -f %m "${BASH_SOURCE[0]:-$0}" >/dev/null 2>&1; then
	MCPBASH_STAT_MTIME_ARGS=(-f %m)
elif stat -c %Y "${BASH_SOURCE[0]:-$0}" >/dev/null 2>&1; then
	MCPBASH_STAT_MTIME_ARGS=(-c %Y)
else
	# Neither stat flavor detected - will fall back to per-call attempts
	# Log at debug level to help diagnose obscure platforms
	if [ "${MCPBASH_DEBUG:-}" = "true" ]; then
		printf '[timeout] warning: stat mtime detection failed, using fallback\n' >&2
	fi
fi

# Get current epoch time
mcp_timeout_now() {
	date +%s
}

# Get file modification time as epoch seconds
# Returns 1 if file doesn't exist or stat fails
mcp_timeout_file_mtime() {
	local file="$1"
	[ -f "${file}" ] || return 1
	if [ "${#MCPBASH_STAT_MTIME_ARGS[@]}" -gt 0 ]; then
		stat "${MCPBASH_STAT_MTIME_ARGS[@]}" "${file}" 2>/dev/null && return 0
	fi
	# Fallback: try both (shouldn't happen if detection worked)
	stat -f %m "${file}" 2>/dev/null && return 0
	stat -c %Y "${file}" 2>/dev/null && return 0
	return 1
}

# Terminate worker process (extracted for reuse)
mcp_timeout_terminate_worker() {
	local worker_pid="$1"
	local worker_pgid="$2"
	local state_file="$3"
	local main_pgid="$4"

	# Read isolation status from state file (5th field)
	local isolated="false"
	if [ -n "${state_file}" ] && [ -f "${state_file}" ]; then
		isolated="$(awk '{print $5}' "${state_file}" 2>/dev/null || echo "false")"
	fi

	# Only use process group signals if the worker is properly isolated.
	# Otherwise, we'd kill the caller along with the tool!
	if [ "${isolated}" = "true" ]; then
		mcp_runtime_signal_group "${worker_pgid}" TERM "${worker_pid}" "${main_pgid}"
	else
		# Process not isolated - only signal the specific PID
		kill -TERM "${worker_pid}" 2>/dev/null || true
	fi

	sleep 1

	if kill -0 "${worker_pid}" 2>/dev/null; then
		if [ "${isolated}" = "true" ]; then
			mcp_runtime_signal_group "${worker_pgid}" KILL "${worker_pid}" "${main_pgid}"
		else
			kill -KILL "${worker_pid}" 2>/dev/null || true
		fi
	fi
}

with_timeout() {
	local seconds
	local cmd

	if [ $# -lt 3 ]; then
		printf '%s\n' 'with_timeout expects: with_timeout <seconds> -- <command...>' >&2
		return 1
	fi

	seconds="$1"
	shift

	case "${seconds}" in
	'' | *[!0-9]*)
		printf '%s\n' 'with_timeout expects integer seconds' >&2
		return 1
		;;
	esac

	if ! [ "$1" = "--" ]; then
		printf '%s\n' 'with_timeout usage: with_timeout <seconds> -- <command...>' >&2
		return 1
	fi

	shift
	cmd=("$@")

	local worker_pid
	local watchdog_pid
	local worker_pgid=""
	local watchdog_state=""
	local main_pgid="${MCPBASH_MAIN_PGID:-}"
	local watchdog_token=""

	# Spawn command as background process
	("${cmd[@]}") &
	worker_pid=$!

	# Look up process group - if job control is active in the environment,
	# the worker may already be in its own group
	worker_pgid="$(mcp_runtime_lookup_pgid "${worker_pid}")"

	# Capture the caller's pgid so watchdog can avoid killing it
	local caller_pgid=""
	caller_pgid="$(mcp_runtime_lookup_pgid "$$")"

	# The worker is truly isolated ONLY if it's the leader of its own process group
	# (pgid == pid). Otherwise, signaling the group would kill other processes.
	local isolated="false"
	if [ -n "${worker_pgid}" ] && [ "${worker_pgid}" = "${worker_pid}" ]; then
		# Worker is its own group leader - safe to signal the group
		isolated="true"
	fi

	if [ -n "${MCPBASH_STATE_DIR:-}" ]; then
		watchdog_state="${MCPBASH_STATE_DIR}/watchdog.${worker_pid}.log"
		watchdog_token="${worker_pid}.${RANDOM}.${SECONDS}"
		printf '%s %s %s %s %s\n' "${worker_pid}" "${worker_pgid}" "${seconds}" "${watchdog_token}" "${isolated}" >"${watchdog_state}"
	fi

	# Watchdog reads progress settings from inherited environment:
	#   MCPBASH_PROGRESS_EXTENDS_TIMEOUT, MCPBASH_MAX_TIMEOUT_SECS, MCP_PROGRESS_STREAM
	# No new arguments needed - watchdog runs inside worker subshell context
	mcp_timeout_spawn_watchdog "${worker_pid}" "${worker_pgid}" "${seconds}" "${watchdog_state}" "${main_pgid}" "${watchdog_token}" "${caller_pgid}" &
	watchdog_pid=$!

	wait "${worker_pid}"
	local status=$?
	local timeout_reason=""

	if kill -0 "${watchdog_pid}" 2>/dev/null; then
		kill -TERM "${watchdog_pid}" 2>/dev/null
	fi
	wait "${watchdog_pid}" 2>/dev/null || true

	# Check state file for timeout reason (single grep)
	if [ -n "${watchdog_state}" ] && [ -f "${watchdog_state}" ]; then
		# Note: local + assignment on one line prevents set -e exit on grep failure
		# shellcheck disable=SC2155 # Intentional: we want local to mask grep exit code
		local timeout_line=$(grep -oE 'timeout(:idle|:max_exceeded)?' "${watchdog_state}" 2>/dev/null | head -1)
		if [ -n "${timeout_line}" ]; then
			status=124
			case "${timeout_line}" in
			timeout:max_exceeded) timeout_reason="max_exceeded" ;;
			timeout:idle) timeout_reason="idle" ;;
			timeout) timeout_reason="fixed" ;;
			esac
		fi
		rm -f "${watchdog_state}"
	fi

	# Export reason for error handler to use
	# Note: This runs in the same shell that called with_timeout, which is
	# the worker subshell (core.sh:729-742). mcp_tools_invoke_handler calls
	# with_timeout and then formats the error in the same subshell context.
	export MCPBASH_TIMEOUT_REASON="${timeout_reason}"

	return "${status}"
}

mcp_timeout_spawn_watchdog() {
	local worker_pid="$1"
	local worker_pgid="$2"
	local seconds="$3"
	local state_file="$4"
	local main_pgid="$5"
	local token="$6"
	local caller_pgid="$7"

	# Read settings from environment (inherited from worker subshell)
	# This avoids argument explosion and leverages existing env var exports
	local progress_extends="${MCPBASH_PROGRESS_EXTENDS_TIMEOUT:-false}"
	local max_timeout="${MCPBASH_MAX_TIMEOUT_SECS:-600}"
	local progress_file="${MCP_PROGRESS_STREAM:-}"

	local last_activity_time
	local total_elapsed=0
	# Capture start time for initialization (loop uses fresh timestamps)
	local init_now
	init_now=$(mcp_timeout_now)

	# Initialize from progress file mtime if exists, else current time
	# This avoids race condition where file pre-creation happens before watchdog starts
	if [ -n "${progress_file}" ] && [ -f "${progress_file}" ]; then
		local file_mtime
		file_mtime=$(mcp_timeout_file_mtime "${progress_file}" || echo "")
		# Guard against stale mtime from previous failed request:
		# Reject mtime older than 5 seconds (tighter than full timeout to avoid
		# accepting near-threshold stale files that don't reflect current activity)
		if [[ -n "${file_mtime}" && "${file_mtime}" =~ ^[0-9]+$ &&
			"${file_mtime}" -gt $((init_now - 5)) ]]; then
			last_activity_time="${file_mtime}"
		else
			last_activity_time="${init_now}"
		fi
	else
		last_activity_time="${init_now}"
	fi

	while true; do
		sleep 1
		total_elapsed=$((total_elapsed + 1))

		# Check if process completed
		if ! kill -0 "${worker_pid}" 2>/dev/null; then
			[ -n "${state_file}" ] && rm -f "${state_file}"
			exit 0
		fi

		# Check cancellation token
		if [ -n "${state_file}" ] && [ -n "${token}" ] && [ -f "${state_file}" ]; then
			local current_token
			current_token="$(awk '{print $4}' "${state_file}" 2>/dev/null || true)"
			if [ "${current_token}" != "${token}" ]; then
				exit 0
			fi
		fi

		# Progress-aware timeout extension
		if [ "${progress_extends}" = "true" ] && [ -n "${progress_file}" ]; then
			local file_mtime
			file_mtime=$(mcp_timeout_file_mtime "${progress_file}" || echo "")

			# Validate mtime is numeric before comparison to avoid bash errors
			if [[ -n "${file_mtime}" && "${file_mtime}" =~ ^[0-9]+$ &&
				"${file_mtime}" -gt "${last_activity_time}" ]]; then
				# Progress detected - reset idle timer
				last_activity_time="${file_mtime}"
				# Debug logging (only when MCPBASH_DEBUG is set)
				if [ "${MCPBASH_DEBUG:-}" = "true" ]; then
					printf '[watchdog] timeout extended: progress at %s, idle reset\n' "${file_mtime}" >&2
				fi
			fi

			# Check idle timeout (time since last progress)
			local now
			now=$(mcp_timeout_now)
			local idle_time=$((now - last_activity_time))

			if [ "${idle_time}" -ge "${seconds}" ]; then
				# No progress for ${seconds} - idle timeout
				[ -n "${state_file}" ] && printf 'timeout:idle\n' >>"${state_file}"
				mcp_timeout_terminate_worker "${worker_pid}" "${worker_pgid}" "${state_file}" "${main_pgid}"
				exit 0
			fi

			# Check hard cap
			if [ "${total_elapsed}" -ge "${max_timeout}" ]; then
				# Hard cap reached regardless of progress
				[ -n "${state_file}" ] && printf 'timeout:max_exceeded\n' >>"${state_file}"
				mcp_timeout_terminate_worker "${worker_pid}" "${worker_pgid}" "${state_file}" "${main_pgid}"
				exit 0
			fi
		else
			# Legacy fixed countdown behavior
			if [ "${total_elapsed}" -ge "${seconds}" ]; then
				[ -n "${state_file}" ] && printf 'timeout\n' >>"${state_file}"
				mcp_timeout_terminate_worker "${worker_pid}" "${worker_pgid}" "${state_file}" "${main_pgid}"
				exit 0
			fi
		fi
	done
}
