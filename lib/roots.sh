#!/usr/bin/env bash
# Roots state tracking and helpers.
# Follows MCP roots/list flow with client-provided roots, env/config fallbacks,
# and normalization to canonical local paths.

set -euo pipefail

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
MCPBASH_CLIENT_SUPPORTS_ROOTS=0
MCPBASH_CLIENT_SUPPORTS_ROOTS_LIST_CHANGED=0

# Tunables
MCPBASH_ROOTS_DEBOUNCE_INTERVAL="${MCPBASH_ROOTS_DEBOUNCE_INTERVAL:-1}"
MCPBASH_ROOTS_REQUEST_TIMEOUT="${MCPBASH_ROOTS_REQUEST_TIMEOUT:-5}"

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
			MCPBASH_CLIENT_SUPPORTS_ROOTS_LIST_CHANGED=1
		fi
	fi
}

mcp_roots_clear() {
	MCPBASH_ROOTS_URIS=()
	MCPBASH_ROOTS_NAMES=()
	MCPBASH_ROOTS_PATHS=()
}

mcp_roots_load_all_fallbacks() {
	mcp_roots_clear
	mcp_roots_load_from_env
	if [ "${#MCPBASH_ROOTS_PATHS[@]}" -eq 0 ]; then
		mcp_roots_load_fallback
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
}

mcp_roots_init_after_initialized() {
	if [ "${MCPBASH_CLIENT_SUPPORTS_ROOTS}" = "1" ]; then
		mcp_roots_request_from_client
	else
		mcp_roots_load_all_fallbacks
		MCPBASH_ROOTS_READY=1
	fi
}

mcp_roots_request_from_client() {
	# If client does not support roots, fall back immediately.
	if [ "${MCPBASH_CLIENT_SUPPORTS_ROOTS}" != "1" ]; then
		mcp_roots_load_all_fallbacks
		MCPBASH_ROOTS_READY=1
		return 0
	fi

	# Debounce rapid notifications.
	local now
	now="$(date +%s)"
	if (( now - MCPBASH_ROOTS_LAST_REQUEST_TIME < MCPBASH_ROOTS_DEBOUNCE_INTERVAL )); then
		mcp_logging_debug "${MCP_ROOTS_LOGGER}" "Debouncing roots/list request"
		return 0
	fi
	MCPBASH_ROOTS_LAST_REQUEST_TIME="${now}"

	if [ "${MCPBASH_ROOTS_PENDING_REQUEST}" = "1" ]; then
		mcp_logging_debug "${MCP_ROOTS_LOGGER}" "roots/list request already pending"
		return 0
	fi

	# Clear current roots so tools block until refresh completes.
	MCPBASH_ROOTS_READY=0
	mcp_roots_clear

	MCPBASH_ROOTS_PENDING_REQUEST=1
	(( MCPBASH_ROOTS_GENERATION++ )) || true
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
		mcp_logging_warning "${MCP_ROOTS_LOGGER}" "roots/list timed out after ${MCPBASH_ROOTS_REQUEST_TIMEOUT}s"
		MCPBASH_ROOTS_PENDING_REQUEST=0
		MCPBASH_ROOTS_PENDING_REQUEST_ID=""
		mcp_rpc_cancel_pending "${request_id}"
		mcp_roots_load_all_fallbacks
		MCPBASH_ROOTS_READY=1
	fi
}

mcp_roots_handle_list_response() {
	local json_payload="$1"
	local expected_generation="${2:-}"

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
		mcp_roots_load_all_fallbacks
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
		mcp_roots_load_all_fallbacks
		MCPBASH_ROOTS_READY=1
		return 0
	fi

	mcp_roots_clear
	mcp_roots_parse_response "${result}"
	MCPBASH_ROOTS_READY=1
}

mcp_roots_normalize_path() {
	local path="$1"
	local canonical

	if ! canonical="$(realpath -m "${path}" 2>/dev/null)"; then
		if ! canonical="$(realpath "${path}" 2>/dev/null)"; then
			if [[ "${path}" != /* ]]; then
				canonical="$(pwd)/${path}"
			else
				canonical="${path}"
			fi
		fi
	fi

	if [[ "${canonical}" != "/" ]]; then
		canonical="${canonical%/}"
	fi

	printf '%s' "${canonical}"
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
	while (( i < len )); do
		local char="${path:i:1}"
		if [[ "${char}" == "%" ]] && (( i + 2 < len )); then
			local hex="${path:i+1:2}"
			if [[ "${hex}" =~ ^[0-9A-Fa-f]{2}$ ]]; then
				decoded+="$(printf "\\x${hex}")"
				(( i += 3 ))
				continue
			fi
		fi
		decoded+="${char}"
		(( i++ ))
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
	while IFS=$'\t' read -r uri name || [ -n "${uri}" ]; do
		[ -n "${uri}" ] || continue
		local path
		if ! path="$(mcp_roots_uri_to_path "${uri}")"; then
			continue
		fi
		path="$(mcp_roots_normalize_path "${path}")"
		if [ -z "${path}" ]; then
			continue
		fi
		case "${seen_paths}" in
		*$'\n'"${path}"$'\n'*) continue ;;
		esac
		seen_paths="${seen_paths}${path}"$'\n'
		MCPBASH_ROOTS_URIS+=("${uri}")
		MCPBASH_ROOTS_NAMES+=("${name}")
		MCPBASH_ROOTS_PATHS+=("${path}")
	done <<<"${entries}"$'\n'
}

mcp_roots_load_from_env() {
	local raw="${MCPBASH_ROOTS:-}"
	[ -n "${raw}" ] || return 0
	local IFS=':'
	local entry
	for entry in ${raw}; do
		[ -n "${entry}" ] || continue
		local path
		path="$(mcp_roots_normalize_path "${entry}")"
		if [ -z "${path}" ]; then
			continue
		fi
		MCPBASH_ROOTS_URIS+=("file://${path}")
		MCPBASH_ROOTS_NAMES+=("")
		MCPBASH_ROOTS_PATHS+=("${path}")
	done
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
	if ! entries="$(cat "${config}" | "${MCPBASH_JSON_TOOL_BIN}" -r '
		.roots // [] |
		map(select((.path // "") != "")) |
		map("\(.path // "")\t\(.name // "")") |
		.[]')" 2>/dev/null; then
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
		abs="$(mcp_roots_normalize_path "${abs}")"
		if [ -z "${abs}" ]; then
			continue
		fi
		case "${seen}" in
		*$'\n'"${abs}"$'\n'*) continue ;;
		esac
		seen="${seen}${abs}"$'\n'
		MCPBASH_ROOTS_URIS+=("file://${abs}")
		MCPBASH_ROOTS_NAMES+=("${name}")
		MCPBASH_ROOTS_PATHS+=("${abs}")
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

	local payload=""
	local entries=()
	local i
	for i in "${!MCPBASH_ROOTS_PATHS[@]}"; do
		entries+=("$(printf '{"uri":%s,"name":%s,"path":%s}' \
			"$(mcp_json_escape_string "${MCPBASH_ROOTS_URIS[$i]}")" \
			"$(mcp_json_escape_string "${MCPBASH_ROOTS_NAMES[$i]}")" \
			"$(mcp_json_escape_string "${MCPBASH_ROOTS_PATHS[$i]}")")")
	done
	printf '[%s]' "$(IFS=,; printf '%s' "${entries[*]}")"
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
		if (( now - start >= timeout )); then
			mcp_logging_warning "${MCP_ROOTS_LOGGER}" "Timeout waiting for roots; loading fallback"
			if [ "${MCPBASH_ROOTS_PENDING_REQUEST}" = "1" ]; then
				if [ -n "${MCPBASH_ROOTS_PENDING_REQUEST_ID}" ]; then
					mcp_rpc_cancel_pending "${MCPBASH_ROOTS_PENDING_REQUEST_ID}"
				fi
				MCPBASH_ROOTS_PENDING_REQUEST=0
				MCPBASH_ROOTS_PENDING_REQUEST_ID=""
				(( MCPBASH_ROOTS_GENERATION++ )) || true
			fi
			mcp_roots_load_all_fallbacks
			MCPBASH_ROOTS_READY=1
			return 0
		fi
		sleep 0.1
	done
}
