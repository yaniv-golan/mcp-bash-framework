#!/usr/bin/env bash
# Timeout orchestration via watchdog processes.

set -euo pipefail

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

	# Spawn command
	("${cmd[@]}") &
	worker_pid=$!

	mcp_runtime_set_process_group "${worker_pid}" || true
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

	mcp_timeout_spawn_watchdog "${worker_pid}" "${worker_pgid}" "${seconds}" "${watchdog_state}" "${main_pgid}" "${watchdog_token}" "${caller_pgid}" &
	watchdog_pid=$!

	wait "${worker_pid}"
	local status=$?

	if kill -0 "${watchdog_pid}" 2>/dev/null; then
		kill -TERM "${watchdog_pid}" 2>/dev/null
	fi
	wait "${watchdog_pid}" 2>/dev/null || true

	if [ -n "${watchdog_state}" ] && [ -f "${watchdog_state}" ]; then
		if grep -Fq "timeout" "${watchdog_state}" 2>/dev/null; then
			status=124
		fi
		rm -f "${watchdog_state}"
	fi

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
	local remaining

	remaining="${seconds}"

	while [ "${remaining}" -gt 0 ]; do
		sleep 1
		if ! kill -0 "${worker_pid}" 2>/dev/null; then
			[ -n "${state_file}" ] && rm -f "${state_file}"
			exit 0
		fi
		if [ -n "${state_file}" ] && [ -n "${token}" ] && [ -f "${state_file}" ]; then
			local current_token
			current_token="$(awk '{print $4}' "${state_file}" 2>/dev/null || true)"
			if [ "${current_token}" != "${token}" ]; then
				exit 0
			fi
		fi
		remaining=$((remaining - 1))
	done

	if ! kill -0 "${worker_pid}" 2>/dev/null; then
		[ -n "${state_file}" ] && rm -f "${state_file}"
		exit 0
	fi

	[ -n "${state_file}" ] && printf 'timeout\n' >>"${state_file}"

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

	if [ -n "${state_file}" ] && [ -f "${state_file}" ]; then
		local current_token
		current_token="$(awk '{print $4}' "${state_file}" 2>/dev/null || true)"
		if [ -z "${token}" ] || [ "${current_token}" = "${token}" ]; then
			rm -f "${state_file}"
		fi
	fi
	exit 0
}
