#!/usr/bin/env bash
# Registry refresh helpers (fast-path detection and locked writes).

set -euo pipefail

MCPBASH_REGISTRY_FASTPATH_FILE=""

mcp_registry_fastpath_file() {
	if [ -z "${MCPBASH_STATE_DIR:-}" ]; then
		return 1
	fi
	if [ -z "${MCPBASH_REGISTRY_FASTPATH_FILE}" ]; then
		MCPBASH_REGISTRY_FASTPATH_FILE="${MCPBASH_STATE_DIR}/registry.fastpath.json"
	fi
	printf '%s' "${MCPBASH_REGISTRY_FASTPATH_FILE}"
}

mcp_registry_stat_mtime() {
	local path="$1"
	if [ ! -e "${path}" ]; then
		printf '0'
		return 0
	fi
	if command -v stat >/dev/null 2>&1; then
		# Prefer GNU stat (-c) for portable numeric mtime; fall back to BSD (-f).
		if stat -c %Y "${path}" >/dev/null 2>&1; then
			stat -c %Y "${path}"
			return 0
		fi
		if stat -f %m "${path}" >/dev/null 2>&1; then
			stat -f %m "${path}"
			return 0
		fi
	fi
	printf '0'
}

mcp_registry_fastpath_snapshot() {
	local root="$1"
	local scan_root="${root}"
	if [ ! -d "${scan_root}" ]; then
		printf '0|0|0'
		return 0
	fi
	local count hash mtime
	count="$(find "${scan_root}" -type f ! -name ".*" 2>/dev/null | wc -l | tr -d ' ')"
	hash="$(find "${scan_root}" -type f ! -name ".*" 2>/dev/null | LC_ALL=C sort | cksum | awk '{print $1}')"
	mtime="$(mcp_registry_stat_mtime "${scan_root}")"
	printf '%s|%s|%s' "${count:-0}" "${hash:-0}" "${mtime:-0}"
}

mcp_registry_fastpath_unchanged() {
	local kind="$1"
	local snapshot="$2"
	if [ "${MCPBASH_JSON_TOOL:-}" = "none" ] || [ -z "${MCPBASH_JSON_TOOL_BIN:-}" ]; then
		return 1
	fi
	local file
	if ! file="$(mcp_registry_fastpath_file)"; then
		return 1
	fi
	if [ ! -f "${file}" ]; then
		return 1
	fi
	local count hash mtime
	IFS='|' read -r count hash mtime <<<"${snapshot}"
	if [ -z "${count}" ] || [ -z "${hash}" ] || [ -z "${mtime}" ]; then
		return 1
	fi
	local prev_count prev_hash prev_mtime
	prev_count="$("${MCPBASH_JSON_TOOL_BIN}" -r --arg kind "${kind}" '.[$kind].count // empty' "${file}" 2>/dev/null || true)"
	prev_hash="$("${MCPBASH_JSON_TOOL_BIN}" -r --arg kind "${kind}" '.[$kind].hash // empty' "${file}" 2>/dev/null || true)"
	prev_mtime="$("${MCPBASH_JSON_TOOL_BIN}" -r --arg kind "${kind}" '.[$kind].mtime // empty' "${file}" 2>/dev/null || true)"
	if [ -n "${prev_count}" ] && [ -n "${prev_hash}" ] && [ -n "${prev_mtime}" ] && [ "${prev_count}" = "${count}" ] && [ "${prev_hash}" = "${hash}" ] && [ "${prev_mtime}" = "${mtime}" ]; then
		return 0
	fi
	return 1
}

mcp_registry_fastpath_store() {
	local kind="$1"
	local snapshot="$2"
	if [ "${MCPBASH_JSON_TOOL:-}" = "none" ] || [ -z "${MCPBASH_JSON_TOOL_BIN:-}" ]; then
		return 0
	fi
	local file
	if ! file="$(mcp_registry_fastpath_file)"; then
		return 0
	fi
	local count hash mtime
	IFS='|' read -r count hash mtime <<<"${snapshot}"
	[ -n "${count}" ] || count="0"
	[ -n "${hash}" ] || hash="0"
	[ -n "${mtime}" ] || mtime="0"
	local existing="{}"
	if [ -f "${file}" ]; then
		existing="$(cat "${file}")"
	fi
	local tmp
	tmp="$(mktemp "${MCPBASH_TMP_ROOT}/mcp-registry-fastpath.XXXXXX")"
	printf '%s' "${existing}" | "${MCPBASH_JSON_TOOL_BIN}" -c --arg kind "${kind}" --argjson count "${count}" --arg hash "${hash}" --argjson mtime "${mtime}" '
		.[$kind] = {count: $count, hash: $hash, mtime: $mtime}
	' >"${tmp}"
	mv "${tmp}" "${file}"
}

mcp_registry_write_with_lock() {
	local path="$1"
	local json_payload="$2"
	local lock_name="${3:-registry.refresh}"
	local timeout="${4:-5}"
	if ! mcp_lock_acquire_timeout "${lock_name}" "${timeout}"; then
		printf '%s\n' "mcp-bash: registry lock '${lock_name}' unavailable after ${timeout}s" >&2
		return 2
	fi
	printf '%s' "${json_payload}" >"${path}"
	mcp_lock_release "${lock_name}"
	return 0
}
