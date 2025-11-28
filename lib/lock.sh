#!/usr/bin/env bash
# Portable lock-dir primitives for stdout serialization and state coordination.

set -euo pipefail

MCPBASH_LOCK_POLL_INTERVAL="0.01"
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
		if stat -c %Y "${path}" >/dev/null 2>&1; then
			mtime="$(stat -c %Y "${path}")"
		elif stat -f %m "${path}" >/dev/null 2>&1; then
			mtime="$(stat -f %m "${path}")"
		fi
	fi
	printf '%s' "${mtime}"
}

mcp_lock_acquire() {
	local name="$1"
	local path
	path="$(mcp_lock_path "${name}")"

	while :; do
		if mkdir "${path}" 2>/dev/null; then
			if printf '%s' "${BASHPID:-$$}" >"${path}/pid" 2>/dev/null; then
				break
			fi
			rm -rf "${path}" 2>/dev/null || true
		else
			mcp_lock_try_reap "${path}"
			sleep "${MCPBASH_LOCK_POLL_INTERVAL}"
		fi
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
		if mkdir "${path}" 2>/dev/null; then
			if printf '%s' "${BASHPID:-$$}" >"${path}/pid" 2>/dev/null; then
				break
			fi
			rm -rf "${path}" 2>/dev/null || true
		else
			mcp_lock_try_reap "${path}"
			if [ "${timeout_secs}" -gt 0 ]; then
				local now
				now="$(date +%s)"
				if [ $((now - start)) -ge "${timeout_secs}" ]; then
					return 1
				fi
			fi
			sleep "${MCPBASH_LOCK_POLL_INTERVAL}"
		fi
	done
}

mcp_lock_release() {
	local name="$1"
	local path
	local owner=""
	local current_pid="${BASHPID:-$$}"
	path="$(mcp_lock_path "${name}")"
	if [ -d "${path}" ]; then
		owner="$(cat "${path}/pid" 2>/dev/null || true)"
		if [ -z "${owner}" ] || [ "${owner}" = "${current_pid}" ] || ! kill -0 "${owner}" 2>/dev/null; then
			rm -rf "${path}"
		else
			printf '%s\n' "mcp-lock: refusing to release lock ${name} owned by pid ${owner}" >&2
		fi
	fi
}

mcp_lock_try_reap() {
	local path="$1"
	local owner
	local current
	local now age mtime
	if [ ! -d "${path}" ]; then
		return
	fi
	if [ ! -f "${path}/pid" ]; then
		now="$(date +%s)"
		mtime="$(mcp_lock_stat_mtime "${path}")"
		age=$((now - mtime))
		if [ "${age}" -lt "${MCPBASH_LOCK_REAP_GRACE_SECS}" ]; then
			# Grace window: allow the creator to finish writing the pid file.
			return
		fi
		rm -rf "${path}"
		return
	fi

	owner="$(cat "${path}/pid" 2>/dev/null || true)"
	if [ -z "${owner}" ]; then
		rm -rf "${path}"
		return
	fi

	if kill -0 "${owner}" 2>/dev/null; then
		return
	fi

	current="$(cat "${path}/pid" 2>/dev/null || true)"
	if [ "${current}" != "${owner}" ]; then
		return
	fi

	rm -rf "${path}"
}

mcp_lock_release_owned() {
	local name="$1"
	local owner_pid="$2"
	local path
	local recorded=""

	if [ -z "${name}" ] || [ -z "${owner_pid}" ]; then
		return 0
	fi

	path="$(mcp_lock_path "${name}")"
	if [ ! -d "${path}" ]; then
		return 0
	fi

	recorded="$(cat "${path}/pid" 2>/dev/null || true)"
	if [ -z "${recorded}" ]; then
		rm -rf "${path}"
		return 0
	fi

	# Clear the lock if it belongs to the specified pid or the recorded owner is gone.
	if [ "${recorded}" = "${owner_pid}" ] || ! kill -0 "${recorded}" 2>/dev/null; then
		rm -rf "${path}"
	fi
}
