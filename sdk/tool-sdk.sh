#!/usr/bin/env bash
# Tool runtime SDK helpers.
# Expects `MCPBASH_JSON_TOOL`/`MCPBASH_JSON_TOOL_BIN` and `MCPBASH_MODE` to be
# injected by the server. When running with `MCPBASH_TOOL_ENV_MODE=minimal` or
# without a JSON tool, JSON-centric helpers fall back to no-ops where possible.
#
# Auto-loaded helpers:
#   - lib/path.sh: Path normalization (mcp_path_normalize)
#   - lib/progress-passthrough.sh: Subprocess progress forwarding (mcp_run_with_progress)

set -euo pipefail

MCP_TOOL_CANCELLATION_FILE="${MCP_CANCEL_FILE:-}"
MCP_PROGRESS_STREAM="${MCP_PROGRESS_STREAM:-}"
MCP_LOG_STREAM="${MCP_LOG_STREAM:-}"
MCP_PROGRESS_TOKEN="${MCP_PROGRESS_TOKEN:-}"

mcp_sdk_load_path_helpers() {
	if declare -F mcp_path_normalize >/dev/null 2>&1; then
		return 0
	fi
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local helper="${script_dir}/../lib/path.sh"
	if [ -f "${helper}" ]; then
		# shellcheck disable=SC1090
		. "${helper}"
	fi
}

mcp_sdk_load_path_helpers

__mcp_sdk_load_progress_passthrough() {
	if declare -F mcp_run_with_progress >/dev/null 2>&1; then
		return 0
	fi
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local helper="${script_dir}/../lib/progress-passthrough.sh"
	if [ -f "${helper}" ]; then
		# shellcheck disable=SC1090
		. "${helper}"
	fi
}

__mcp_sdk_load_progress_passthrough

__mcp_sdk_load_ui_helpers() {
	# Load UI SDK helpers for MCP Apps support (SEP-1865)
	if declare -F mcp_client_supports_ui >/dev/null 2>&1; then
		return 0
	fi
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local helper="${script_dir}/ui-sdk.sh"
	if [ -f "${helper}" ]; then
		# shellcheck disable=SC1090
		. "${helper}"
	fi
}

__mcp_sdk_load_ui_helpers

__mcp_sdk_json_escape() {
	# Return a quoted JSON string literal for the given value.
	# Prefer the framework-selected JSON tool, then fall back to jq, then a
	# best-effort manual escape (ASCII control chars + quotes + backslashes).
	local value="${1-}"

	if [ -n "${MCPBASH_JSON_TOOL_BIN:-}" ] && command -v "${MCPBASH_JSON_TOOL_BIN}" >/dev/null 2>&1; then
		"${MCPBASH_JSON_TOOL_BIN}" -n --arg val "${value}" '$val'
		return 0
	fi

	if command -v jq >/dev/null 2>&1; then
		jq -n --arg val "${value}" '$val'
		return 0
	fi

	# Fallback: handle core escapes; non-ASCII is passed through assuming UTF-8.
	local escaped="${value//\\/\\\\}"
	escaped="${escaped//\"/\\\"}"
	escaped="${escaped//$'\n'/\\n}"
	escaped="${escaped//$'\r'/\\r}"
	escaped="${escaped//$'\t'/\\t}"
	printf '"%s"' "${escaped}"
}

__mcp_sdk_warn() {
	printf '%s\n' "$1" >&2
}

# Public JSON helpers --------------------------------------------------------
#
# These helpers are intentionally simple and treat all values as strings.
# They are designed for use from short-lived tool scripts; misuse (e.g., odd
# argument count) is a programming error and terminates the process.

mcp_json_escape() {
	# Escape a string for JSON; returns a quoted string literal.
	__mcp_sdk_json_escape "${1-}"
}

mcp_json_obj() {
	# Build a JSON object from key/value pairs. All keys and values are treated
	# as strings and JSON-escaped. Odd argument counts are fatal.
	if [ $(($# % 2)) -ne 0 ]; then
		__mcp_sdk_warn "mcp_json_obj: expected even number of arguments (key value ...), got $#"
		# Exit rather than return so that misuse inside $(...) is not silently ignored.
		exit 1
	fi

	local json="{"
	local sep=""
	local key value key_json value_json

	while [ "$#" -gt 0 ]; do
		key="$1"
		value="$2"
		shift 2
		key_json="$(__mcp_sdk_json_escape "${key}")"
		value_json="$(__mcp_sdk_json_escape "${value}")"
		json="${json}${sep}${key_json}:${value_json}"
		sep=","
	done

	json="${json}}"
	printf '%s' "${json}"
}

mcp_json_arr() {
	# Build a JSON array from values. All values are treated as strings and
	# JSON-escaped.
	local json="["
	local sep=""
	local value value_json

	while [ "$#" -gt 0 ]; do
		value="$1"
		shift
		value_json="$(__mcp_sdk_json_escape "${value}")"
		json="${json}${sep}${value_json}"
		sep=","
	done

	json="${json}]"
	printf '%s' "${json}"
}

__mcp_sdk_payload_from_env() {
	local inline="$1"
	local file_path="$2"
	# SECURITY: When xtrace is enabled (bash -x / set -x), avoid expanding
	# secret-bearing JSON payloads as command arguments in trace output.
	local _mcp_xtrace_was_on=false
	case $- in
	*x*)
		_mcp_xtrace_was_on=true
		set +x
		;;
	esac

	if [ -n "${file_path}" ] && [ -f "${file_path}" ]; then
		cat "${file_path}"
	else
		printf '%s' "${inline}"
	fi

	if [ "${_mcp_xtrace_was_on}" = true ]; then
		set -x
	fi
}

__mcp_sdk_payload_from_env_vars() {
	# SECURITY: Avoid passing secret-bearing payloads as function arguments when
	# xtrace is enabled. Accept variable names and perform indirection with xtrace
	# suspended so bash -x does not print full payloads into trace logs.
	local inline_var="$1"
	local file_var="$2"
	local default_value="${3:-}"

	local _mcp_xtrace_was_on=false
	case $- in
	*x*)
		_mcp_xtrace_was_on=true
		set +x
		;;
	esac

	local file_path=""
	if [ -n "${file_var}" ]; then
		file_path="${!file_var:-}"
	fi
	if [ -n "${file_path}" ] && [ -f "${file_path}" ]; then
		cat "${file_path}"
	else
		local inline="${default_value}"
		if [ -n "${inline_var}" ]; then
			inline="${!inline_var:-${default_value}}"
		fi
		printf '%s' "${inline}"
	fi

	if [ "${_mcp_xtrace_was_on}" = true ]; then
		set -x
	fi
}

mcp_args_raw() {
	__mcp_sdk_payload_from_env_vars MCP_TOOL_ARGS_JSON MCP_TOOL_ARGS_FILE "{}"
}

# Request metadata helpers -----------------------------------------------------
#
# The _meta object from tools/call requests provides client-controlled metadata
# that is not exposed to the LLM. Common use cases: passing auth context, rate
# limiting identifiers, or behavior flags that should not be LLM-generated.

mcp_meta_raw() {
	# Return the raw _meta JSON from the tools/call request.
	__mcp_sdk_payload_from_env_vars MCP_TOOL_META_JSON MCP_TOOL_META_FILE "{}"
}

mcp_meta_get() {
	# Extract a value from the request _meta JSON using a jq filter.
	local filter="$1"
	if [ "${MCPBASH_MODE:-full}" = "minimal" ]; then
		__mcp_sdk_warn "mcp_meta_get: JSON tooling unavailable; use mcp_meta_raw instead"
		printf ''
		return 1
	fi
	local _mcp_xtrace_was_on=false
	case $- in
	*x*)
		_mcp_xtrace_was_on=true
		set +x
		;;
	esac

	local payload
	payload="$(mcp_meta_raw)"
	local rc=0
	if command -v "${MCPBASH_JSON_TOOL_BIN:-}" >/dev/null 2>&1; then
		printf '%s' "${payload}" | "${MCPBASH_JSON_TOOL_BIN}" -rc "${filter}" 2>/dev/null || rc=$?
	else
		__mcp_sdk_warn "mcp_meta_get: JSON tooling unavailable; use mcp_meta_raw instead"
		printf ''
		rc=1
	fi

	if [ "${_mcp_xtrace_was_on}" = true ]; then
		set -x
	fi
	return "${rc}"
}

# Extract a value from the arguments JSON using a jq filter (returns empty string if unavailable).
mcp_args_get() {
	local filter="$1"
	if [ "${MCPBASH_MODE:-full}" = "minimal" ]; then
		__mcp_sdk_warn "mcp_args_get: JSON tooling unavailable; use mcp_args_raw instead"
		printf ''
		return 1
	fi
	local _mcp_xtrace_was_on=false
	case $- in
	*x*)
		_mcp_xtrace_was_on=true
		set +x
		;;
	esac

	local payload
	payload="$(mcp_args_raw)"
	local rc=0
	local result=""
	if command -v "${MCPBASH_JSON_TOOL_BIN:-}" >/dev/null 2>&1; then
		result="$(printf '%s' "${payload}" | "${MCPBASH_JSON_TOOL_BIN}" -rc "${filter}" 2>/dev/null)" || rc=$?
		if [ "${rc}" -ne 0 ]; then
			# Log parse error for debugging (stderr goes to server log, not tool output)
			__mcp_sdk_warn "mcp_args_get: jq error (rc=${rc}) filter=${filter} payload_len=${#payload}"
			result=""
		fi
		printf '%s' "${result}"
	else
		__mcp_sdk_warn "mcp_args_get: JSON tooling unavailable; use mcp_args_raw instead"
		printf ''
		rc=1
	fi

	if [ "${_mcp_xtrace_was_on}" = true ]; then
		set -x
	fi
	return "${rc}"
}

mcp_args_require() {
	local pointer="$1"
	local message="${2:-}"
	local raw
	raw="$(mcp_args_get "${pointer}" 2>/dev/null || true)"
	if [ -z "${raw}" ] || [ "${raw}" = "null" ]; then
		if [ -z "${message}" ]; then
			message="${pointer} is required"
		fi
		mcp_fail_invalid_args "${message}"
	fi
	printf '%s' "${raw}"
}

mcp_args_bool() {
	local pointer="$1"
	shift || true
	local default_set="false"
	local default_value="false"
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--default)
			default_set="true"
			default_value="$2"
			shift
			;;
		*) break ;;
		esac
		shift
	done

	local raw
	raw="$(mcp_args_get "${pointer}" 2>/dev/null || true)"
	if [ -z "${raw}" ] || [ "${raw}" = "null" ]; then
		if [ "${default_set}" = "true" ]; then
			case "${default_value}" in
			true | 1)
				printf 'true'
				return 0
				;;
			*)
				printf 'false'
				return 0
				;;
			esac
		fi
		if [ "${MCPBASH_MODE:-full}" = "minimal" ]; then
			mcp_fail_invalid_args "${pointer} requires JSON tooling or a default"
		else
			mcp_fail_invalid_args "${pointer} is required"
		fi
	fi

	case "${raw}" in
	true | 1) printf 'true' ;;
	*) printf 'false' ;;
	esac
}

mcp_args_int() {
	local pointer="$1"
	shift || true
	# Integer comparisons rely on bash arithmetic (64-bit signed); extremely large values are not supported.
	local default_set="false"
	local default_value=""
	local min_set="false"
	local max_set="false"
	local min_value=""
	local max_value=""

	while [ "$#" -gt 0 ]; do
		case "$1" in
		--default)
			default_set="true"
			default_value="$2"
			shift
			;;
		--min)
			min_set="true"
			min_value="$2"
			shift
			;;
		--max)
			max_set="true"
			max_value="$2"
			shift
			;;
		*) break ;;
		esac
		shift
	done

	if [ "${min_set}" = "true" ] && [ "${max_set}" = "true" ]; then
		if ! [ "${min_value}" -le "${max_value}" ] 2>/dev/null; then
			mcp_fail_invalid_args "mcp_args_int: --min cannot exceed --max"
		fi
	fi

	local raw
	raw="$(mcp_args_get "${pointer}" 2>/dev/null || true)"
	if [ -z "${raw}" ] || [ "${raw}" = "null" ]; then
		if [ "${default_set}" = "true" ]; then
			raw="${default_value}"
		else
			if [ "${MCPBASH_MODE:-full}" = "minimal" ]; then
				mcp_fail_invalid_args "${pointer} requires JSON tooling or a default"
			else
				mcp_fail_invalid_args "${pointer} is required"
			fi
		fi
	fi

	if ! printf '%s' "${raw}" | LC_ALL=C grep -Eq '^-?[0-9]+$'; then
		mcp_fail_invalid_args "${pointer} must be an integer"
	fi

	if [ "${min_set}" = "true" ]; then
		if ! [ "${raw}" -ge "${min_value}" ] 2>/dev/null; then
			mcp_fail_invalid_args "${pointer} must be >= ${min_value}"
		fi
	fi
	if [ "${max_set}" = "true" ]; then
		if ! [ "${raw}" -le "${max_value}" ] 2>/dev/null; then
			mcp_fail_invalid_args "${pointer} must be <= ${max_value}"
		fi
	fi

	printf '%s' "${raw}"
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

mcp_debug() {
	if [[ -z "${MCPBASH_DEBUG_LOG:-}" ]]; then
		return 0
	fi
	local message="$*"
	local timestamp=""
	timestamp="$(date +%H:%M:%S 2>/dev/null || true)"
	if [ -z "${timestamp}" ]; then
		timestamp="??:??:??"
	fi
	printf '[%s] %s\n' "${timestamp}" "${message}" >>"${MCPBASH_DEBUG_LOG}" 2>/dev/null || true
}

# Retry helper ----------------------------------------------------------------
#
# mcp_with_retry <max_attempts> <base_delay> -- <command...>
# Retries command with exponential backoff + jitter.
# Exit codes 0, 1, 2 are not retried (success, error, invalid args).
# Exit codes 3+ are retried (transient failures).
#
# Example:
#   mcp_with_retry 3 1.0 -- curl -sf "https://api.example.com/data"
#   mcp_with_retry 5 0.5 -- my_cli get-entity "$id"

mcp_with_retry() {
	local max_attempts="$1"
	local base_delay="$2"
	shift 2
	[[ "$1" == "--" ]] && shift

	# Validate inputs
	if ! printf '%s' "${max_attempts}" | LC_ALL=C grep -Eq '^[0-9]+$'; then
		__mcp_sdk_warn "mcp_with_retry: max_attempts must be a positive integer"
		return 1
	fi
	if ! printf '%s' "${base_delay}" | LC_ALL=C grep -Eq '^[0-9]+\.?[0-9]*$'; then
		__mcp_sdk_warn "mcp_with_retry: base_delay must be a number"
		return 1
	fi

	local attempt=1
	local delay="${base_delay}"

	while true; do
		# errexit-safe: capture exit code without toggling shell state
		local exit_code=0
		"$@" && exit_code=0 || exit_code=$?

		# Success
		if [[ ${exit_code} -eq 0 ]]; then
			return 0
		fi

		# Don't retry permanent failures (exit codes 0-2)
		# 0 = success, 1 = general error, 2 = invalid args/usage
		if [[ ${exit_code} -le 2 ]]; then
			return ${exit_code}
		fi

		# Max attempts reached
		if [[ ${attempt} -ge ${max_attempts} ]]; then
			return ${exit_code}
		fi

		# Calculate jitter (0-50% of delay) and sleep
		local jitter sleep_time
		jitter=$(awk "BEGIN {srand(); print ${delay} * rand() * 0.5}")
		sleep_time=$(awk "BEGIN {print ${delay} + ${jitter}}")

		mcp_log_debug "retry" "Attempt ${attempt}/${max_attempts} failed (exit ${exit_code}), retrying in ${sleep_time}s"
		sleep "${sleep_time}"

		# Exponential backoff
		delay=$(awk "BEGIN {print ${delay} * 2}")
		attempt=$((attempt + 1))
	done
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
	canonical="$(mcp_path_normalize --physical "${path}")"

	local root
	while IFS= read -r root; do
		[ -n "${root}" ] || continue
		local root_canonical
		root_canonical="$(mcp_path_normalize --physical "${root}")"
		# SECURITY: do NOT use glob/pattern matching for containment checks.
		# Root paths may contain glob metacharacters like []?* which would turn a
		# prefix check into a wildcard match. Use literal string comparisons.
		if [ "${root_canonical}" != "/" ]; then
			root_canonical="${root_canonical%/}"
		fi
		if [ "${canonical}" = "${root_canonical}" ]; then
			return 0
		fi
		if [ "${root_canonical}" = "/" ]; then
			return 0
		fi
		local prefix="${root_canonical}/"
		if [ "${canonical:0:${#prefix}}" = "${prefix}" ]; then
			return 0
		fi
	done <<<"${MCP_ROOTS_PATHS:-}"

	return 1
}

mcp_require_path() {
	local pointer="${1-}"
	shift || true

	local default_single_root="false"
	local allow_empty="false"
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--default-to-single-root) default_single_root="true" ;;
		--allow-empty) allow_empty="true" ;;
		--)
			shift
			break
			;;
		*) break ;;
		esac
		shift
	done

	if [ -z "${pointer}" ]; then
		mcp_fail_invalid_args "mcp_require_path: argument pointer is required"
	fi

	local raw_value
	raw_value="$(mcp_args_get "${pointer}" 2>/dev/null || true)"
	if [ "${raw_value}" = "null" ]; then
		raw_value=""
	fi

	if [ -z "${raw_value}" ] && [ "${default_single_root}" = "true" ]; then
		local roots_count
		roots_count="$(mcp_roots_count 2>/dev/null || printf '0')"
		if [ "${roots_count}" -eq 1 ]; then
			raw_value="$(mcp_roots_list | head -n1)"
		else
			mcp_fail_invalid_args "${pointer} is required when zero or multiple roots are configured"
		fi
	fi

	if [ -z "${raw_value}" ]; then
		if [ "${allow_empty}" = "true" ]; then
			printf ''
			return 0
		fi
		mcp_fail_invalid_args "${pointer} is required"
	fi

	local normalized
	normalized="$(mcp_path_normalize --physical "${raw_value}")"

	local roots_count
	roots_count="$(mcp_roots_count 2>/dev/null || printf '0')"
	if [ "${roots_count}" -gt 0 ]; then
		if ! mcp_roots_contains "${normalized}"; then
			mcp_fail_invalid_args "${pointer} is outside configured MCP roots"
		fi
	fi

	printf '%s' "${normalized}"
}

# Elicitation helpers ---------------------------------------------------------
# SEP-1036: Supports form (in-band) and url (out-of-band) modes

MCP_ELICIT_DEFAULT_TIMEOUT="${MCPBASH_ELICITATION_TIMEOUT:-30}"

# Core elicitation function with mode support
# Usage: mcp_elicit <message> <schema_json> [timeout] [mode]
# mode: "form" (default) or "url"
mcp_elicit() {
	local message="$1"
	local schema_json="$2"
	local timeout="${3:-${MCP_ELICIT_DEFAULT_TIMEOUT}}"
	local mode="${4:-form}"

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
	# SEP-1036: Include mode in request
	printf '{"message":%s,"schema":%s,"mode":"%s"}' "${message_json}" "${schema_json}" "${mode}" >"${tmp_request}"
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

# SEP-1036: URL mode elicitation for secure out-of-band interactions
# Opens a browser URL for OAuth, payments, or sensitive data entry
# Usage: mcp_elicit_url <message> <url> [timeout]
# Returns: {"action":"accept|decline|cancel","content":null}
mcp_elicit_url() {
	local message="$1"
	local url="$2"
	local timeout="${3:-${MCP_ELICIT_DEFAULT_TIMEOUT}}"

	if [ "${MCP_ELICIT_SUPPORTED:-0}" != "1" ]; then
		__mcp_sdk_warn "mcp_elicit_url: Client does not support elicitation"
		printf '{"action":"decline","content":null}'
		return 1
	fi

	if [ -z "${MCP_ELICIT_REQUEST_FILE:-}" ] || [ -z "${MCP_ELICIT_RESPONSE_FILE:-}" ]; then
		__mcp_sdk_warn "mcp_elicit_url: Elicitation environment not configured"
		printf '{"action":"error","content":null}'
		return 1
	fi

	rm -f "${MCP_ELICIT_RESPONSE_FILE}"

	local message_json url_json
	message_json="$(__mcp_sdk_json_escape "${message}")"
	url_json="$(__mcp_sdk_json_escape "${url}")"
	local tmp_request="${MCP_ELICIT_REQUEST_FILE}.tmp.$$"
	# SEP-1036 URL mode: message + url, no schema
	printf '{"message":%s,"url":%s,"mode":"url"}' "${message_json}" "${url_json}" >"${tmp_request}"
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
		__mcp_sdk_warn "mcp_elicit_url: Timeout waiting for user response"
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
	local json_tool="${MCPBASH_JSON_TOOL_BIN:-jq}"
	local enum_json
	enum_json="$(printf '%s\n' "${options[@]}" | "${json_tool}" -R . | "${json_tool}" -s -c .)"
	local schema
	schema="$(printf '{"type":"object","properties":{"choice":{"type":"string","enum":%s}},"required":["choice"]}' "${enum_json}")"
	mcp_elicit "${message}" "${schema}"
}

# Titled choice: each option is "value:Display Title"
# Example: mcp_elicit_titled_choice "Pick quality" "high:High (1080p)" "low:Low (480p)"
# Returns: {"action":"accept","content":{"choice":"high"}}
mcp_elicit_titled_choice() {
	local message="$1"
	shift
	local options=("$@")
	local json_tool="${MCPBASH_JSON_TOOL_BIN:-jq}"

	# Build oneOf array: [{"const":"value","title":"Display Title"}, ...]
	local one_of_items=""
	local first=1
	for opt in "${options[@]}"; do
		local value="${opt%%:*}"
		local title="${opt#*:}"
		# If no colon, use value as title
		[[ "${value}" == "${opt}" ]] && title="${value}"

		local item
		item="$("${json_tool}" -n -c --arg v "${value}" --arg t "${title}" '{const:$v,title:$t}')"
		if [[ "${first}" -eq 1 ]]; then
			one_of_items="${item}"
			first=0
		else
			one_of_items="${one_of_items},${item}"
		fi
	done

	local schema
	schema="$(printf '{"type":"object","properties":{"choice":{"type":"string","oneOf":[%s]}},"required":["choice"]}' "${one_of_items}")"
	mcp_elicit "${message}" "${schema}"
}

# Multi-select choice: user can select multiple options (checkboxes)
# Example: mcp_elicit_multi_choice "Select codecs" "h264" "h265" "vp9"
# Returns: {"action":"accept","content":{"choices":["h264","vp9"]}}
mcp_elicit_multi_choice() {
	local message="$1"
	shift
	local options=("$@")
	local json_tool="${MCPBASH_JSON_TOOL_BIN:-jq}"
	local enum_json
	enum_json="$(printf '%s\n' "${options[@]}" | "${json_tool}" -R . | "${json_tool}" -s -c .)"
	local schema
	schema="$(printf '{"type":"object","properties":{"choices":{"type":"array","items":{"type":"string","enum":%s}}},"required":["choices"]}' "${enum_json}")"
	mcp_elicit "${message}" "${schema}"
}

# Multi-select with titles: each option is "value:Display Title"
# Example: mcp_elicit_titled_multi_choice "Select outputs" "mp4:MP4 Video" "mp3:MP3 Audio"
# Returns: {"action":"accept","content":{"choices":["mp4","mp3"]}}
mcp_elicit_titled_multi_choice() {
	local message="$1"
	shift
	local options=("$@")
	local json_tool="${MCPBASH_JSON_TOOL_BIN:-jq}"

	# Build oneOf array for items
	local one_of_items=""
	local first=1
	for opt in "${options[@]}"; do
		local value="${opt%%:*}"
		local title="${opt#*:}"
		[[ "${value}" == "${opt}" ]] && title="${value}"

		local item
		item="$("${json_tool}" -n -c --arg v "${value}" --arg t "${title}" '{const:$v,title:$t}')"
		if [[ "${first}" -eq 1 ]]; then
			one_of_items="${item}"
			first=0
		else
			one_of_items="${one_of_items},${item}"
		fi
	done

	local schema
	schema="$(printf '{"type":"object","properties":{"choices":{"type":"array","items":{"oneOf":[%s]}}},"required":["choices"]}' "${one_of_items}")"
	mcp_elicit "${message}" "${schema}"
}

# CallToolResult helpers ------------------------------------------------------
# SEP-1042: Structured response envelope helpers for MCP tools
#
# These helpers construct MCP-compliant CallToolResult objects with:
# - content[]: Human-readable text for LLMs
# - structuredContent: Machine-parseable JSON wrapped in {success, result} envelope
# - isError: Boolean flag for error responses
#
# All functions return 0 to avoid set -e issues; errors are expressed via isError field.

# __mcp_sdk_uint_or_default <value> <default>
# Parse value as unsigned integer, return default if invalid
#
# Arguments:
#   value   - Value to parse (may be empty, non-numeric, or negative)
#   default - Fallback value if parsing fails (also sanitized; falls back to 0)
#
# Output: Validated unsigned integer to stdout
# Returns: 0 always (never fails, always outputs valid number)
__mcp_sdk_uint_or_default() {
	local val="${1:-}"
	local def="${2:-0}"

	# Sanitize val: strip whitespace
	val="${val#"${val%%[![:space:]]*}"}" # trim leading
	val="${val%"${val##*[![:space:]]}"}" # trim trailing

	# Sanitize def: strip whitespace
	def="${def#"${def%%[![:space:]]*}"}" # trim leading
	def="${def%"${def##*[![:space:]]}"}" # trim trailing

	# Validate def is numeric; fall back to 0 if not
	case "$def" in
	'' | *[!0-9]*) def=0 ;;
	esac

	# Check if val is a valid non-negative integer (digits only)
	case "$val" in
	'' | *[!0-9]*) printf '%s' "$def" ;;
	*) printf '%s' "$val" ;;
	esac
}

# mcp_is_valid_json <string>
# Check if string is valid JSON (exactly one value)
#
# Returns: 0 if valid single JSON value, 1 if invalid/empty/multiple
# In minimal mode always returns 0 (assumes valid)
#
# NOTE: Uses -s (slurp) with length==1 to enforce single-value semantics.
# This correctly accepts `false` and `null`, and rejects empty/whitespace/multi-value.
mcp_is_valid_json() {
	local str="$1"

	if [ "${MCPBASH_MODE:-full}" = "minimal" ] || [ -z "${MCPBASH_JSON_TOOL_BIN:-}" ]; then
		# Minimal mode: assume valid (can't check)
		return 0
	fi

	# Normalize jq exit codes (jq returns 4 on parse error) to 0/1
	if printf '%s' "$str" | "${MCPBASH_JSON_TOOL_BIN}" -e -s 'length==1' >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

# mcp_extract_cli_error <stdout> <stderr> <exit_code>
# Extract error message from CLI output, preferring structured JSON
#
# Arguments:
#   stdout    - CLI stdout (may contain JSON error)
#   stderr    - CLI stderr (traditional error output)
#   exit_code - CLI exit code
#
# Output: Error message string to stdout
# Returns: 0 always
#
# Extraction priority:
#   1. stdout JSON .error.message
#   2. stdout JSON .error (if string)
#   3. stdout JSON .message (when .success==false or .ok==false or .status=="error")
#   4. stdout JSON .errors[0].message (GraphQL pattern)
#   5. stderr (traditional)
#   6. Generic "CLI exited with code N"
mcp_extract_cli_error() {
	local stdout="$1"
	local stderr="$2"
	local exit_code="$3"

	# Try structured JSON extraction if we have JSON tooling
	if [ "${MCPBASH_MODE:-full}" != "minimal" ] && [ -n "${MCPBASH_JSON_TOOL_BIN:-}" ]; then
		if mcp_is_valid_json "$stdout"; then
			local extracted
			# Note: first() available in jq 1.5+ and all gojq versions
			# Use | values to skip null results (ensures fallthrough)
			extracted=$(printf '%s' "$stdout" | "${MCPBASH_JSON_TOOL_BIN}" -r '
				first(
					(select(.error | type == "object") | .error.message | values),
					(select(.error | type == "string") | .error),
					(select(.success == false or .ok == false or .status == "error") | .message | values),
					((.errors // [])[0].message | values)
				) // empty
			' 2>/dev/null) || true

			if [ -n "$extracted" ]; then
				printf '%s' "$extracted"
				return 0
			fi
		fi
	fi

	# Fall back to stderr
	if [ -n "$stderr" ]; then
		printf '%s' "$stderr"
		return 0
	fi

	# Final fallback
	printf 'CLI exited with code %s' "$exit_code"
}

# mcp_byte_length <string>
# Get byte length of string (UTF-8 safe)
#
# Output: byte count to stdout
mcp_byte_length() {
	printf '%s' "$1" | wc -c | tr -d ' '
}

# mcp_result_success <json_data> [max_text_bytes]
# Emit MCP CallToolResult with success envelope
#
# Arguments:
#   json_data       - Valid JSON data to return
#   max_text_bytes  - Max size for content[].text (default: MCPBASH_MAX_TEXT_BYTES or 102400)
#
# Output: CallToolResult JSON to stdout
# Returns: 0 always (MCP tool errors are expressed via isError, not exit codes)
mcp_result_success() {
	local data="$1"
	# Sanitize max_text_bytes to avoid set -e hazards from non-numeric input
	# Default: 100KB (102400) - large enough for typical LLM responses to avoid
	# unhelpful summaries like "Success: object with 3 keys"
	local max_text_bytes
	max_text_bytes=$(__mcp_sdk_uint_or_default "${2:-}" "${MCPBASH_MAX_TEXT_BYTES:-102400}")

	# Guard: reject empty input
	if [ -z "$data" ]; then
		mcp_result_error '{"type":"internal_error","message":"Empty data passed to mcp_result_success"}'
		return 0 # Always return 0 after emitting CallToolResult
	fi

	if [ "${MCPBASH_MODE:-full}" != "minimal" ] && [ -n "${MCPBASH_JSON_TOOL_BIN:-}" ]; then
		# Full mode: validate, wrap, and emit in a single jq pipeline
		# - Use -s (slurp) to enforce single JSON value (reject streams like "1 2")
		# - Use tojson on parsed value for content[].text (avoids argv pressure entirely)
		# - Stream everything via stdin (no --arg with large payloads)
		# NOTE: Do NOT use -n with -s; -n means "don't read input" which breaks slurp
		printf '%s' "$data" | "${MCPBASH_JSON_TOOL_BIN}" -c -s --argjson max "$max_text_bytes" '
            # Validate single value
            if length != 1 then
                {
                    content: [{type: "text", text: "Error: input must be single JSON value"}],
                    structuredContent: {success: false, error: {type: "internal_error", message: "Input contained multiple JSON values", count: length}},
                    isError: true
                }
            else
                .[0] as $data |
                {success: true, result: $data} as $envelope |
                ($envelope | tojson) as $text |
                # Use utf8bytelength for accurate byte counting (length counts codepoints)
                if ($text | utf8bytelength) <= $max then
                    # Small: full envelope in text
                    {
                        content: [{type: "text", text: $text}],
                        structuredContent: $envelope,
                        isError: false
                    }
                else
                    # Large: summary in text
                    (
                        if ($data | type) == "array" then "Success: array with \($data | length) items"
                        elif ($data | type) == "object" then "Success: object with \($data | keys | length) keys"
                        else "Success: \($data | tostring | .[0:100])"
                        end
                    ) as $summary |
                    {
                        content: [{type: "text", text: $summary}],
                        structuredContent: $envelope,
                        isError: false
                    }
                end
            end
        ' 2>/dev/null || {
			# jq failed (invalid JSON)
			mcp_result_error '{"type":"internal_error","message":"Invalid JSON passed to mcp_result_success"}'
		}
	else
		# Minimal mode: wrap blindly (can't validate or parse)
		local envelope
		envelope="{\"success\":true,\"result\":${data}}"

		# Byte-accurate size check
		local size
		size=$(printf '%s' "$envelope" | wc -c | tr -d ' ')

		if [ "$size" -le "$max_text_bytes" ]; then
			# Small: full JSON in text
			# __mcp_sdk_json_escape returns a QUOTED string like "foo", use directly
			local escaped_text
			escaped_text=$(__mcp_sdk_json_escape "$envelope")
			printf '{"content":[{"type":"text","text":%s}],"structuredContent":%s,"isError":false}\n' \
				"$escaped_text" "$envelope"
		else
			# Large: generic summary (no jq to introspect type)
			printf '{"content":[{"type":"text","text":"Success: response too large for text content"}],"structuredContent":%s,"isError":false}\n' \
				"$envelope"
		fi
	fi
	return 0
}

# mcp_result_error <error_json>
# Emit MCP CallToolResult with error envelope
#
# Arguments:
#   error_json - Error object with 'type' and 'message' fields
#
# Output: CallToolResult JSON to stdout
# Returns: 0 always (MCP tool errors are expressed via isError, not exit codes)
mcp_result_error() {
	local error_json="$1"

	# Guard: handle empty input
	if [ -z "$error_json" ]; then
		error_json='{"type":"internal_error","message":"Unknown error (empty error object)"}'
	fi

	# Extract message for text content (with fallback)
	local message
	if [ "${MCPBASH_MODE:-full}" != "minimal" ] && [ -n "${MCPBASH_JSON_TOOL_BIN:-}" ]; then
		# Validate and normalize error_json:
		# 1. Must be valid JSON (single value, not a stream)
		# 2. Must be an object with type/message fields
		# If not, wrap appropriately to guarantee well-formed error structure
		error_json=$(printf '%s' "$error_json" | "${MCPBASH_JSON_TOOL_BIN}" -c -s '
            if length != 1 then
                {type:"internal_error", message:"Error payload must be single JSON value", raw:("multiple values: \(length)")}
            elif .[0] | type != "object" then
                {type:"internal_error", message:"Error payload must be an object", raw:(.[0] | tostring)}
            else
                .[0] + {type:(.[0].type // "internal_error"), message:(.[0].message // "Unknown error")}
            end
        ' 2>/dev/null) || {
			# jq failed entirely (invalid JSON) - wrap raw string
			local escaped_raw
			escaped_raw=$(printf '%s' "$1" | "${MCPBASH_JSON_TOOL_BIN}" -Rs '.')
			error_json=$(printf '{"type":"internal_error","message":"Invalid error JSON passed to mcp_result_error","raw":%s}' "$escaped_raw")
		}

		# Stream everything via stdin to avoid argv pressure (even for large error messages)
		# Use tostring to ensure content[].text is always a string (even if .message is non-string)
		printf '%s' "$error_json" | "${MCPBASH_JSON_TOOL_BIN}" -c '
            . as $err |
            (($err.message // "Unknown error") | tostring) as $msg |
            {
                content: [{type: "text", text: $msg}],
                structuredContent: {success: false, error: $err},
                isError: true
            }
        '
	else
		# Minimal mode: MUST produce valid JSON even if error_json is invalid
		# Do NOT embed raw error_json; always wrap safely to guarantee valid output
		message=$(printf '%s' "$error_json" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
		message="${message:-Unknown error}"
		# __mcp_sdk_json_escape returns quoted string, use directly
		local escaped_message escaped_raw
		escaped_message=$(__mcp_sdk_json_escape "$message")
		escaped_raw=$(__mcp_sdk_json_escape "$error_json")
		# Wrap error_json as escaped string to guarantee valid JSON output
		printf '{"content":[{"type":"text","text":%s}],"structuredContent":{"success":false,"error":{"type":"internal_error","message":%s,"raw":%s}},"isError":true}\n' \
			"$escaped_message" "$escaped_message" "$escaped_raw"
	fi
	return 0
}

# mcp_error - Convenience wrapper for tool execution errors
# Usage: mcp_error <type> <message> [--hint <hint>] [--data <json>]
# Always returns 0. Errors expressed via isError flag in response.
#
# Note: --data must be valid JSON. In minimal mode, invalid JSON will corrupt output.
# Caller is responsible for ensuring --data contains valid JSON.
# Note: Flags (--hint, --data) must include a value. Missing values cause undefined behavior.
mcp_error() {
	local error_type="${1:-internal_error}"
	local message="${2:-Unknown error}"
	# Guard: shift 2 fails if <2 args; fallback shifts remaining
	shift 2 || shift $#

	local hint=""
	local data=""

	# Parse optional flags
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--hint)
			hint="$2"
			shift 2
			;;
		--data)
			data="$2"
			shift 2
			;;
		*)
			# Silently ignore unknown flags for forward compatibility
			shift
			;;
		esac
	done

	# Build error JSON
	local error_json
	if [ "${MCPBASH_MODE:-full}" != "minimal" ] && [ -n "${MCPBASH_JSON_TOOL_BIN:-}" ]; then
		# Full mode: use jq for proper JSON construction
		# Validate --data if provided (--argjson fails with non-zero exit on invalid JSON)
		local data_json="null"
		if [[ -n "$data" ]]; then
			if data_json=$(printf '%s' "$data" | "${MCPBASH_JSON_TOOL_BIN}" -c '.' 2>/dev/null); then
				: # valid JSON, data_json now holds normalized form
			else
				# Invalid JSON - wrap raw value for debugging
				data_json=$("${MCPBASH_JSON_TOOL_BIN}" -n -c --arg raw "$data" '{"_invalid_json": $raw}')
			fi
		fi
		error_json=$("${MCPBASH_JSON_TOOL_BIN}" -n -c \
			--arg type "$error_type" \
			--arg message "$message" \
			--arg hint "$hint" \
			--argjson data "$data_json" \
			'{type: $type, message: $message} +
       (if $hint != "" then {hint: $hint} else {} end) +
       (if $data != null then {data: $data} else {} end)')
	else
		# Minimal mode: manual JSON construction
		# __mcp_sdk_json_escape returns quoted strings like "value"
		local escaped_type escaped_message escaped_hint
		escaped_type=$(__mcp_sdk_json_escape "$error_type")
		escaped_message=$(__mcp_sdk_json_escape "$message")
		error_json="{\"type\":${escaped_type},\"message\":${escaped_message}"
		if [[ -n "$hint" ]]; then
			escaped_hint=$(__mcp_sdk_json_escape "$hint")
			error_json="${error_json},\"hint\":${escaped_hint}"
		fi
		if [[ -n "$data" ]]; then
			# In minimal mode, trust data is valid JSON - caller responsibility
			error_json="${error_json},\"data\":${data}"
		fi
		error_json="${error_json}}"
	fi

	# Log all errors at debug level for observability
	mcp_log_debug "mcp_error" "type=${error_type}: ${message}"

	# Log at warn level if hint provided (actionable error)
	if [[ -n "$hint" ]]; then
		mcp_log_warn "mcp_error" "type=${error_type} hint: ${message}"
	fi

	# Delegate to existing helper
	mcp_result_error "$error_json"
}

# Lazy-load resource content helpers (lib/resource_content.sh)
# Called only when MIME auto-detection is needed
# Uses function-existence pattern (like __mcp_sdk_load_progress_passthrough at line 33)
__mcp_sdk_load_resource_helpers() {
	# Check if already loaded via function existence (consistent with existing SDK pattern)
	if declare -F mcp_resource_detect_mime >/dev/null 2>&1; then
		return 0
	fi
	local script_dir lib_path
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	lib_path="${script_dir}/../lib/resource_content.sh"
	if [[ -f "$lib_path" ]]; then
		# shellcheck source=lib/resource_content.sh disable=SC1091
		. "$lib_path"
	fi
	return 0 # Best-effort; MIME detection may still fail if file doesn't exist
}

# mcp_result_text_with_resource <text_or_json> [--path <file>] [--mime <type>] [--uri <uri>]
# Combine text output with optional embedded resources in a single call.
#
# Arguments:
#   $1       - Text content or JSON object (passed to mcp_result_success)
#   --path   - File path to embed as resource (repeatable)
#   --mime   - MIME type for preceding --path (auto-detect if omitted)
#   --uri    - Custom URI for preceding --path (auto-generate if omitted)
#
# Output: CallToolResult JSON to stdout
# Returns: 0 always (errors are logged, not thrown)
#
# Resources are written to MCP_TOOL_RESOURCES_FILE as a single JSON array.
# WARNING: This helper OVERWRITES MCP_TOOL_RESOURCES_FILE (does not append).
mcp_result_text_with_resource() {
	local data="${1:-}"
	shift || true

	# Parse flags using parallel arrays (avoids delimiter issues with | in paths/URIs)
	local -a res_paths=() res_mimes=() res_uris=()
	local current_path="" current_mime="" current_uri=""

	local have_pending_path=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--path)
			# Save pending resource if any (even empty paths, to emit debug log in loop)
			if [[ "$have_pending_path" == true ]]; then
				res_paths+=("$current_path")
				res_mimes+=("$current_mime")
				res_uris+=("$current_uri")
			fi
			current_path="${2:-}"
			current_mime=""
			current_uri=""
			have_pending_path=true
			shift 2 || shift $#
			;;
		--mime)
			current_mime="${2:-}"
			shift 2 || shift $#
			;;
		--uri)
			current_uri="${2:-}"
			shift 2 || shift $#
			;;
		*)
			# Log warning for unknown flags (helps catch typos)
			mcp_log_debug "sdk" "mcp_result_text_with_resource: unknown flag ignored: $1"
			shift
			;;
		esac
	done

	# Don't forget last pending path (even empty, to emit debug log in loop)
	if [[ "$have_pending_path" == true ]]; then
		res_paths+=("$current_path")
		res_mimes+=("$current_mime")
		res_uris+=("$current_uri")
	fi

	# Write resources to MCP_TOOL_RESOURCES_FILE as single JSON array
	# CRITICAL: Framework expects a single JSON document, NOT JSONL (one object per line)
	if [[ ${#res_paths[@]} -gt 0 ]]; then
		if [[ -z "${MCP_TOOL_RESOURCES_FILE:-}" ]]; then
			mcp_log_warn "sdk" "mcp_result_text_with_resource: MCP_TOOL_RESOURCES_FILE not set, resources will not be embedded"
		else
			# Build JSON array in memory, then write once
			local json_array="["
			local sep=""
			local i path mime uri uri_json

			for ((i = 0; i < ${#res_paths[@]}; i++)); do
				path="${res_paths[$i]:-}"
				mime="${res_mimes[$i]:-}"
				uri="${res_uris[$i]:-}"

				# Skip empty paths (e.g., from --path "")
				if [[ -z "$path" ]]; then
					mcp_log_debug "sdk" "mcp_result_text_with_resource: empty path, skipping"
					continue
				fi

				# Validate: must be regular file AND readable (not directory, not broken symlink)
				if [[ ! -f "$path" ]] || [[ ! -r "$path" ]]; then
					mcp_log_warn "sdk" "mcp_result_text_with_resource: not a readable file, skipping path=${path}"
					continue
				fi

				# Auto-detect MIME if not provided (lazy-load resource helpers)
				if [[ -z "$mime" ]]; then
					__mcp_sdk_load_resource_helpers
					# Use declare -F (not command -v) to check for shell functions
					if declare -F mcp_resource_detect_mime >/dev/null 2>&1; then
						mime="$(mcp_resource_detect_mime "$path" "application/octet-stream")"
					else
						mime="application/octet-stream"
						mcp_log_debug "sdk" "mcp_result_text_with_resource: MIME auto-detect unavailable, using ${mime}"
					fi
				fi

				# Build JSON object for this resource
				uri_json="null"
				[[ -n "$uri" ]] && uri_json="$(__mcp_sdk_json_escape "$uri")"

				json_array+="${sep}{\"path\":$(__mcp_sdk_json_escape "$path"),\"mimeType\":$(__mcp_sdk_json_escape "$mime"),\"uri\":${uri_json}}"
				sep=","
			done

			json_array+="]"

			# OVERWRITE (not append) - ensures consistent format
			# If tool mixes direct TSV writes + helper, the helper wins
			# This avoids format mixing (TSV then JSON) which breaks parsing
			printf '%s' "$json_array" >"${MCP_TOOL_RESOURCES_FILE}"
		fi
	fi

	# Delegate to mcp_result_success
	mcp_result_success "$data"
}

# ============================================================================
# Configuration Helpers
# ============================================================================

# Private helper: check if string is valid JSON
# Used by mcp_config_load
__mcp_config_is_json() {
	local str="$1"
	local json_tool="${MCPBASH_JSON_TOOL_BIN:-}"
	if [[ -n "$json_tool" ]]; then
		printf '%s' "$str" | "$json_tool" -e . >/dev/null 2>&1
	else
		# Basic check: starts with { or [
		[[ "$str" =~ ^[[:space:]]*[\{\[] ]]
	fi
}

# Private helper: merge two JSON objects (shallow)
# Used by mcp_config_load
__mcp_config_merge() {
	local base="$1" overlay="$2"
	local json_tool="${MCPBASH_JSON_TOOL_BIN:-}"
	if [[ -n "$json_tool" ]]; then
		"$json_tool" -n --argjson base "$base" --argjson overlay "$overlay" \
			'$base + $overlay' 2>/dev/null || printf '%s' "$base"
	else
		# Fallback: overlay wins entirely (no jq available for merge)
		printf '%s' "$overlay"
	fi
}

# Private helper: read and validate JSON file
# Used by mcp_config_load
__mcp_config_read_file() {
	local path="$1"
	if [[ -f "$path" ]] && [[ -r "$path" ]]; then
		local content
		content=$(<"$path")
		if __mcp_config_is_json "$content"; then
			printf '%s' "$content"
			return 0
		else
			mcp_log_warn "config" "Invalid JSON in file: $path"
			return 1
		fi
	fi
	return 1
}

# mcp_config_load [--env VAR] [--file PATH] [--example PATH] [--defaults JSON]
# Load and merge configuration from multiple sources.
#
# Precedence (highest to lowest):
#   1. Env var (JSON string or path to file)
#   2. --file config file
#   3. --example config file
#   4. --defaults inline JSON
#
# Result: Sets MCP_CONFIG_JSON env var with merged config
# Returns: 0 if config available, 1 if no sources and empty defaults
mcp_config_load() {
	local env_var="" config_file="" example_file="" defaults="{}"

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--env)
			env_var="${2:-}"
			shift 2 || shift $#
			;;
		--file)
			config_file="${2:-}"
			shift 2 || shift $#
			;;
		--example)
			example_file="${2:-}"
			shift 2 || shift $#
			;;
		--defaults)
			defaults="${2:-}"
			shift 2 || shift $#
			;;
		*) shift ;;
		esac
	done

	# Validate --defaults JSON
	if [[ "$defaults" != "{}" ]] && ! __mcp_config_is_json "$defaults"; then
		mcp_log_warn "config" "Invalid JSON in --defaults, using {}"
		defaults="{}"
	fi

	local merged="$defaults"
	local sources_loaded=0

	# 1. Load example file (lowest priority)
	if [[ -n "$example_file" ]]; then
		local example_json
		if example_json=$(__mcp_config_read_file "$example_file"); then
			merged=$(__mcp_config_merge "$merged" "$example_json")
			((++sources_loaded))
			mcp_log_debug "config" "Loaded example config: $example_file"
		fi
	fi

	# 2. Load config file
	if [[ -n "$config_file" ]]; then
		local file_json
		if file_json=$(__mcp_config_read_file "$config_file"); then
			merged=$(__mcp_config_merge "$merged" "$file_json")
			((++sources_loaded))
			mcp_log_debug "config" "Loaded config file: $config_file"
		fi
	fi

	# 3. Load from env var (highest priority)
	if [[ -n "$env_var" ]]; then
		local env_value="${!env_var:-}"
		if [[ -n "$env_value" ]]; then
			if __mcp_config_is_json "$env_value"; then
				# Env var contains JSON directly
				merged=$(__mcp_config_merge "$merged" "$env_value")
				((++sources_loaded))
				mcp_log_debug "config" "Loaded config from env var: $env_var (JSON)"
			elif [[ -f "$env_value" ]]; then
				# Env var contains path to file
				local env_file_json
				if env_file_json=$(__mcp_config_read_file "$env_value"); then
					merged=$(__mcp_config_merge "$merged" "$env_file_json")
					((++sources_loaded))
					mcp_log_debug "config" "Loaded config from env var: $env_var (file: $env_value)"
				fi
			else
				mcp_log_warn "config" "Env var $env_var is neither valid JSON nor a file path"
			fi
		fi
	fi

	# Export merged config
	export MCP_CONFIG_JSON="$merged"

	# Return success if at least one source loaded (or defaults exist)
	if [[ $sources_loaded -gt 0 ]] || [[ "$defaults" != "{}" ]]; then
		return 0
	else
		mcp_log_warn "config" "No configuration sources loaded"
		return 1
	fi
}

# mcp_config_get <jq_path> [--default VALUE]
# Get a value from loaded configuration.
#
# Arguments:
#   jq_path   - jq path expression (e.g., '.timeout', '.api.endpoint')
#   --default - Default value if path not found
#
# Output: Value at path (stdout)
# Returns: 0 on success, 1 if path missing without default
mcp_config_get() {
	local path="${1:-}"
	shift || true
	local default_value=""
	local has_default=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--default)
			default_value="${2:-}"
			has_default=true
			shift 2 || shift $#
			;;
		*) shift ;;
		esac
	done

	if [[ -z "$path" ]]; then
		mcp_log_warn "config" "mcp_config_get: path required"
		return 1
	fi

	local config="${MCP_CONFIG_JSON:-{}}"
	local json_tool="${MCPBASH_JSON_TOOL_BIN:-}"
	local result

	if [[ -n "$json_tool" ]]; then
		# Use jq for path extraction
		# Note: We use a sentinel string for missing keys, not empty string
		# Empty string "" is a valid config value and should be returned
		# Sentinel collision risk: if a config value is literally "__MCP_CONFIG_NULL__"
		# it will be treated as missing. This is extremely unlikely in practice.
		# IMPORTANT: Cannot use // operator because it treats false as falsy.
		# Instead, explicitly check for null (missing key) vs false (actual value).
		result=$("$json_tool" -r "($path) as \$v | if \$v == null then \"__MCP_CONFIG_NULL__\" else \$v end" <<<"$config" 2>/dev/null)

		if [[ "$result" == "__MCP_CONFIG_NULL__" ]]; then
			if [[ "$has_default" == true ]]; then
				printf '%s' "$default_value"
				return 0
			else
				return 1
			fi
		fi

		printf '%s' "$result"
		return 0
	else
		# Minimal mode: basic top-level key extraction
		# Only supports simple paths like '.key' (not nested)
		# NOTE: BASH_REMATCH usage is safe here because we only access [1] after
		# successful regex match that guarantees the capture group exists.
		# See bash-conventions.mdc for general BASH_REMATCH guidance.
		if [[ "$path" =~ ^\.([a-zA-Z_][a-zA-Z0-9_]*)$ ]]; then
			local key="${BASH_REMATCH[1]}"
			# Extract value using pattern matching
			# Limitation: does not handle escaped quotes in values
			if [[ "$config" =~ \"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
				# Note: [^\"]* allows empty strings (test #21)
				printf '%s' "${BASH_REMATCH[1]}"
				return 0
			elif [[ "$config" =~ \"$key\"[[:space:]]*:[[:space:]]*(-?[0-9]+\.?[0-9]*) ]]; then
				# Supports: integers, floats, negative numbers
				printf '%s' "${BASH_REMATCH[1]}"
				return 0
			elif [[ "$config" =~ \"$key\"[[:space:]]*:[[:space:]]*(true|false) ]]; then
				printf '%s' "${BASH_REMATCH[1]}"
				return 0
			fi
		fi

		# Path not found or too complex for minimal mode
		if [[ "$has_default" == true ]]; then
			printf '%s' "$default_value"
			return 0
		fi

		mcp_log_debug "config" "mcp_config_get: path not found (minimal mode): $path"
		return 1
	fi
}

# __mcp_json_truncate_at_path <json> <max_bytes> <jq_path>
# Internal helper: truncate array at specified jq path
# Precondition: array_path has been validated by caller (format check + exists + is array)
__mcp_json_truncate_at_path() {
	local json="$1"
	local max_bytes="$2"
	local array_path="$3"

	local total
	total=$(printf '%s' "$json" | "${MCPBASH_JSON_TOOL_BIN}" -r "${array_path} | length")

	# Early exit: empty array - nothing to truncate
	if [[ "$total" -eq 0 ]]; then
		printf '%s' "$json" | "${MCPBASH_JSON_TOOL_BIN}" -c \
			'{result: ., truncated: false, kept: 0, total: 0}'
		return 0
	fi

	# Early exit: check if entire result fits without truncation
	local full_size
	full_size=$(printf '%s' "$json" | wc -c | tr -d ' ')
	if [[ "$full_size" -le "$max_bytes" ]]; then
		printf '%s' "$json" | "${MCPBASH_JSON_TOOL_BIN}" -c \
			--argjson t "$total" \
			'{result: ., truncated: false, kept: $t, total: $t}'
		return 0
	fi

	# Pre-check: can we fit with empty array at path?
	local empty_size empty_json
	empty_json=$(printf '%s' "$json" | "${MCPBASH_JSON_TOOL_BIN}" -c "${array_path} = []")
	empty_size=$(printf '%s' "$empty_json" | wc -c | tr -d ' ')

	if [[ "$empty_size" -gt "$max_bytes" ]]; then
		"${MCPBASH_JSON_TOOL_BIN}" -n -c \
			--arg msg "Response too large ($empty_size bytes) even with empty array at $array_path" \
			'{result: null, truncated: false, error: {type: "output_too_large", message: $msg}}'
		return 0
	fi

	# Binary search for max elements that fit
	local low=1 high=$total mid best_count=0

	while [[ "$low" -le "$high" ]]; do
		mid=$(((low + high) / 2))
		local test_json test_size
		test_json=$(printf '%s' "$json" | "${MCPBASH_JSON_TOOL_BIN}" -c "${array_path} = ${array_path}[:$mid]")
		test_size=$(printf '%s' "$test_json" | wc -c | tr -d ' ')

		if [[ "$test_size" -le "$max_bytes" ]]; then
			best_count=$mid
			low=$((mid + 1))
		else
			high=$((mid - 1))
		fi
	done

	# Output truncated result
	# Note: \$k and \$t are escaped to become jq variables (passed via --argjson)
	printf '%s' "$json" | "${MCPBASH_JSON_TOOL_BIN}" -c \
		--argjson k "$best_count" \
		--argjson t "$total" \
		"${array_path} = ${array_path}[:\$k] | {result: ., truncated: true, kept: \$k, total: \$t}"
}

# mcp_json_truncate <json> [max_bytes] [--array-path <jq_path>]
# Truncate JSON arrays while preserving valid structure
#
# Arguments:
#   json        - JSON data to potentially truncate
#   max_bytes   - Maximum size of the result payload (default: MCPBASH_MAX_TOOL_OUTPUT_SIZE or 10MB)
#                 NOTE: This bounds the compact serialized size of .result, not the wrapper object
#   --array-path - jq path to array to truncate (e.g., ".data", ".response.items")
#                  If not provided, falls back to heuristics (top-level array, then .results)
#
# Output: {result: <data>, truncated: bool, kept?: int, total?: int, error?: object}
# Returns: 0 always (errors expressed via .error field for set -e safety)
#
# Performance note: Binary search runs O(log n) jq invocations. For very large
# arrays (10k+ elements), consider pre-filtering or pagination at the source.
mcp_json_truncate() {
	local json=""
	local max_bytes=""
	local array_path=""
	local positional_idx=0

	# Parse positional and named arguments
	# Supports: json max_bytes --array-path .data
	#           json --array-path .data max_bytes
	#           --array-path .data json max_bytes
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--array-path)
			# Validate value is present and not another flag
			if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
				"${MCPBASH_JSON_TOOL_BIN}" -n -c \
					'{result: null, truncated: false, error: {type: "invalid_path_syntax", message: "--array-path requires a value"}}'
				return 0
			fi
			array_path="$2"
			shift 2
			;;
		*)
			# Positional args by index: json (0), max_bytes (1)
			case $positional_idx in
			0) json="$1" ;;
			1) max_bytes="$1" ;;
			esac
			((positional_idx++))
			shift
			;;
		esac
	done

	# Sanitize max_bytes to avoid set -e hazards from non-numeric input
	max_bytes=$(__mcp_sdk_uint_or_default "${max_bytes:-}" "${MCPBASH_MAX_TOOL_OUTPUT_SIZE:-10485760}")

	# Minimal mode: no truncation capability
	if [ "${MCPBASH_MODE:-full}" = "minimal" ] || [ -z "${MCPBASH_JSON_TOOL_BIN:-}" ]; then
		printf '{"result":%s,"truncated":false,"_warning":"truncation unavailable in minimal mode"}\n' "$json"
		return 0
	fi

	# Guard: validate input is valid JSON (single value, not a stream)
	# Use -s (slurp) to collect all values; output error object instead of using error()
	# to allow bash to distinguish between empty, multi-value, and invalid JSON
	local compact size validation_result
	validation_result=$(printf '%s' "$json" | "${MCPBASH_JSON_TOOL_BIN}" -c -s '
        if length == 0 then {_error: "empty", count: 0}
        elif length > 1 then {_error: "multiple", count: length}
        else {_ok: .[0]}
        end
    ' 2>/dev/null) || {
		# jq parse error - invalid JSON
		printf '%s' "$json" | "${MCPBASH_JSON_TOOL_BIN}" -Rs -c \
			'{result: null, truncated: false, error: {type: "invalid_json", message: "Invalid JSON: parse error", raw: .}}'
		return 0
	}

	# Check if validation returned an error object
	local err_type
	err_type=$(printf '%s' "$validation_result" | "${MCPBASH_JSON_TOOL_BIN}" -r '._error // empty')
	if [ -n "$err_type" ]; then
		local err_count err_msg
		err_count=$(printf '%s' "$validation_result" | "${MCPBASH_JSON_TOOL_BIN}" -r '.count')
		case "$err_type" in
		empty)
			err_msg="Empty input: expected exactly one JSON value"
			;;
		multiple)
			err_msg="Multiple JSON values found ($err_count): expected exactly one"
			;;
		*)
			err_msg="Validation error: $err_type"
			;;
		esac
		printf '%s' "$json" | "${MCPBASH_JSON_TOOL_BIN}" -Rs -c --arg msg "$err_msg" \
			'{result: null, truncated: false, error: {type: "invalid_json", message: $msg, raw: .}}'
		return 0
	fi

	# Extract the valid single value
	compact=$(printf '%s' "$validation_result" | "${MCPBASH_JSON_TOOL_BIN}" -c '._ok')

	# compact is now normalized (single value, compact format)
	# Use wc -c for byte count; printf '%s' doesn't add newlines, and command
	# substitution strips trailing newlines from jq output, so this is accurate
	size=$(printf '%s' "$compact" | wc -c | tr -d ' ')

	# Use compact version for all subsequent operations
	json="$compact"

	# If --array-path specified, use it exclusively (validate path even if data fits)
	if [[ -n "$array_path" ]]; then
		# SECURITY: Validate path format before interpolating into jq
		# Allows: .key, .key.nested, .key_name, .key123
		# Rejects: empty, missing dot, index notation, trailing dot, injection attempts
		if [[ ! "$array_path" =~ ^\.[a-zA-Z_][a-zA-Z0-9_]*(\.[a-zA-Z_][a-zA-Z0-9_]*)*$ ]]; then
			"${MCPBASH_JSON_TOOL_BIN}" -n -c \
				--arg path "$array_path" \
				'{result: null, truncated: false, error: {type: "invalid_path_syntax", message: ("Invalid path syntax: " + $path + " (must be .key or .key.nested format)")}}'
			return 0
		fi

		# Validate path exists and is an array
		# Note: Using string interpolation is safe here because we validated the format above
		local path_check
		path_check=$(printf '%s' "$json" | "${MCPBASH_JSON_TOOL_BIN}" -r \
			"if ${array_path} == null then \"missing\"
			 elif (${array_path} | type) != \"array\" then \"not_array\"
			 else \"ok\"
			 end" 2>/dev/null) || path_check="invalid_path"

		case "$path_check" in
		missing)
			"${MCPBASH_JSON_TOOL_BIN}" -n -c \
				--arg path "$array_path" \
				'{result: null, truncated: false, error: {type: "path_not_found", message: ("Path not found: " + $path)}}'
			return 0
			;;
		not_array)
			"${MCPBASH_JSON_TOOL_BIN}" -n -c \
				--arg path "$array_path" \
				'{result: null, truncated: false, error: {type: "invalid_array_path", message: ("Path is not an array: " + $path)}}'
			return 0
			;;
		invalid_path)
			"${MCPBASH_JSON_TOOL_BIN}" -n -c \
				--arg path "$array_path" \
				'{result: null, truncated: false, error: {type: "invalid_path", message: ("Invalid path or malformed JSON: " + $path)}}'
			return 0
			;;
		esac

		# Path is valid array - proceed with truncation using helper
		__mcp_json_truncate_at_path "$json" "$max_bytes" "$array_path"
		return 0
	fi

	# No --array-path provided - use heuristics

	# Small enough - return as-is (only for heuristic case)
	if [ "$size" -le "$max_bytes" ]; then
		printf '%s' "$json" | "${MCPBASH_JSON_TOOL_BIN}" -n -c '{result: input, truncated: false}'
		return 0
	fi

	# Check if it's an array
	local json_type
	json_type=$(printf '%s' "$json" | "${MCPBASH_JSON_TOOL_BIN}" -r 'type')

	if [ "$json_type" = "array" ]; then
		local total
		total=$(printf '%s' "$json" | "${MCPBASH_JSON_TOOL_BIN}" 'length')

		# Early exit: if even one element exceeds max_bytes, return empty array
		local first_elem_size first_elem
		first_elem=$(printf '%s' "$json" | "${MCPBASH_JSON_TOOL_BIN}" -c '.[0:1]')
		first_elem_size=$(printf '%s' "$first_elem" | wc -c | tr -d ' ')
		if [ "$first_elem_size" -gt "$max_bytes" ]; then
			printf '%s' "$total" | "${MCPBASH_JSON_TOOL_BIN}" -n -c \
				'{result: [], truncated: true, kept: 0, total: (input | tonumber), _warning: "individual items exceed max_bytes"}'
			return 0
		fi

		# Binary search for max elements that fit
		local low high mid best best_count
		low=1
		high=$total
		best="[]"
		best_count=0

		while [ "$low" -le "$high" ]; do
			mid=$(((low + high) / 2))
			local candidate csize
			candidate=$(printf '%s' "$json" | "${MCPBASH_JSON_TOOL_BIN}" -c ".[:$mid]")
			csize=$(printf '%s' "$candidate" | wc -c | tr -d ' ')

			if [ "$csize" -le "$max_bytes" ]; then
				best="$candidate"
				best_count=$mid
				low=$((mid + 1))
			else
				high=$((mid - 1))
			fi
		done

		# Stream $best via stdin to avoid argv size limits
		printf '%s' "$best" | "${MCPBASH_JSON_TOOL_BIN}" -n -c \
			--argjson t "$total" \
			--argjson k "$best_count" \
			'{result: input, truncated: true, kept: $k, total: $t}'
		return 0
	fi

	# Check if it's an object with .results array (common API pattern - backward compatibility)
	local has_results
	has_results=$(printf '%s' "$json" | "${MCPBASH_JSON_TOOL_BIN}" -r 'if .results and (.results | type) == "array" then "yes" else "no" end')

	if [ "$has_results" = "yes" ]; then
		__mcp_json_truncate_at_path "$json" "$max_bytes" ".results"
		return 0
	fi

	# Cannot truncate safely - emit error structure
	# Still return 0 for set -e safety; error is expressed via .error field
	"${MCPBASH_JSON_TOOL_BIN}" -n -c \
		--arg msg "Response too large ($size bytes) and cannot be safely truncated (not an array)" \
		'{result: null, truncated: false, error: {type: "output_too_large", message: $msg}}'
	return 0
}

# Safe download helper ---------------------------------------------------------
#
# mcp_download_safe --url <url> --out <path> [--allow <host>]... [options]
#
# Ergonomic wrapper for secure HTTP(S) downloads. Delegates to the HTTPS provider
# (providers/https.sh) for security enforcement while providing tool-author-friendly API.
#
# Security features (inherited from HTTPS provider):
# - SSRF protection (private IP blocking)
# - DNS rebinding defense (--resolve pinning)
# - Obfuscated IP literal rejection
# - Allow/deny list enforcement
# - HTTPS only, no redirects
#
# Returns JSON to stdout: {"success":true,"bytes":<n>,"path":"<path>"} or
# {"success":false,"error":{"type":"<type>","message":"<msg>"}}
# Always returns exit code 0 for set -e safety.

mcp_download_safe() {
	local url="" out="" max_bytes="" timeout="" user_agent="" retry=1 retry_delay="1.0"
	local -a allow_hosts=()
	local -a deny_hosts=()

	# Parse arguments - reject unknown flags for security
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--url)
			url="$2"
			shift 2
			;;
		--out)
			out="$2"
			shift 2
			;;
		--allow)
			allow_hosts+=("$2")
			shift 2
			;;
		--deny)
			deny_hosts+=("$2")
			shift 2
			;;
		--max-bytes)
			max_bytes="$2"
			shift 2
			;;
		--timeout)
			timeout="$2"
			shift 2
			;;
		--user-agent)
			user_agent="$2"
			shift 2
			;;
		--retry)
			retry="$2"
			shift 2
			;;
		--retry-delay)
			retry_delay="$2"
			shift 2
			;;
		-*)
			# SECURITY: Reject unknown flags to prevent typos like --alow silently passing
			local escaped_msg
			escaped_msg=$(__mcp_sdk_json_escape "Unknown option: $1")
			printf '{"success":false,"error":{"type":"invalid_params","message":%s}}' "$escaped_msg"
			return 0
			;;
		*)
			# Reject positional arguments
			local escaped_msg
			escaped_msg=$(__mcp_sdk_json_escape "Unexpected argument: $1")
			printf '{"success":false,"error":{"type":"invalid_params","message":%s}}' "$escaped_msg"
			return 0
			;;
		esac
	done

	# Validate required params
	if [[ -z "$url" ]]; then
		printf '{"success":false,"error":{"type":"invalid_url","message":"--url is required"}}'
		return 0
	fi
	if [[ -z "$out" ]]; then
		printf '{"success":false,"error":{"type":"invalid_params","message":"--out is required"}}'
		return 0
	fi

	# Validate URL scheme
	if [[ "$url" != https://* ]]; then
		printf '{"success":false,"error":{"type":"invalid_url","message":"URL must use https://"}}'
		return 0
	fi

	# Validate numeric parameters
	if [[ -n "$max_bytes" ]] && ! [[ "$max_bytes" =~ ^[0-9]+$ ]]; then
		printf '{"success":false,"error":{"type":"invalid_params","message":"--max-bytes must be a positive integer"}}'
		return 0
	fi
	if [[ -n "$timeout" ]]; then
		if ! [[ "$timeout" =~ ^[0-9]+$ ]]; then
			printf '{"success":false,"error":{"type":"invalid_params","message":"--timeout must be a positive integer"}}'
			return 0
		fi
		if [[ "$timeout" -gt 60 ]]; then
			printf '{"success":false,"error":{"type":"invalid_params","message":"--timeout cannot exceed 60 seconds"}}'
			return 0
		fi
	fi
	if ! [[ "$retry" =~ ^[0-9]+$ ]] || [[ "$retry" -lt 1 ]]; then
		printf '{"success":false,"error":{"type":"invalid_params","message":"--retry must be a positive integer"}}'
		return 0
	fi
	# Accept formats: 1, 1.0, 0.5, .5
	if ! [[ "$retry_delay" =~ ^[0-9]*\.?[0-9]+$ ]]; then
		printf '{"success":false,"error":{"type":"invalid_params","message":"--retry-delay must be a number (e.g., 0.5, 1, 2.0)"}}'
		return 0
	fi

	# Locate provider
	local provider=""
	if [[ -n "${MCPBASH_HOME:-}" ]] && [[ -f "${MCPBASH_HOME}/providers/https.sh" ]]; then
		provider="${MCPBASH_HOME}/providers/https.sh"
	else
		local sdk_dir
		sdk_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
		if [[ -f "${sdk_dir}/../providers/https.sh" ]]; then
			provider="${sdk_dir}/../providers/https.sh"
		fi
	fi

	if [[ -z "$provider" ]] || [[ ! -f "$provider" ]]; then
		printf '{"success":false,"error":{"type":"provider_unavailable","message":"HTTPS provider not found"}}'
		return 0
	fi

	# Pre-check for curl (provider exit code 4 means both "policy blocked" and "curl missing",
	# so we check here to return the correct error type)
	if ! command -v curl >/dev/null 2>&1; then
		printf '{"success":false,"error":{"type":"provider_unavailable","message":"curl is required for HTTPS provider"}}'
		return 0
	fi

	# Build allow/deny lists for provider (comma-separated)
	local allow_list="" deny_list=""
	if [[ ${#allow_hosts[@]} -gt 0 ]]; then
		allow_list=$(
			IFS=,
			echo "${allow_hosts[*]}"
		)
	fi
	if [[ ${#deny_hosts[@]} -gt 0 ]]; then
		deny_list=$(
			IFS=,
			echo "${deny_hosts[*]}"
		)
	fi

	# Set default User-Agent if not specified
	if [[ -z "$user_agent" ]]; then
		local version="unknown"
		if [[ -n "${MCPBASH_HOME:-}" ]] && [[ -f "${MCPBASH_HOME}/VERSION" ]]; then
			version=$(<"${MCPBASH_HOME}/VERSION")
			version="${version%%$'\n'*}" # Strip newlines
		fi
		user_agent="mcpbash/${version} (tool-sdk)"
	fi

	# Prepare environment for provider
	local -a env_vars=()
	[[ -n "$allow_list" ]] && env_vars+=(MCPBASH_HTTPS_ALLOW_HOSTS="$allow_list")
	[[ -n "$deny_list" ]] && env_vars+=(MCPBASH_HTTPS_DENY_HOSTS="$deny_list")
	[[ -n "$max_bytes" ]] && env_vars+=(MCPBASH_HTTPS_MAX_BYTES="$max_bytes")
	[[ -n "$timeout" ]] && env_vars+=(MCPBASH_HTTPS_TIMEOUT="$timeout")
	env_vars+=(MCPBASH_HTTPS_USER_AGENT="$user_agent")

	# Create temp files for download and stderr capture
	local tmp_out tmp_err
	tmp_out=$(mktemp "${TMPDIR:-/tmp}/mcp-dl.XXXXXX") || {
		printf '{"success":false,"error":{"type":"write_error","message":"Could not create temp file"}}'
		return 0
	}
	tmp_err=$(mktemp "${TMPDIR:-/tmp}/mcp-dl-err.XXXXXX") || {
		rm -f "$tmp_out"
		printf '{"success":false,"error":{"type":"write_error","message":"Could not create temp file"}}'
		return 0
	}
	trap 'rm -f -- "${tmp_out:-}" "${tmp_err:-}"' RETURN

	# Execute with optional retry (exponential backoff + jitter, consistent with mcp_with_retry)
	local attempt=1 rc=0 delay="$retry_delay"

	while [[ $attempt -le $retry ]]; do
		rc=0
		if [[ ${#env_vars[@]} -gt 0 ]]; then
			env "${env_vars[@]}" bash "$provider" "$url" >"$tmp_out" 2>"$tmp_err" || rc=$?
		else
			bash "$provider" "$url" >"$tmp_out" 2>"$tmp_err" || rc=$?
		fi

		[[ $rc -eq 0 ]] && break

		# Don't retry permanent failures:
		#   4 = policy rejection (host blocked - won't change)
		#   6 = size exceeded (server response too large - won't shrink)
		#   7 = redirect (deterministic behavior - same URL will always redirect)
		[[ $rc -eq 4 || $rc -eq 6 || $rc -eq 7 ]] && break

		attempt=$((attempt + 1))
		if [[ $attempt -le $retry ]]; then
			# Add jitter (0-50% of delay) consistent with mcp_with_retry
			local jitter sleep_time
			jitter=$(awk "BEGIN {srand(); print $delay * rand() * 0.5}")
			sleep_time=$(awk "BEGIN {print $delay + $jitter}")
			sleep "$sleep_time"
			delay=$(awk "BEGIN {print $delay * 2}")
		fi
	done

	# CRITICAL: Read first line from $tmp_err file BEFORE sanitization truncates it
	# The sanitized stderr is for error messages; redirect location needs raw first line
	local stderr_first_line=""
	if [[ -s "$tmp_err" ]]; then
		stderr_first_line=$(head -n 1 "$tmp_err")
	fi

	# Capture stderr for error messages (truncate to 200 chars, sanitize control chars)
	local stderr_raw=""
	if [[ -s "$tmp_err" ]]; then
		# Replace newlines/tabs/CRs with spaces, strip control chars
		stderr_raw=$(head -c 200 "$tmp_err" | tr '\n\t\r' '   ' | sed 's/[[:cntrl:]]//g')
	fi

	# Translate exit codes to error types
	case $rc in
	0)
		# Success - move to final destination
		if mv "$tmp_out" "$out" 2>/dev/null; then
			local bytes escaped_path
			bytes=$(wc -c <"$out" | tr -d ' ')
			# SECURITY: JSON-escape the path to prevent injection
			escaped_path=$(__mcp_sdk_json_escape "$out")
			printf '{"success":true,"bytes":%s,"path":%s}' "$bytes" "$escaped_path"
		else
			printf '{"success":false,"error":{"type":"write_error","message":"Could not write to output path"}}'
		fi
		;;
	4)
		printf '{"success":false,"error":{"type":"host_blocked","message":"Host blocked by policy"}}'
		;;
	5)
		if [[ -n "$stderr_raw" ]]; then
			local escaped_msg
			escaped_msg=$(__mcp_sdk_json_escape "Network request failed: ${stderr_raw}")
			printf '{"success":false,"error":{"type":"network_error","message":%s}}' "$escaped_msg"
		else
			printf '{"success":false,"error":{"type":"network_error","message":"Network request failed"}}'
		fi
		;;
	6)
		printf '{"success":false,"error":{"type":"size_exceeded","message":"Response exceeds max-bytes limit"}}'
		;;
	7)
		# Redirect detected - parse location from FIRST LINE of stderr (before sanitization)
		local location=""
		if [[ "$stderr_first_line" == redirect:* ]]; then
			location="${stderr_first_line#redirect:}"
			# CRITICAL: Strip trailing newline and CR (head -n 1 preserves the \n)
			# Two-pass stripping handles both Unix (\n) and Windows (\r\n) line endings:
			# - After first strip: "https://...\r" (if server sent \r\n)
			# - After second strip: "https://..." (clean)
			location="${location%$'\n'}"
			location="${location%$'\r'}"
		fi
		if [[ -n "$location" ]]; then
			local escaped_loc
			escaped_loc=$(__mcp_sdk_json_escape "$location")
			printf '{"success":false,"error":{"type":"redirect","location":%s,"message":"URL redirects - use canonical URL or add target to allowlist"}}' "$escaped_loc"
		else
			printf '{"success":false,"error":{"type":"redirect","message":"URL redirects but location unavailable"}}'
		fi
		;;
	1 | 2 | 126 | 127)
		# Provider script errors (syntax, not found, not executable)
		if [[ -n "$stderr_raw" ]]; then
			local escaped_msg
			escaped_msg=$(__mcp_sdk_json_escape "Provider failed (exit ${rc}): ${stderr_raw}")
			printf '{"success":false,"error":{"type":"provider_error","message":%s}}' "$escaped_msg"
		else
			printf '{"success":false,"error":{"type":"provider_error","message":"Provider failed with exit code %s"}}' "$rc"
		fi
		;;
	*)
		# Unexpected exit codes
		if [[ -n "$stderr_raw" ]]; then
			local escaped_msg
			escaped_msg=$(__mcp_sdk_json_escape "Unexpected error (exit ${rc}): ${stderr_raw}")
			printf '{"success":false,"error":{"type":"provider_error","message":%s}}' "$escaped_msg"
		else
			printf '{"success":false,"error":{"type":"provider_error","message":"Unexpected error with exit code %s"}}' "$rc"
		fi
		;;
	esac

	return 0
}

# Fail-fast download wrapper -----------------------------------------------------
#
# mcp_download_safe_or_fail --url <url> --out <path> [--allow <host>]... [options]
#
# Downloads file or fails the tool with -32602 (InvalidParams).
# Returns the output path on success.
#
# Use mcp_download_safe directly if you need custom error handling.

mcp_download_safe_or_fail() {
	local result
	result=$(mcp_download_safe "$@")

	# Handle minimal mode (no jq available)
	if [[ "${MCPBASH_MODE:-full}" = "minimal" ]] || [[ -z "${MCPBASH_JSON_TOOL_BIN:-}" ]]; then
		# Best-effort pattern matching - anchor to start of JSON for robustness
		# (avoids false positive if path/message somehow contained '"success":true')
		if [[ "$result" == '{"success":true,'* ]]; then
			# Extract path with sed (fragile but best-effort for minimal mode)
			# KNOWN LIMITATION: This pattern fails if path contains escaped quotes (e.g., /tmp/foo\"bar)
			# This is rare and acceptable for minimal mode; use full mode for edge cases.
			printf '%s' "${result}" | sed -n 's/.*"path":"\([^"]*\)".*/\1/p'
			return 0
		fi
		mcp_fail_invalid_args "Download failed (minimal mode - cannot parse error details)"
	fi

	# Full mode: parse with jq (single call for efficiency)
	# Uses @tsv (tab-separated values) format which is safer than trying to parse JSON in bash
	# CRITICAL: Sanitize tabs AND newlines in BOTH error message AND path to prevent TSV parsing issues
	# - Tabs would break IFS=$'\t' read (tabs are our field delimiter!)
	# - Newlines would cause read to only get first line
	local parsed
	parsed=$(printf '%s' "$result" | "${MCPBASH_JSON_TOOL_BIN}" -r '
		[.success // false, .error.type // "unknown", ((.error.message // "Download failed") | gsub("[\t\n]"; " ")), ((.path // "") | gsub("[\t\n]"; " "))] | @tsv
	')

	local success err_type err_msg path
	IFS=$'\t' read -r success err_type err_msg path <<<"$parsed"

	if [[ "$success" != "true" ]]; then
		mcp_fail_invalid_args "Download failed (${err_type}): ${err_msg}"
	fi

	# Return the path using printf (not echo) to handle paths with -n, -e, or backslashes
	printf '%s' "$path"
}
