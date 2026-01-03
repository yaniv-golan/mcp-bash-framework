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
	if command -v "${MCPBASH_JSON_TOOL_BIN:-}" >/dev/null 2>&1; then
		printf '%s' "${payload}" | "${MCPBASH_JSON_TOOL_BIN}" -rc "${filter}" 2>/dev/null || rc=$?
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
		# Run command and capture exit code
		set +e
		"$@"
		local exit_code=$?
		set -e

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
