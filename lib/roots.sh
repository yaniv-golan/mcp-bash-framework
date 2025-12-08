#!/usr/bin/env bash
# Roots state tracking and helpers.
# Follows MCP roots/list flow with client-provided roots, env/config fallbacks,
# and normalization to canonical local paths.

set -euo pipefail

if ! command -v mcp_path_normalize >/dev/null 2>&1; then
	# shellcheck source=lib/path.sh disable=SC1090,SC1091
	. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/path.sh"
fi

MCP_ROOTS_LOGGER="${MCP_ROOTS_LOGGER:-mcp.roots}"

# Avoid Bash 4-only declare -g for macOS /bin/bash 3.2 compatibility.
MCPBASH_ROOTS_URIS=()
MCPBASH_ROOTS_NAMES=()
MCPBASH_ROOTS_PATHS=()
MCPBASH_ROOTS_READY=0
MCPBASH_ROOTS_PENDING_REQUEST=0
MCPBASH_ROOTS_PENDING_REQUEST_ID=""
MCPBASH_ROOTS_GENERATION=0
MCPBASH_ROOTS_LAST_REQUEST_TIME=0
# shellcheck disable=SC2034  # Consumed by lifecycle handler for logging and feature gating
MCPBASH_CLIENT_SUPPORTS_ROOTS=0
MCPBASH_CLIENT_SUPPORTS_ROOTS_LIST_CHANGED=0

# Tunables
MCPBASH_ROOTS_DEBOUNCE_INTERVAL="${MCPBASH_ROOTS_DEBOUNCE_INTERVAL:-1}"
MCPBASH_ROOTS_REQUEST_TIMEOUT="${MCPBASH_ROOTS_REQUEST_TIMEOUT:-5}"

mcp_roots_log_path_issue() {
	local level="$1"
	local source="$2"
	local message="$3"
	if command -v mcp_logging_emit >/dev/null 2>&1; then
		case "${level}" in
		error) mcp_logging_error "${MCP_ROOTS_LOGGER}" "${source}: ${message}" ;;
		warning) mcp_logging_warning "${MCP_ROOTS_LOGGER}" "${source}: ${message}" ;;
		info) mcp_logging_info "${MCP_ROOTS_LOGGER}" "${source}: ${message}" ;;
		debug) mcp_logging_debug "${MCP_ROOTS_LOGGER}" "${source}: ${message}" ;;
		*) mcp_logging_warning "${MCP_ROOTS_LOGGER}" "${source}: ${message}" ;;
		esac
	else
		printf '%s: %s\n' "${source}" "${message}" >&2
	fi
}

mcp_roots_canonicalize_checked() {
	local raw="$1"
	local source="$2"
	local strict="${3:-0}"
	local level="warning"
	if [ "${strict}" = "1" ]; then
		level="error"
	fi

	# Basic ~ expansion; we avoid eval for safety.
	if [[ "${raw}" == "~"* ]]; then
		raw="${raw/#~/${HOME:-~}}"
	fi

	local normalized
	normalized="$(mcp_roots_normalize_path "${raw}")"
	if [ -z "${normalized}" ]; then
		mcp_roots_log_path_issue "${level}" "${source}" "unable to normalize path '${raw}'"
		return 1
	fi

	if [ ! -e "${normalized}" ]; then
		mcp_roots_log_path_issue "${level}" "${source}" "path does not exist: ${normalized}"
		return 1
	fi

	if [ ! -r "${normalized}" ]; then
		mcp_roots_log_path_issue "${level}" "${source}" "path not readable: ${normalized}"
		return 1
	fi

	printf '%s' "${normalized}"
	return 0
}

mcp_roots_append_unique() {
	local path="$1"
	local name="$2"

	local existing
	for existing in "${MCPBASH_ROOTS_PATHS[@]}"; do
		if [ "${existing}" = "${path}" ]; then
			return 0
		fi
	done

	MCPBASH_ROOTS_PATHS+=("${path}")
	MCPBASH_ROOTS_URIS+=("file://${path}")
	MCPBASH_ROOTS_NAMES+=("${name}")
}

mcp_roots_capture_capabilities() {
	local client_caps_json="$1"
	MCPBASH_CLIENT_SUPPORTS_ROOTS=0
	MCPBASH_CLIENT_SUPPORTS_ROOTS_LIST_CHANGED=0
	if [ -z "${client_caps_json}" ] || [ "${client_caps_json}" = "null" ]; then
		return 0
	fi
	if [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
		if printf '%s' "${client_caps_json}" | "${MCPBASH_JSON_TOOL_BIN}" -e '.roots? // empty' >/dev/null 2>&1; then
			MCPBASH_CLIENT_SUPPORTS_ROOTS=1
		fi
		if printf '%s' "${client_caps_json}" | "${MCPBASH_JSON_TOOL_BIN}" -e '.roots.listChanged == true' >/dev/null 2>&1; then
			# shellcheck disable=SC2034
			MCPBASH_CLIENT_SUPPORTS_ROOTS_LIST_CHANGED=1
		fi
	fi
}

mcp_roots_clear() {
	MCPBASH_ROOTS_URIS=()
	MCPBASH_ROOTS_NAMES=()
	MCPBASH_ROOTS_PATHS=()
}

mcp_roots_add_default_project_root() {
	if [ -z "${MCPBASH_PROJECT_ROOT:-}" ]; then
		return 0
	fi
	local abs
	if ! abs="$(mcp_roots_canonicalize_checked "${MCPBASH_PROJECT_ROOT}" "project root" 1)"; then
		return 1
	fi
	mcp_roots_append_unique "${abs}" ""
}

mcp_roots_load_all_fallbacks() {
	mcp_roots_clear
	local had_error=0
	if ! mcp_roots_load_from_env; then
		had_error=1
	fi
	if [ "${#MCPBASH_ROOTS_PATHS[@]}" -eq 0 ]; then
		mcp_roots_load_fallback
	fi
	if [ "${#MCPBASH_ROOTS_PATHS[@]}" -eq 0 ]; then
		mcp_roots_add_default_project_root || had_error=1
	fi
	# Debug dump to state dir if available
	if [ -n "${MCPBASH_STATE_DIR:-}" ]; then
		{
			local i
			for i in "${!MCPBASH_ROOTS_PATHS[@]}"; do
				printf '%s|%s|%s\n' "${MCPBASH_ROOTS_URIS[$i]:-}" "${MCPBASH_ROOTS_NAMES[$i]:-}" "${MCPBASH_ROOTS_PATHS[$i]:-}"
			done
		} >"${MCPBASH_STATE_DIR}/roots.debug" 2>/dev/null || true
	fi
	return "${had_error}"
}

mcp_roots_init_after_initialized() {
	mcp_roots_load_all_fallbacks || true
	MCPBASH_ROOTS_READY=1
	if [ "${MCPBASH_CLIENT_SUPPORTS_ROOTS}" = "1" ]; then
		mcp_roots_request_from_client
	fi
}

mcp_roots_request_from_client() {
	# If client does not support roots, fall back immediately.
	if [ "${MCPBASH_CLIENT_SUPPORTS_ROOTS}" != "1" ]; then
		return 0
	fi

	# Debounce rapid notifications.
	local now
	now="$(date +%s)"
	if ((now - MCPBASH_ROOTS_LAST_REQUEST_TIME < MCPBASH_ROOTS_DEBOUNCE_INTERVAL)); then
		mcp_logging_debug "${MCP_ROOTS_LOGGER}" "Debouncing roots/list request"
		return 0
	fi
	MCPBASH_ROOTS_LAST_REQUEST_TIME="${now}"

	if [ "${MCPBASH_ROOTS_PENDING_REQUEST}" = "1" ]; then
		mcp_logging_debug "${MCP_ROOTS_LOGGER}" "roots/list request already pending"
		return 0
	fi

	MCPBASH_ROOTS_PENDING_REQUEST=1
	((MCPBASH_ROOTS_GENERATION++)) || true
	local current_generation="${MCPBASH_ROOTS_GENERATION}"

	local request_id
	request_id="$(mcp_rpc_next_outgoing_id)"
	MCPBASH_ROOTS_PENDING_REQUEST_ID="${request_id}"

	local id_json
	if printf '%s' "${request_id}" | LC_ALL=C grep -Eq '^-?[0-9]+$'; then
		id_json="${request_id}"
	else
		id_json="$(mcp_json_escape_string "${request_id}")"
	fi

	# Use direct send to bypass handler stdout capture.
	rpc_send_line_direct '{"jsonrpc":"2.0","id":'"${id_json}"',"method":"roots/list"}'

	# Register callback; include generation so handler can drop stale responses.
	mcp_rpc_register_callback "${request_id}" "mcp_roots_handle_list_response" "${current_generation}"
	mcp_roots_start_timeout_watchdog "${request_id}" "${current_generation}" &
}

mcp_roots_start_timeout_watchdog() {
	local request_id="$1"
	local expected_generation="$2"
	sleep "${MCPBASH_ROOTS_REQUEST_TIMEOUT}"

	if [ "${expected_generation}" != "${MCPBASH_ROOTS_GENERATION}" ]; then
		return 0
	fi

	if [ "${MCPBASH_ROOTS_PENDING_REQUEST}" = "1" ]; then
		mcp_logging_debug "${MCP_ROOTS_LOGGER}" "roots/list timed out after ${MCPBASH_ROOTS_REQUEST_TIMEOUT}s; keeping existing roots"
		MCPBASH_ROOTS_PENDING_REQUEST=0
		MCPBASH_ROOTS_PENDING_REQUEST_ID=""
		mcp_rpc_cancel_pending "${request_id}"
	fi
}

mcp_roots_handle_list_response() {
	local json_payload="$1"
	local expected_generation="${2:-}"
	local prev_paths=("${MCPBASH_ROOTS_PATHS[@]}")
	local prev_uris=("${MCPBASH_ROOTS_URIS[@]}")
	local prev_names=("${MCPBASH_ROOTS_NAMES[@]}")

	if [ -n "${expected_generation}" ] && [ "${expected_generation}" != "${MCPBASH_ROOTS_GENERATION}" ]; then
		mcp_logging_debug "${MCP_ROOTS_LOGGER}" "Stale roots/list response discarded (gen ${expected_generation}, current ${MCPBASH_ROOTS_GENERATION})"
		return 0
	fi

	MCPBASH_ROOTS_PENDING_REQUEST=0
	MCPBASH_ROOTS_PENDING_REQUEST_ID=""

	if mcp_json_has_key "${json_payload}" "error"; then
		local code msg
		if [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
			code="$(printf '%s' "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.error.code // -32603' 2>/dev/null || printf '%s' "-32603")"
			msg="$(printf '%s' "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.error.message // "Unknown error"' 2>/dev/null || printf '%s' "Unknown error")"
		else
			code="-32603"
			msg="Unknown error"
		fi
		mcp_logging_warning "${MCP_ROOTS_LOGGER}" "roots/list failed: code=${code} message=${msg}"
		MCPBASH_ROOTS_READY=1
		return 0
	fi

	local result
	if [ "${MCPBASH_JSON_TOOL:-none}" != "none" ]; then
		result="$(printf '%s' "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.result // null' 2>/dev/null || printf 'null')"
	else
		result="null"
	fi
	if [ -z "${result}" ] || [ "${result}" = "null" ]; then
		mcp_logging_warning "${MCP_ROOTS_LOGGER}" "roots/list response missing result"
		MCPBASH_ROOTS_READY=1
		return 0
	fi

	if ! mcp_roots_parse_response "${result}"; then
		MCPBASH_ROOTS_PATHS=("${prev_paths[@]}")
		MCPBASH_ROOTS_URIS=("${prev_uris[@]}")
		MCPBASH_ROOTS_NAMES=("${prev_names[@]}")
	fi
	MCPBASH_ROOTS_READY=1
}

mcp_roots_normalize_path() {
	local path="$1"
	printf '%s' "$(mcp_path_normalize --physical "${path}")"
}

mcp_roots_uri_to_path() {
	local uri="$1"

	local lower_uri
	lower_uri="$(printf '%s' "${uri}" | tr '[:upper:]' '[:lower:]')"
	if [[ "${lower_uri}" != file://* ]]; then
		# Avoid leaking full URI in non-verbose mode.
		if mcp_logging_verbose_enabled; then
			mcp_logging_warning "${MCP_ROOTS_LOGGER}" "Unsupported URI scheme: ${uri}"
		else
			mcp_logging_warning "${MCP_ROOTS_LOGGER}" "Unsupported URI scheme"
		fi
		return 1
	fi

	local after_scheme_lower="${lower_uri#file://}"
	local path=""
	local authority=""

	if [[ "${after_scheme_lower}" == /* ]]; then
		authority=""
		path="${uri:7}"
	elif [[ "${after_scheme_lower}" == */* ]]; then
		authority="${after_scheme_lower%%/*}"
		local authority_len="${#authority}"
		path="${uri:$((7 + authority_len))}"
	else
		if mcp_logging_verbose_enabled; then
			mcp_logging_warning "${MCP_ROOTS_LOGGER}" "Malformed file URI (no path): ${uri}"
		else
			mcp_logging_warning "${MCP_ROOTS_LOGGER}" "Malformed file URI (no path)"
		fi
		return 1
	fi

	if [[ -n "${authority}" && "${authority}" != "localhost" ]]; then
		if mcp_logging_verbose_enabled; then
			mcp_logging_warning "${MCP_ROOTS_LOGGER}" "Rejecting non-local file URI authority=${authority}: ${uri}"
		else
			mcp_logging_warning "${MCP_ROOTS_LOGGER}" "Rejecting non-local file URI authority"
		fi
		return 1
	fi

	if [[ "${path}" != /* ]]; then
		if mcp_logging_verbose_enabled; then
			mcp_logging_warning "${MCP_ROOTS_LOGGER}" "Rejecting file URI with relative path: ${uri}"
		else
			mcp_logging_warning "${MCP_ROOTS_LOGGER}" "Rejecting file URI with relative path"
		fi
		return 1
	fi

	# Percent-decode path
	local decoded=""
	local i=0 len=${#path}
	while ((i < len)); do
		local char="${path:i:1}"
		if [[ "${char}" == "%" ]] && ((i + 2 < len)); then
			local hex="${path:i+1:2}"
			if [[ "${hex}" =~ ^[0-9A-Fa-f]{2}$ ]]; then
				decoded+="$(printf '%b' "\\x${hex}")"
				((i += 3))
				continue
			fi
		fi
		decoded+="${char}"
		((i++))
	done

	if [[ "${decoded}" != /* ]]; then
		mcp_logging_warning "${MCP_ROOTS_LOGGER}" "Decoded file URI not absolute"
		return 1
	fi

	printf '%s' "${decoded}"
}

mcp_roots_parse_response() {
	local result_json="$1"

	if [ "${MCPBASH_JSON_TOOL:-none}" = "none" ]; then
		mcp_logging_warning "${MCP_ROOTS_LOGGER}" "JSON tool unavailable; cannot parse roots"
		return 1
	fi

	local entries
	if ! entries="$(printf '%s' "${result_json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.roots[]? | "\(.uri // "")\t\(.name // "")"' 2>/dev/null)"; then
		mcp_logging_warning "${MCP_ROOTS_LOGGER}" "Unable to parse roots/list result"
		return 1
	fi

	local seen_paths=$'\n'
	local -a new_uris=()
	local -a new_names=()
	local -a new_paths=()

	while IFS=$'\t' read -r uri name || [ -n "${uri}" ]; do
		[ -n "${uri}" ] || continue
		local path
		if ! path="$(mcp_roots_uri_to_path "${uri}")"; then
			continue
		fi
		if ! path="$(mcp_roots_canonicalize_checked "${path}" "client roots" 0)"; then
			continue
		fi
		case "${seen_paths}" in
		*$'\n'"${path}"$'\n'*) continue ;;
		esac
		seen_paths="${seen_paths}${path}"$'\n'
		new_uris+=("${uri}")
		new_names+=("${name}")
		new_paths+=("${path}")
	done <<<"${entries}"$'\n'

	MCPBASH_ROOTS_URIS=("${new_uris[@]}")
	MCPBASH_ROOTS_NAMES=("${new_names[@]}")
	MCPBASH_ROOTS_PATHS=("${new_paths[@]}")
}

mcp_roots_load_from_env() {
	local raw="${MCPBASH_ROOTS:-}"
	[ -n "${raw}" ] || return 0
	local had_error=0
	local IFS=':'
	local entry
	for entry in ${raw}; do
		[ -n "${entry}" ] || continue
		local path
		if ! path="$(mcp_roots_canonicalize_checked "${entry}" "MCPBASH_ROOTS" 1)"; then
			had_error=1
			continue
		fi
		mcp_roots_append_unique "${path}" ""
	done
	return "${had_error}"
}

mcp_roots_load_fallback() {
	local config="${MCPBASH_PROJECT_ROOT}/config/roots.json"
	if [ ! -f "${config}" ]; then
		return 0
	fi

	if [ "${MCPBASH_JSON_TOOL:-none}" = "none" ]; then
		mcp_logging_warning "${MCP_ROOTS_LOGGER}" "JSON tool unavailable; cannot load fallback roots"
		return 0
	fi

	local entries
	if ! entries="$("${MCPBASH_JSON_TOOL_BIN}" -r '
		.roots // [] |
		map(select((.path // "") != "")) |
		map("\(.path // "")\t\(.name // "")") |
		.[]' <"${config}")" 2>/dev/null; then
		mcp_logging_warning "${MCP_ROOTS_LOGGER}" "Invalid fallback config at ${config}"
		return 0
	fi

	local seen=$'\n'
	while IFS=$'\t' read -r path_raw name || [ -n "${path_raw}" ]; do
		[ -n "${path_raw}" ] || continue
		local abs="${path_raw}"
		if [[ "${abs}" != /* ]]; then
			abs="${MCPBASH_PROJECT_ROOT%/}/${abs}"
		fi
		if ! abs="$(mcp_roots_canonicalize_checked "${abs}" "config/roots.json" 0)"; then
			continue
		fi
		case "${seen}" in
		*$'\n'"${abs}"$'\n'*) continue ;;
		esac
		seen="${seen}${abs}"$'\n'
		mcp_roots_append_unique "${abs}" "${name}"
	done <<<"${entries}"$'\n'
}

mcp_roots_get_paths() {
	local i
	for i in "${!MCPBASH_ROOTS_PATHS[@]}"; do
		printf '%s\n' "${MCPBASH_ROOTS_PATHS[$i]}"
	done
}

mcp_roots_get_json() {
	if [ "${#MCPBASH_ROOTS_PATHS[@]}" -eq 0 ]; then
		printf '[]'
		return 0
	fi

	if [ "${MCPBASH_JSON_TOOL:-none}" = "none" ]; then
		local i
		printf '['
		for i in "${!MCPBASH_ROOTS_PATHS[@]}"; do
			[ "${i}" -gt 0 ] && printf ','
			printf '{"uri":"%s","name":"%s","path":"%s"}' \
				"${MCPBASH_ROOTS_URIS[$i]//\"/\\\"}" \
				"${MCPBASH_ROOTS_NAMES[$i]//\"/\\\"}" \
				"${MCPBASH_ROOTS_PATHS[$i]//\"/\\\"}"
		done
		printf ']'
		return 0
	fi

	local entries=()
	local i
	for i in "${!MCPBASH_ROOTS_PATHS[@]}"; do
		entries+=("$(printf '{"uri":%s,"name":%s,"path":%s}' \
			"$(mcp_json_escape_string "${MCPBASH_ROOTS_URIS[$i]}")" \
			"$(mcp_json_escape_string "${MCPBASH_ROOTS_NAMES[$i]}")" \
			"$(mcp_json_escape_string "${MCPBASH_ROOTS_PATHS[$i]}")")")
	done
	printf '[%s]' "$(
		IFS=,
		printf '%s' "${entries[*]}"
	)"
}

mcp_roots_contains_path() {
	local path="$1"
	local canonical
	canonical="$(mcp_roots_normalize_path "${path}")"

	local root
	for root in "${MCPBASH_ROOTS_PATHS[@]}"; do
		if [[ "${canonical}" == "${root}" ]] || [[ "${canonical}" == "${root}/"* ]]; then
			return 0
		fi
	done
	return 1
}

mcp_roots_wait_ready() {
	local timeout="${1:-${MCPBASH_ROOTS_REQUEST_TIMEOUT}}"
	local start
	start="$(date +%s)"
	while [ "${MCPBASH_ROOTS_READY}" != "1" ]; do
		local now
		now="$(date +%s)"
		if ((now - start >= timeout)); then
			mcp_logging_debug "${MCP_ROOTS_LOGGER}" "Timeout waiting for roots; using existing roots"
			if [ "${MCPBASH_ROOTS_PENDING_REQUEST}" = "1" ]; then
				if [ -n "${MCPBASH_ROOTS_PENDING_REQUEST_ID}" ]; then
					mcp_rpc_cancel_pending "${MCPBASH_ROOTS_PENDING_REQUEST_ID}"
				fi
				MCPBASH_ROOTS_PENDING_REQUEST=0
				MCPBASH_ROOTS_PENDING_REQUEST_ID=""
				((MCPBASH_ROOTS_GENERATION++)) || true
			fi
			MCPBASH_ROOTS_READY=1
			return 0
		fi
		sleep 0.1
	done
}
