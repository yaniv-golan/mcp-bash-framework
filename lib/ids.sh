#!/usr/bin/env bash
# Request id encoding, pid registry, and cancellation markers.

set -euo pipefail

mcp_ids_init_state() {
	if [ -z "${MCPBASH_STATE_DIR}" ]; then
		printf '%s\n' 'MCPBASH_STATE_DIR not established; call mcp_runtime_init_paths first.' >&2
		exit 1
	fi

	mkdir -p "${MCPBASH_STATE_DIR}"
}

mcp_ids_key_from_json() {
	local json_id="$1"

	if [ -z "${json_id}" ] || [ "${json_id}" = "null" ]; then
		printf ''
		return 0
	fi

	mcp_ids_encode "${json_id}"
}

mcp_ids_encode() {
	local raw="$1"
	local encoded

	encoded="$(mcp_ids_base64url "${raw}")"

	if [ ${#encoded} -gt 200 ]; then
		encoded="$(mcp_ids_sha256 "${raw}")"
	fi

	printf '%s' "${encoded}"
}

mcp_ids_base64url() {
	if command -v base64 >/dev/null 2>&1; then
		printf '%s' "${1}" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='
	else
		printf '%s' "${1}" | openssl base64 2>/dev/null | tr -d '\n' | tr '+/' '-_' | tr -d '='
	fi
}

mcp_ids_sha256() {
	local raw="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "${raw}" | sha256sum | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		printf '%s' "${raw}" | shasum -a 256 | awk '{print $1}'
	elif command -v openssl >/dev/null 2>&1; then
		printf '%s' "${raw}" | openssl dgst -sha256 | awk '{print $NF}'
	else
		# Fallback: include checksum and length to lessen collisions.
		printf '%s' "${raw}" | cksum | awk '{printf "%s-%s", $1, $2}'
	fi
}

mcp_ids_state_path() {
	local prefix="$1"
	local key="$2"
	printf '%s/%s.%s' "${MCPBASH_STATE_DIR}" "${prefix}" "${key}"
}

mcp_ids_track_worker() {
	local key="$1"
	local pid="$2"
	local pgid="$3"
	local stderr_path="$4"

	if [ -z "${key}" ]; then
		return 0
	fi

	local path
	path="$(mcp_ids_state_path "pid" "${key}")"
	printf '%s %s %s' "${pid}" "${pgid}" "${stderr_path}" >"${path}"
}

mcp_ids_clear_worker() {
	local key="$1"

	if [ -z "${key}" ]; then
		return 0
	fi

	local pid_path
	pid_path="$(mcp_ids_state_path "pid" "${key}")"
	if [ -f "${pid_path}" ]; then
		rm -f "${pid_path}"
	fi

	local cancelled_path
	cancelled_path="$(mcp_ids_state_path "cancelled" "${key}")"
	if [ -f "${cancelled_path}" ]; then
		rm -f "${cancelled_path}"
	fi
}

mcp_ids_mark_cancelled() {
	local key="$1"
	if [ -z "${key}" ]; then
		return 0
	fi
	local cancelled_path
	cancelled_path="$(mcp_ids_state_path "cancelled" "${key}")"
	printf '%s' "1" >"${cancelled_path}"
}

mcp_ids_is_cancelled_key() {
	local key="$1"
	if [ -z "${key}" ]; then
		return 1
	fi

	local cancelled_path
	cancelled_path="$(mcp_ids_state_path "cancelled" "${key}")"
	[ -f "${cancelled_path}" ]
}

mcp_ids_worker_info() {
	local key="$1"
	local pid_path
	pid_path="$(mcp_ids_state_path "pid" "${key}")"
	if [ ! -f "${pid_path}" ]; then
		return 1
	fi
	cat "${pid_path}"
}
