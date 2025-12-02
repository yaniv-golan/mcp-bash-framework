#!/usr/bin/env bash
# Ensure single-line JSON emission with stdout discipline.

set -euo pipefail

# Track outgoing requests awaiting responses using files for Bash 3.2 compatibility
MCPBASH_NEXT_OUTGOING_ID="${MCPBASH_NEXT_OUTGOING_ID:-1}"

mcp_rpc_pending_path() {
	local request_id="$1"
	printf '%s/pending.%s.path' "${MCPBASH_STATE_DIR}" "${request_id}"
}

mcp_rpc_callback_path() {
	local request_id="$1"
	printf '%s/pending.%s.cb' "${MCPBASH_STATE_DIR}" "${request_id}"
}

mcp_rpc_next_outgoing_id() {
	local id="${MCPBASH_NEXT_OUTGOING_ID}"
	MCPBASH_NEXT_OUTGOING_ID=$((MCPBASH_NEXT_OUTGOING_ID + 1))
	printf '%s' "${id}"
}

mcp_rpc_register_pending() {
	local request_id="$1"
	local response_file="$2"
	printf '%s' "${response_file}" >"$(mcp_rpc_pending_path "${request_id}")"
}

mcp_rpc_register_callback() {
	local request_id="$1"
	local callback="$2"
	local generation="${3:-0}"
	printf '%s %s' "${callback}" "${generation}" >"$(mcp_rpc_callback_path "${request_id}")"
}

mcp_rpc_unregister_pending() {
	local request_id="$1"
	rm -f "$(mcp_rpc_pending_path "${request_id}")"
}

mcp_rpc_cancel_pending() {
	local request_id="$1"
	rm -f "$(mcp_rpc_pending_path "${request_id}")" 2>/dev/null || true
	rm -f "$(mcp_rpc_callback_path "${request_id}")" 2>/dev/null || true
}

mcp_rpc_handle_response() {
	local json_payload="$1"
	local id
	id="$(mcp_json_extract_id "${json_payload}")"

	# Callback-based responses (e.g., roots/list)
	local callback_file
	callback_file="$(mcp_rpc_callback_path "${id}")"
	if [ -f "${callback_file}" ]; then
		local callback generation
		callback="$(cut -d' ' -f1 <"${callback_file}" 2>/dev/null || true)"
		generation="$(cut -d' ' -f2 <"${callback_file}" 2>/dev/null || true)"
		rm -f "${callback_file}"

		if [ -z "${callback}" ]; then
			return 1
		fi

		if [ -n "${generation}" ] && [ "${generation}" != "0" ] && [ -n "${MCPBASH_ROOTS_GENERATION:-}" ] && [ "${generation}" != "${MCPBASH_ROOTS_GENERATION}" ]; then
			mcp_logging_debug "mcp.rpc" "Discarding stale response (gen ${generation}, current ${MCPBASH_ROOTS_GENERATION:-0})"
			return 0
		fi

		"${callback}" "${json_payload}" "${generation}"
		return 0
	fi

	local response_file
	response_file="$(cat "$(mcp_rpc_pending_path "${id}")" 2>/dev/null || true)"
	if [ -z "${response_file}" ]; then
		mcp_logging_warning "mcp.rpc" "Received response for unknown request id=${id}"
		return 1
	fi

	rm -f "$(mcp_rpc_pending_path "${id}")"

	# Clear worker mapping if available (elicitation)
	if declare -F mcp_elicitation_clear_request_id >/dev/null 2>&1; then
		mcp_elicitation_clear_request_id "${id}"
	fi

	local normalized
	if mcp_json_has_key "${json_payload}" "error"; then
		local error_code error_message
		error_code="$(printf '%s' "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.error.code // -32603' 2>/dev/null || printf '%s' "-32603")"
		error_message="$(printf '%s' "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.error.message // "Unknown error"' 2>/dev/null || printf '%s' "Unknown error")"
		mcp_logging_warning "mcp.elicitation" "Client error: code=${error_code} message=${error_message}"
		normalized='{"action":"error","content":null}'
	else
		local action content action_json
		action="$(printf '%s' "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.result.action // "error"' 2>/dev/null || printf '%s' "error")"
		content="$(printf '%s' "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.result.content // null' 2>/dev/null || printf 'null')"
		action_json="$(mcp_json_quote_text "${action}")"
		normalized="$(printf '{"action":%s,"content":%s}' "${action_json}" "${content}")"
	fi

	printf '%s' "${normalized}" >"${response_file}"
	return 0
}

rpc_send_line() {
	local payload="$1"
	mcp_io_send_line "${payload}"
}

rpc_send_line_direct() {
	local payload="$1"
	if [ -z "${payload}" ]; then
		return 0
	fi
	if [ -z "${MCPBASH_DIRECT_FD:-}" ]; then
		rpc_send_line "${payload}"
		return 0
	fi
	(
		exec 1>&"${MCPBASH_DIRECT_FD}"
		rpc_send_line "${payload}"
	)
}
