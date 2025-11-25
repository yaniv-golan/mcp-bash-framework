#!/usr/bin/env bash
# Portable lock-dir primitives for stdout serialization and state coordination.

set -euo pipefail

MCPBASH_LOCK_POLL_INTERVAL="0.01"

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
	if [ ! -d "${path}" ]; then
		return
	fi
	if [ ! -f "${path}/pid" ]; then
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
