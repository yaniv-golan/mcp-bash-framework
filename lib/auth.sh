#!/usr/bin/env bash
# Remote authentication guard for proxied deployments.

set -euo pipefail

: "${MCPBASH_REMOTE_TOKEN_EXPECTED:=}"
: "${MCPBASH_REMOTE_TOKEN_KEY:=}"
: "${MCPBASH_REMOTE_TOKEN_FALLBACK_KEY:=}"
: "${MCPBASH_REMOTE_TOKEN_ENABLED:=false}"

mcp_auth_init() {
	local token="${MCPBASH_REMOTE_TOKEN:-}"
	local key="${MCPBASH_REMOTE_TOKEN_KEY:-mcpbash/remoteToken}"
	local fallback="${MCPBASH_REMOTE_TOKEN_FALLBACK_KEY:-remoteToken}"

	if [ -z "${token}" ]; then
		MCPBASH_REMOTE_TOKEN_ENABLED=false
		return 0
	fi

	if [ "${MCPBASH_JSON_TOOL:-none}" = "none" ] || [ -z "${MCPBASH_JSON_TOOL_BIN:-}" ]; then
		printf '%s\n' "mcp-bash: MCPBASH_REMOTE_TOKEN is set but JSON tooling is unavailable; cannot enforce remote token guard." >&2
		return 1
	fi

	if [ -z "${key}" ]; then
		key="mcpbash/remoteToken"
	fi

	MCPBASH_REMOTE_TOKEN_EXPECTED="${token}"
	MCPBASH_REMOTE_TOKEN_KEY="${key}"
	MCPBASH_REMOTE_TOKEN_FALLBACK_KEY="${fallback}"
	MCPBASH_REMOTE_TOKEN_ENABLED=true

	if [ "${#token}" -lt 32 ] && mcp_runtime_log_allowed; then
		printf '%s\n' "mcp-bash: MCPBASH_REMOTE_TOKEN appears short (<256 bits); use 'openssl rand -base64 32' for stronger entropy." >&2
	fi

	return 0
}

mcp_auth_is_enabled() {
	[ "${MCPBASH_REMOTE_TOKEN_ENABLED:-false}" = "true" ]
}

mcp_auth_constant_time_equals() {
	local expected="$1"
	local provided="$2"
	local expected_len=${#expected}
	local provided_len=${#provided}
	local diff=$((expected_len ^ provided_len))
	local max_len="${expected_len}"
	local i=0

	if [ "${provided_len}" -gt "${max_len}" ]; then
		max_len="${provided_len}"
	fi

	while [ "${i}" -lt "${max_len}" ]; do
		local e=0 p=0
		if [ "${i}" -lt "${expected_len}" ]; then
			LC_ALL=C printf -v e '%d' "'${expected:i:1}"
		fi
		if [ "${i}" -lt "${provided_len}" ]; then
			LC_ALL=C printf -v p '%d' "'${provided:i:1}"
		fi
		diff=$((diff | (e ^ p)))
		i=$((i + 1))
	done

	[ "${diff}" -eq 0 ]
}

mcp_auth_extract_remote_token() {
	local json_line="$1"
	local key="${MCPBASH_REMOTE_TOKEN_KEY:-mcpbash/remoteToken}"
	local fallback="${MCPBASH_REMOTE_TOKEN_FALLBACK_KEY:-remoteToken}"
	local value=""

	value="$(
		{ printf '%s' "${json_line}" | "${MCPBASH_JSON_TOOL_BIN}" -r --arg key "${key}" --arg fallback "${fallback}" '
			def grab($k): ((.params._meta // {})[$k]? // empty | strings);
			(grab($key) // (if $fallback != "" then grab($fallback) else "" end))
		'; } 2>/dev/null
	)"

	printf '%s' "${value}"
}

mcp_auth_emit_error() {
	local id_json="$1"
	local message="$2"

	# Notifications must not receive responses; skip when id is absent.
	case "${id_json}" in
	null | '') return 0 ;;
	esac

	rpc_send_line "$(mcp_core_build_error_response "${id_json}" -32602 "${message}" "")"
}

mcp_auth_guard_request() {
	local json_line="$1"
	local method="$2"
	local id_json="$3"

	if ! mcp_auth_is_enabled; then
		return 0
	fi

	local presented
	presented="$(mcp_auth_extract_remote_token "${json_line}")"

	if [ -z "${presented}" ] || ! mcp_auth_constant_time_equals "${MCPBASH_REMOTE_TOKEN_EXPECTED}" "${presented}"; then
		if mcp_logging_is_enabled "warning"; then
			mcp_logging_warning "mcp.auth" "Remote token rejected method=${method}"
		fi
		mcp_auth_emit_error "${id_json:-null}" "Remote token missing or invalid"
		return 1
	fi

	return 0
}
