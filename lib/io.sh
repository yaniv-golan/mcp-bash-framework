#!/usr/bin/env bash
# Stdout serialization, UTF-8 validation, and cancellation-aware emission.

set -euo pipefail

MCPBASH_STDOUT_LOCK_NAME="stdout"
MCPBASH_ICONV_AVAILABLE=""
MCPBASH_ALLOW_CORRUPT_STDOUT="${MCPBASH_ALLOW_CORRUPT_STDOUT:-false}"
MCP_IO_ACTIVE_KEY=""
MCP_IO_ACTIVE_CATEGORY=""

mcp_io_corruption_file() {
	if [ -z "${MCPBASH_STATE_DIR:-}" ]; then
		printf ''
		return 1
	fi
	printf '%s/corruption.log' "${MCPBASH_STATE_DIR}"
}

mcp_io_corruption_count() {
	local file
	file="$(mcp_io_corruption_file || true)"
	if [ -z "${file}" ] || [ ! -f "${file}" ]; then
		printf '0'
		return 0
	fi
	awk 'NF {count++} END {print count+0}' "${file}"
}

mcp_io_log_corruption_summary() {
	local file count window threshold
	file="$(mcp_io_corruption_file || true)"
	if [ -z "${file}" ] || [ ! -f "${file}" ]; then
		return 0
	fi
	count="$(mcp_io_corruption_count)"
	if [ "${count}" -eq 0 ]; then
		return 0
	fi
	window="${MCPBASH_CORRUPTION_WINDOW:-60}"
	threshold="${MCPBASH_CORRUPTION_THRESHOLD:-3}"
	printf '%s\n' "mcp-bash corruption summary: ${count} event(s) recorded within the last ${window}s (threshold ${threshold}, allow override ${MCPBASH_ALLOW_CORRUPT_STDOUT})." >&2
	return 0
}

mcp_io_read_file_exact() {
	local path="$1"
	local marker=$'\037MCPBASH_EOF\037'
	local data
	if [ -z "${path}" ] || [ ! -f "${path}" ]; then
		printf '%s' ''
		return 0
	fi
	if ! data="$(
		cat "${path}" 2>/dev/null
		printf '%s' "${marker}"
	)"; then
		return 1
	fi
	printf '%s' "${data%"${marker}"}"
}

mcp_io_handle_corruption() {
	local reason="$1"
	local key="${2:-}"
	local category="${3:-}"
	local payload="${4:-}"
	local allow="${MCPBASH_ALLOW_CORRUPT_STDOUT:-false}"
	local threshold="${MCPBASH_CORRUPTION_THRESHOLD:-3}"
	local window="${MCPBASH_CORRUPTION_WINDOW:-60}"
	local file
	local preserved=""
	local count=0
	local now line
	local lock_name

	file="$(mcp_io_corruption_file || true)"
	if [ -z "${file}" ]; then
		return 0
	fi
	lock_name="corruption"
	mcp_lock_acquire "${lock_name}"

	case "${threshold}" in
	'' | *[!0-9]*) threshold=3 ;;
	0) threshold=3 ;;
	esac
	case "${window}" in
	'' | *[!0-9]*) window=60 ;;
	esac

	now="$(date +%s)"
	if [ -f "${file}" ]; then
		while IFS= read -r line; do
			[ -z "${line}" ] && continue
			if [ $((now - line)) -lt "${window}" ]; then
				preserved="${preserved}${line}\n"
				count=$((count + 1))
			fi
		done <"${file}"
	fi

	printf '%s\n' "mcp-bash: stdout corruption detected (${reason}); ${count} prior event(s) in the last ${window}s" >&2
	if [ -n "${MCPBASH_STATE_DIR:-}" ]; then
		local snippet="${payload//$'\r'/\\r}"
		snippet="${snippet//$'\n'/\\n}"
		if [ ${#snippet} -gt 256 ]; then
			snippet="${snippet:0:256}..."
		fi
		printf '%s|%s|%s|%s|%s\n' "${now}" "${reason}" "${key:-"-"}" "${category:-"-"}" "${snippet}" >>"${MCPBASH_STATE_DIR}/stdout_corruption.log"
	fi

	printf '%s%s\n' "${preserved}" "${now}" >"${file}"

	if [ "${allow}" = "true" ]; then
		mcp_lock_release "${lock_name}"
		return 0
	fi

	if [ $((count + 1)) -ge "${threshold}" ]; then
		printf '%s\n' 'mcp-bash: exiting due to repeated stdout corruption.' >&2
		mcp_lock_release "${lock_name}"
		exit 2
	fi

	mcp_lock_release "${lock_name}"
	return 0
}

mcp_io_init() {
	mcp_lock_init
}

mcp_io_stdout_lock_acquire() {
	mcp_lock_acquire "${MCPBASH_STDOUT_LOCK_NAME}"
}

mcp_io_stdout_lock_release() {
	mcp_lock_release "${MCPBASH_STDOUT_LOCK_NAME}"
}

mcp_io_debug_enabled() {
	[ "${MCPBASH_DEBUG_PAYLOADS:-}" = "true" ] && [ -n "${MCPBASH_STATE_DIR:-}" ]
}

mcp_io_debug_log() {
	local category="$1"
	local key="$2"
	local status="$3"
	local payload="$4"

	if ! mcp_io_debug_enabled; then
		return 0
	fi

	local path="${MCPBASH_STATE_DIR}/payload.debug.log"
	mkdir -p "$(dirname "${path}")" 2>/dev/null || true
	local sanitized="${payload//$'\r'/\\r}"
	sanitized="${sanitized//$'\n'/\\n}"
	printf '%s|%s|%s|%s|%s\n' "$(date +%s)" "${category:-rpc}" "${key:-"-"}" "${status:-unknown}" "${sanitized}" >>"${path}"
}

mcp_io_send_line() {
	local payload="$1"
	if [ -z "${payload}" ]; then
		mcp_io_debug_log "rpc" "-" "empty" ""
		return 0
	fi
	local status="ok"
	local category="rpc"
	local prev_key="${MCP_IO_ACTIVE_KEY}"
	local prev_category="${MCP_IO_ACTIVE_CATEGORY}"
	MCP_IO_ACTIVE_KEY="-"
	MCP_IO_ACTIVE_CATEGORY="${category}"
	mcp_io_stdout_lock_acquire
	if ! mcp_io_write_payload "${payload}"; then
		status="error"
		mcp_io_stdout_lock_release
		MCP_IO_ACTIVE_KEY="${prev_key}"
		MCP_IO_ACTIVE_CATEGORY="${prev_category}"
		mcp_io_debug_log "rpc" "-" "${status}" "${payload}"
		return 1
	fi
	mcp_io_stdout_lock_release
	MCP_IO_ACTIVE_KEY="${prev_key}"
	MCP_IO_ACTIVE_CATEGORY="${prev_category}"
	mcp_io_debug_log "rpc" "-" "${status}" "${payload}"
	return 0
}

mcp_io_send_response() {
	local key="$1"
	local payload="$2"

	if [ -z "${payload}" ]; then
		mcp_io_debug_log "response" "${key}" "empty" ""
		return 0
	fi

	# Suppress responses for cancelled requests
	if [ -n "${key}" ] && [ "${key}" != "-" ] && mcp_ids_is_cancelled_key "${key}" 2>/dev/null; then
		mcp_io_debug_log "response" "${key}" "cancelled" "${payload}"
		return 0
	fi

	local prev_key="${MCP_IO_ACTIVE_KEY}"
	local prev_category="${MCP_IO_ACTIVE_CATEGORY}"
	MCP_IO_ACTIVE_KEY="${key:-"-"}"
	MCP_IO_ACTIVE_CATEGORY="response"
	mcp_io_stdout_lock_acquire
	if ! mcp_io_write_payload "${payload}"; then
		mcp_io_stdout_lock_release
		MCP_IO_ACTIVE_KEY="${prev_key}"
		MCP_IO_ACTIVE_CATEGORY="${prev_category}"
		mcp_io_debug_log "response" "${key}" "error" "${payload}"
		return 1
	fi

	mcp_io_stdout_lock_release
	MCP_IO_ACTIVE_KEY="${prev_key}"
	MCP_IO_ACTIVE_CATEGORY="${prev_category}"
	mcp_io_debug_log "response" "${key}" "ok" "${payload}"
	return 0
}

mcp_io_write_payload() {
	local payload="$1"
	local normalized
	local key="${MCP_IO_ACTIVE_KEY:-"-"}"
	local category="${MCP_IO_ACTIVE_CATEGORY:-"-"}"

	normalized="$(printf '%s' "${payload}" | tr -d '\r')"

	case "${normalized}" in
	*$'\n'*)
		mcp_io_handle_corruption "multi-line payload" "${key}" "${category}" "${normalized}"
		return 1
		;;
	esac

	if ! mcp_io_validate_utf8 "${normalized}"; then
		printf '%s\n' 'mcp-bash: dropping non-UTF8 payload to preserve stdout contract.' >&2
		mcp_io_handle_corruption "invalid UTF-8" "${key}" "${category}" "${normalized}"
		return 1
	fi

	if ! printf '%s\n' "${normalized}"; then
		mcp_io_handle_corruption "stdout write failure" "${key}" "${category}" "${normalized}"
		return 1
	fi
	return 0
}

mcp_io_validate_utf8() {
	local data="$1"

	if [ -z "${data}" ]; then
		return 0
	fi

	if [ -z "${MCPBASH_ICONV_AVAILABLE}" ]; then
		if command -v iconv >/dev/null 2>&1; then
			MCPBASH_ICONV_AVAILABLE="true"
		else
			MCPBASH_ICONV_AVAILABLE="false"
		fi
	fi

	if [ "${MCPBASH_ICONV_AVAILABLE}" = "false" ]; then
		return 0
	fi

	printf '%s' "${data}" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1
}
