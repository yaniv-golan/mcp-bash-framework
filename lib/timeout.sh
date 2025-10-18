#!/usr/bin/env bash
# Spec §6: timeout orchestration via watchdog processes.

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

	("${cmd[@]}") &
	worker_pid=$!

	mcp_runtime_set_process_group "${worker_pid}" || true
	worker_pgid="$(mcp_runtime_lookup_pgid "${worker_pid}")"

	if [ -n "${MCPBASH_STATE_DIR:-}" ]; then
		watchdog_state="${MCPBASH_STATE_DIR}/watchdog.${worker_pid}.log"
		printf '%s %s %s\n' "${worker_pid}" "${worker_pgid}" "${seconds}" >"${watchdog_state}"
	fi

	mcp_timeout_spawn_watchdog "${worker_pid}" "${worker_pgid}" "${seconds}" "${watchdog_state}" "${main_pgid}" &
	watchdog_pid=$!

	wait "${worker_pid}"
	local status=$?

	if kill -0 "${watchdog_pid}" 2>/dev/null; then
		kill -TERM "${watchdog_pid}" 2>/dev/null
	fi
	wait "${watchdog_pid}" 2>/dev/null || true

	if [ -n "${watchdog_state}" ]; then
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
	local parent_pid="$PPID"
	local remaining

	remaining="${seconds}"

	while [ "${remaining}" -gt 0 ]; do
		sleep 1
		if ! kill -0 "${worker_pid}" 2>/dev/null; then
			[ -n "${state_file}" ] && rm -f "${state_file}"
			exit 0
		fi
		if ! kill -0 "${parent_pid}" 2>/dev/null; then
			exit 0
		fi
		remaining=$((remaining - 1))
	done

	if ! kill -0 "${worker_pid}" 2>/dev/null; then
		[ -n "${state_file}" ] && rm -f "${state_file}"
		exit 0
	fi

	[ -n "${state_file}" ] && printf '%s\n' "timeout" >"${state_file}"

	mcp_runtime_signal_group "${worker_pgid}" TERM "${worker_pid}" "${main_pgid}"
	sleep 1
	if kill -0 "${worker_pid}" 2>/dev/null; then
		mcp_runtime_signal_group "${worker_pgid}" KILL "${worker_pid}" "${main_pgid}"
	fi

	[ -n "${state_file}" ] && rm -f "${state_file}"
	exit 0
}
