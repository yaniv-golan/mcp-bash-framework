#!/usr/bin/env bash
# Portable lock-dir primitives for stdout serialization and state coordination.

set -euo pipefail

MCPBASH_LOCK_POLL_INTERVAL="${MCPBASH_LOCK_POLL_INTERVAL:-0.02}"
MCPBASH_LOCK_REAP_GRACE_SECS="${MCPBASH_LOCK_REAP_GRACE_SECS:-1}"

mcp_lock_init() {
	if [ -z "${MCPBASH_LOCK_ROOT}" ]; then
		printf '%s\n' 'MCPBASH_LOCK_ROOT not set; call mcp_runtime_init_paths first.' >&2
		exit 1
	fi
	mkdir -p "${MCPBASH_LOCK_ROOT}"
}

mcp_lock_path() {
	printf '%s/%s.lock' "${MCPBASH_LOCK_ROOT}" "$1"
}

mcp_lock_stat_mtime() {
	local path="$1"
	local mtime="0"
	if [ ! -e "${path}" ]; then
		printf '%s' "${mtime}"
		return 0
	fi
	if command -v stat >/dev/null 2>&1; then
		# The path can vanish between checks (another process released it).
		mtime="$(stat -c %Y "${path}" 2>/dev/null || stat -f %m "${path}" 2>/dev/null || printf '0')"
		case "${mtime}" in
		'' | *[!0-9]*) mtime="0" ;;
		esac
	fi
	printf '%s' "${mtime}"
}

# The lock root lives in the server's state directory, which cleanup removes on
# exit. A worker still waiting then can never create its lock dir, so the
# acquire functions give up (return 1) instead of polling forever.
mcp_lock_root_gone() {
	[ ! -d "${MCPBASH_LOCK_ROOT}" ]
}

# Create the lock dir and record this process as its owner. The pid is written
# to a temp file in the lock root and renamed into place, so a lock's pid file
# is either absent (acquire in progress) or complete, never empty. Returns 1 if
# the lock is held, or if the dir vanished before the pid landed (the caller
# retries).
mcp_lock_try_create() {
	local path="$1"
	local tmp
	mkdir "${path}" 2>/dev/null || return 1
	tmp="${MCPBASH_LOCK_ROOT}/.pid.${path##*/}.${BASHPID:-$$}.${RANDOM}"
	if printf '%s' "${BASHPID:-$$}" >"${tmp}" 2>/dev/null && mv -f "${tmp}" "${path}/pid" 2>/dev/null; then
		return 0
	fi
	rm -f "${tmp}" 2>/dev/null || true
	# rmdir only removes the dir while it is still empty, i.e. not yet owned.
	rmdir "${path}" 2>/dev/null || true
	return 1
}

mcp_lock_acquire() {
	local name="$1"
	local path
	path="$(mcp_lock_path "${name}")"

	while :; do
		if mcp_lock_try_create "${path}"; then
			break
		fi
		if mcp_lock_root_gone; then
			return 1
		fi
		mcp_lock_try_reap "${path}"
		sleep "${MCPBASH_LOCK_POLL_INTERVAL}"
	done
}

mcp_lock_acquire_timeout() {
	local name="$1"
	local timeout_secs="${2:-5}"
	local path
	path="$(mcp_lock_path "${name}")"
	local start
	start="$(date +%s)"

	while :; do
		if mcp_lock_try_create "${path}"; then
			break
		fi
		if mcp_lock_root_gone; then
			return 1
		fi
		mcp_lock_try_reap "${path}"
		if [ "${timeout_secs}" -gt 0 ]; then
			local now
			now="$(date +%s)"
			if [ $((now - start)) -ge "${timeout_secs}" ]; then
				return 1
			fi
		fi
		sleep "${MCPBASH_LOCK_POLL_INTERVAL}"
	done
}

mcp_lock_debug() {
	if [ "${MCPBASH_LOG_LEVEL:-info}" = "debug" ]; then
		printf 'mcp-lock: %s\n' "$1" >&2
	fi
}

# Release a lock this process holds. Anything else is left alone: a lock owned
# by another live process, or one with no pid yet (another process is in the
# middle of acquiring it). Locks of dead owners are removed by reaping.
mcp_lock_release() {
	local name="$1"
	local path
	local owner=""
	local current_pid="${BASHPID:-$$}"
	path="$(mcp_lock_path "${name}")"
	if [ -d "${path}" ]; then
		owner="$(cat "${path}/pid" 2>/dev/null || true)"
		if [ "${owner}" = "${current_pid}" ]; then
			rm -rf "${path}" 2>/dev/null || true
		else
			mcp_lock_debug "not releasing lock ${name}: owner is '${owner}', not ${current_pid}"
		fi
	fi
}

# Run "mcp_lock_reap_now PATH [EXPECTED_PID]" while holding the lock's reap
# guard, so only one process at a time can remove a lock it did not create.
# Without the guard, two reapers that both saw a dead owner could interleave
# with a fresh acquire, and the slower one would delete the new holder's lock.
# A guard older than MCPBASH_LOCK_REAP_GUARD_STALE_SECS belongs to a reaper
# that died; it is cleared, and reaping happens on a later poll.
mcp_lock_with_reap_guard() {
	local path="$1"
	local expected="${2:-}"
	local guard="${MCPBASH_LOCK_ROOT}/.reap.${path##*/}"
	if ! mkdir "${guard}" 2>/dev/null; then
		local now mtime
		now="$(date +%s)"
		mtime="$(mcp_lock_stat_mtime "${guard}")"
		if [ "${mtime}" != "0" ] && [ $((now - mtime)) -gt "${MCPBASH_LOCK_REAP_GUARD_STALE_SECS:-5}" ]; then
			rmdir "${guard}" 2>/dev/null || true
		fi
		return 0
	fi
	mcp_lock_reap_now "${path}" "${expected}"
	rmdir "${guard}" 2>/dev/null || true
}

# Remove the lock at PATH if it is stale: no pid file after the grace period,
# or a dead owner. With EXPECTED_PID, also remove it if that pid owns it (the
# caller knows that process is gone). Call only through mcp_lock_with_reap_guard.
mcp_lock_reap_now() {
	local path="$1"
	local expected="${2:-}"
	local owner now mtime age
	[ -d "${path}" ] || return 0
	owner="$(cat "${path}/pid" 2>/dev/null || true)"
	if [ -z "${owner}" ]; then
		now="$(date +%s)"
		mtime="$(mcp_lock_stat_mtime "${path}")"
		age=$((now - mtime))
		# Grace window: allow the creator to finish writing the pid file.
		# Times are whole seconds, so age 1 can mean 10ms; -le makes the
		# real minimum at least GRACE seconds.
		if [ "${age}" -le "${MCPBASH_LOCK_REAP_GRACE_SECS}" ]; then
			return 0
		fi
		rm -rf "${path}" 2>/dev/null || true
		return 0
	fi
	if [ -n "${expected}" ] && [ "${owner}" = "${expected}" ]; then
		rm -rf "${path}" 2>/dev/null || true
		return 0
	fi
	if kill -0 "${owner}" 2>/dev/null; then
		return 0
	fi
	rm -rf "${path}" 2>/dev/null || true
}

mcp_lock_try_reap() {
	local path="$1"
	local owner
	[ -d "${path}" ] || return 0
	# Fast path: a live owner means nothing to reap, no guard needed.
	owner="$(cat "${path}/pid" 2>/dev/null || true)"
	if [ -n "${owner}" ] && kill -0 "${owner}" 2>/dev/null; then
		return 0
	fi
	mcp_lock_with_reap_guard "${path}"
}

# Clear a lock held by OWNER_PID, a process the caller knows has exited, or by
# any dead owner.
mcp_lock_release_owned() {
	local name="$1"
	local owner_pid="$2"
	local path

	if [ -z "${name}" ] || [ -z "${owner_pid}" ]; then
		return 0
	fi

	path="$(mcp_lock_path "${name}")"
	[ -d "${path}" ] || return 0
	mcp_lock_with_reap_guard "${path}" "${owner_pid}"
}
