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

	("${cmd[@]}") &
	worker_pid=$!

	mcp_runtime_set_process_group "${worker_pid}" || true
	worker_pgid="$(mcp_runtime_lookup_pgid "${worker_pid}")"

	if [ -n "${MCPBASH_STATE_DIR:-}" ]; then
		watchdog_state="${MCPBASH_STATE_DIR}/watchdog.${worker_pid}.log"
		watchdog_token="${worker_pid}.${RANDOM}.${SECONDS}"
		printf '%s %s %s %s\n' "${worker_pid}" "${worker_pgid}" "${seconds}" "${watchdog_token}" >"${watchdog_state}"
	fi

	mcp_timeout_spawn_watchdog "${worker_pid}" "${worker_pgid}" "${seconds}" "${watchdog_state}" "${main_pgid}" "${watchdog_token}" &
	watchdog_pid=$!

	wait "${worker_pid}"
	local status=$?

	if kill -0 "${watchdog_pid}" 2>/dev/null; then
		kill -TERM "${watchdog_pid}" 2>/dev/null
	fi
	wait "${watchdog_pid}" 2>/dev/null || true

	if [ -n "${watchdog_state}" ] && [ -f "${watchdog_state}" ]; then
		local current_token
		current_token="$(awk '{print $4}' "${watchdog_state}" 2>/dev/null || true)"
		if [ -n "${watchdog_token}" ] && [ "${current_token}" = "${watchdog_token}" ]; then
			if grep -Fq "timeout" "${watchdog_state}" 2>/dev/null; then
				status=124
			fi
			rm -f "${watchdog_state}"
		fi
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
	local parent_pid="$PPID"
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

	[ -n "${state_file}" ] && printf '%s\n' "timeout" >"${state_file}"

	mcp_runtime_signal_group "${worker_pgid}" TERM "${worker_pid}" "${main_pgid}"
	sleep 1
	if kill -0 "${worker_pid}" 2>/dev/null; then
		mcp_runtime_signal_group "${worker_pgid}" KILL "${worker_pid}" "${main_pgid}"
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
