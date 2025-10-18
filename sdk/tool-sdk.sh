#!/usr/bin/env bash
# Spec §10 tool runtime SDK helpers.

set -euo pipefail

MCP_TOOL_CANCELLATION_FILE="${MCP_CANCEL_FILE:-}"
MCP_PROGRESS_STREAM="${MCP_PROGRESS_STREAM:-}"
MCP_LOG_STREAM="${MCP_LOG_STREAM:-}"
MCP_PROGRESS_TOKEN="${MCP_PROGRESS_TOKEN:-}"

__mcp_sdk_json_escape() {
	local value="$1"
	if command -v python3 >/dev/null 2>&1; then
		python3 - "$value" <<'PY' 2>/dev/null
import json, sys
print(json.dumps(sys.argv[1]))
PY
		return 0
	fi
	if command -v python >/dev/null 2>&1; then
		python - "$value" <<'PY' 2>/dev/null
import json, sys
print(json.dumps(sys.argv[1]))
PY
		return 0
	fi
	local escaped="${value//\\/\\\\}"
	escaped="${escaped//\"/\\\"}"
	escaped="${escaped//$'\n'/\\n}"
	escaped="${escaped//$'\r'/\\r}"
	printf '"%s"' "${escaped}"
}

__mcp_sdk_warn() {
	printf '%s\n' "$1" >&2
}

mcp_args_raw() {
	printf '%s' "${MCP_TOOL_ARGS_JSON:-{}}"
}

mcp_args_get() {
	local filter="$1"
	if [ "${MCPBASH_MODE:-full}" = "minimal" ]; then
		__mcp_sdk_warn "mcp_args_get: JSON tooling unavailable; use mcp_args_raw instead"
		printf ''
		return 1
	fi
	if command -v "${MCPBASH_JSON_TOOL_BIN:-}" >/dev/null 2>&1; then
		printf '%s' "${MCP_TOOL_ARGS_JSON:-{}}" | "${MCPBASH_JSON_TOOL_BIN}" -c "${filter}" 2>/dev/null
	else
		__mcp_sdk_warn "mcp_args_get: JSON tooling unavailable; use mcp_args_raw instead"
		printf ''
		return 1
	fi
}

mcp_is_cancelled() {
	if [ -z "${MCP_TOOL_CANCELLATION_FILE}" ]; then
		return 1
	fi
	if [ -f "${MCP_TOOL_CANCELLATION_FILE}" ]; then
		return 0
	fi
	return 1
}

mcp_progress() {
	local percent="$1"
	local message="$2"
	if [ -z "${MCP_PROGRESS_TOKEN}" ] || [ -z "${MCP_PROGRESS_STREAM}" ]; then
		return 0
	fi
	case "${percent}" in
	'' | *[!0-9]*) percent="0" ;;
	*)
		if [ "${percent}" -lt 0 ]; then
			percent=0
		elif [ "${percent}" -gt 100 ]; then
			percent=100
		fi
		;;
	esac
	local token_json message_json
	if printf '%s' "${MCP_PROGRESS_TOKEN}" | LC_ALL=C grep -Eq '^[-+]?[0-9]+(\.[0-9]+)?$'; then
		token_json="${MCP_PROGRESS_TOKEN}"
	else
		token_json="$(__mcp_sdk_json_escape "${MCP_PROGRESS_TOKEN}")"
	fi
	message_json="$(__mcp_sdk_json_escape "${message}")"
	printf '{"jsonrpc":"2.0","method":"notifications/progress","params":{"token":%s,"percent":%s,"message":%s}}\n' "${token_json}" "${percent}" "${message_json}" >>"${MCP_PROGRESS_STREAM}" 2>/dev/null || true
}

mcp_log() {
	local level="$1"
	local logger="$2"
	local json_payload="$3"
	local normalized_level
	normalized_level="$(printf '%s' "${level}" | tr '[:upper:]' '[:lower:]')"
	case " ${normalized_level} " in
	" debug " | " info " | " notice " | " warning " | " error " | " critical " | " alert " | " emergency ") ;;
	*)
		__mcp_sdk_warn "mcp_log: invalid level '${level}', defaulting to 'info'"
		normalized_level="info"
		;;
	esac
	if [ -z "${MCP_LOG_STREAM}" ]; then
		return 0
	fi
	local logger_json
	logger_json="$(__mcp_sdk_json_escape "${logger}")"
	printf '{"jsonrpc":"2.0","method":"notifications/log","params":{"level":"%s","logger":%s,"message":%s}}\n' "${normalized_level}" "${logger_json}" "${json_payload}" >>"${MCP_LOG_STREAM}" 2>/dev/null || true
}

mcp_emit_text() {
	local text="$1"
	printf '%s' "${text}"
}

mcp_emit_json() {
	local json="$1"
	if [ "${MCPBASH_MODE:-full}" != "minimal" ] && [ -n "${MCPBASH_JSON_TOOL_BIN:-}" ]; then
		case "${MCPBASH_JSON_TOOL}" in
		gojq | jq)
			local compact_json
			compact_json="$(printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.' 2>/dev/null || true)"
			if [ -n "${compact_json}" ]; then
				printf '%s' "${compact_json}"
				return 0
			fi
			;;
		python)
			local compact_py
			compact_py="$(printf '%s' "${json}" | "${MCPBASH_JSON_TOOL_BIN}" -c "import json, sys; obj = json.load(sys.stdin); print(json.dumps(obj, separators=(',', ':')))" 2>/dev/null || true)"
			if [ -n "${compact_py}" ]; then
				printf '%s' "${compact_py}"
				return 0
			fi
			;;
		esac
	fi
	printf '%s' "${json}"
}
