#!/usr/bin/env bash
# Tool runtime SDK helpers.
# Expects `MCPBASH_JSON_TOOL`/`MCPBASH_JSON_TOOL_BIN` and `MCPBASH_MODE` to be
# injected by the server. When running with `MCPBASH_TOOL_ENV_MODE=minimal` or
# without a JSON tool, JSON-centric helpers fall back to no-ops where possible.

set -euo pipefail

MCP_TOOL_CANCELLATION_FILE="${MCP_CANCEL_FILE:-}"
MCP_PROGRESS_STREAM="${MCP_PROGRESS_STREAM:-}"
MCP_LOG_STREAM="${MCP_LOG_STREAM:-}"
MCP_PROGRESS_TOKEN="${MCP_PROGRESS_TOKEN:-}"

__mcp_sdk_json_escape() {
	local value="$1"
	if command -v jq >/dev/null 2>&1; then
		jq -n --arg val "$value" '$val'
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

__mcp_sdk_payload_from_env() {
	local inline="$1"
	local file_path="$2"
	if [ -n "${file_path}" ] && [ -f "${file_path}" ]; then
		cat "${file_path}"
		return 0
	fi
	printf '%s' "${inline}"
}

mcp_args_raw() {
	__mcp_sdk_payload_from_env "${MCP_TOOL_ARGS_JSON:-"{}"}" "${MCP_TOOL_ARGS_FILE:-}"
}

# Extract a value from the arguments JSON using a jq filter (returns empty string if unavailable).
mcp_args_get() {
	local filter="$1"
	if [ "${MCPBASH_MODE:-full}" = "minimal" ]; then
		__mcp_sdk_warn "mcp_args_get: JSON tooling unavailable; use mcp_args_raw instead"
		printf ''
		return 1
	fi
	local payload
	payload="$(mcp_args_raw)"
	if command -v "${MCPBASH_JSON_TOOL_BIN:-}" >/dev/null 2>&1; then
		printf '%s' "${payload}" | "${MCPBASH_JSON_TOOL_BIN}" -c "${filter}" 2>/dev/null
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
	local total="${3:-}"
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
	local total_json="null"
	if [ -n "${total}" ]; then
		if printf '%s' "${total}" | LC_ALL=C grep -Eq '^[0-9]+$'; then
			total_json="${total}"
		fi
	fi
	printf '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":%s,"progress":%s,"total":%s,"message":%s}}\n' "${token_json}" "${percent}" "${total_json}" "${message_json}" >>"${MCP_PROGRESS_STREAM}" 2>/dev/null || true
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
	printf '{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"%s","logger":%s,"data":%s}}\n' "${normalized_level}" "${logger_json}" "${json_payload}" >>"${MCP_LOG_STREAM}" 2>/dev/null || true
}

mcp_log_debug() {
	mcp_log "debug" "$1" "$(__mcp_sdk_json_escape "$2")"
}

mcp_log_info() {
	mcp_log "info" "$1" "$(__mcp_sdk_json_escape "$2")"
}

mcp_log_warn() {
	mcp_log "warning" "$1" "$(__mcp_sdk_json_escape "$2")"
}

mcp_log_error() {
	mcp_log "error" "$1" "$(__mcp_sdk_json_escape "$2")"
}

mcp_fail() {
	local code="$1"
	local message="${2:-}"
	local data_raw="${3:-}"

	if ! printf '%s' "${code}" | LC_ALL=C grep -Eq '^[-+]?[0-9]+$'; then
		code="-32603"
	fi
	if [ -z "${message}" ]; then
		message="Tool failed"
	fi

	local message_json
	message_json="$(__mcp_sdk_json_escape "${message}")"

	local data_json="null"
	if [ -n "${data_raw}" ]; then
		if command -v "${MCPBASH_JSON_TOOL_BIN:-}" >/dev/null 2>&1; then
			local compact
			compact="$(printf '%s' "${data_raw}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.' 2>/dev/null || true)"
			[ -n "${compact}" ] && data_json="${compact}"
		else
			data_json="${data_raw}"
		fi
	fi

	if [ -n "${MCP_TOOL_ERROR_FILE:-}" ] && [ -w "${MCP_TOOL_ERROR_FILE}" ] 2>/dev/null; then
		printf '{"code":%s,"message":%s,"data":%s}\n' "${code}" "${message_json}" "${data_json}" >"${MCP_TOOL_ERROR_FILE}" 2>/dev/null || true
	fi
	printf '{"code":%s,"message":%s,"data":%s}\n' "${code}" "${message_json}" "${data_json}"
	printf '%s\n' "${message}" >&2
	exit 1
}

mcp_fail_invalid_args() {
	local message="${1:-Invalid params}"
	local data="${2:-}"
	mcp_fail -32602 "${message}" "${data}"
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
		esac
	fi
	printf '%s' "${json}"
}

# Roots helpers ---------------------------------------------------------------

mcp_roots_list() {
	printf '%s' "${MCP_ROOTS_PATHS:-}"
}

mcp_roots_count() {
	printf '%s' "${MCP_ROOTS_COUNT:-0}"
}

mcp_roots_contains() {
	local path="$1"
	local canonical

	if command -v realpath >/dev/null 2>&1; then
		canonical="$(realpath -m "${path}" 2>/dev/null)" || canonical="$(realpath "${path}" 2>/dev/null)" || canonical="${path}"
	else
		if [[ "${path}" != /* ]]; then
			canonical="$(cd "$(dirname "${path}")" 2>/dev/null && pwd)/$(basename "${path}")"
		else
			canonical="${path}"
		fi
	fi

	if [[ "${canonical}" != "/" ]]; then
		canonical="${canonical%/}"
	fi

	local root
	while IFS= read -r root; do
		[ -n "${root}" ] || continue
		if [[ "${canonical}" == "${root}" ]] || [[ "${canonical}" == "${root}/"* ]]; then
			return 0
		fi
	done <<<"${MCP_ROOTS_PATHS:-}"

	return 1
}

# Elicitation helpers ---------------------------------------------------------

MCP_ELICIT_DEFAULT_TIMEOUT="${MCPBASH_ELICITATION_TIMEOUT:-30}"

mcp_elicit() {
	local message="$1"
	local schema_json="$2"
	local timeout="${3:-${MCP_ELICIT_DEFAULT_TIMEOUT}}"

	if [ "${MCP_ELICIT_SUPPORTED:-0}" != "1" ]; then
		__mcp_sdk_warn "mcp_elicit: Client does not support elicitation"
		printf '{"action":"decline","content":null}'
		return 1
	fi

	if [ -z "${MCP_ELICIT_REQUEST_FILE:-}" ] || [ -z "${MCP_ELICIT_RESPONSE_FILE:-}" ]; then
		__mcp_sdk_warn "mcp_elicit: Elicitation environment not configured"
		printf '{"action":"error","content":null}'
		return 1
	fi

	rm -f "${MCP_ELICIT_RESPONSE_FILE}"

	local message_json
	message_json="$(__mcp_sdk_json_escape "${message}")"
	local tmp_request="${MCP_ELICIT_REQUEST_FILE}.tmp.$$"
	printf '{"message":%s,"schema":%s}' "${message_json}" "${schema_json}" >"${tmp_request}"
	mv "${tmp_request}" "${MCP_ELICIT_REQUEST_FILE}"

	local max_iterations=$((timeout * 10))
	local iterations=0
	while [ ! -f "${MCP_ELICIT_RESPONSE_FILE}" ] && [ "${iterations}" -lt "${max_iterations}" ]; do
		sleep 0.1
		iterations=$((iterations + 1))
		if mcp_is_cancelled; then
			rm -f "${MCP_ELICIT_REQUEST_FILE}"
			printf '{"action":"cancel","content":null}'
			return 1
		fi
	done

	if [ ! -f "${MCP_ELICIT_RESPONSE_FILE}" ]; then
		rm -f "${MCP_ELICIT_REQUEST_FILE}"
		__mcp_sdk_warn "mcp_elicit: Timeout waiting for user response"
		printf '{"action":"error","content":null}'
		return 1
	fi

	local response
	response="$(cat "${MCP_ELICIT_RESPONSE_FILE}")"
	rm -f "${MCP_ELICIT_RESPONSE_FILE}"
	printf '%s' "${response}"
}

mcp_elicit_string() {
	local message="$1"
	local field_name="${2:-value}"
	local schema
	schema="$(printf '{"type":"object","properties":{"%s":{"type":"string"}},"required":["%s"]}' "${field_name}" "${field_name}")"
	mcp_elicit "${message}" "${schema}"
}

mcp_elicit_confirm() {
	local message="$1"
	local schema='{"type":"object","properties":{"confirmed":{"type":"boolean"}},"required":["confirmed"]}'
	mcp_elicit "${message}" "${schema}"
}

mcp_elicit_choice() {
	local message="$1"
	shift
	local options=("$@")
	local enum_json
	enum_json="$(printf '%s\n' "${options[@]}" | jq -R . | jq -s -c .)"
	local schema
	schema="$(printf '{"type":"object","properties":{"choice":{"type":"string","enum":%s}},"required":["choice"]}' "${enum_json}")"
	mcp_elicit "${message}" "${schema}"
}
