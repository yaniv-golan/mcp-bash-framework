#!/usr/bin/env bash
# Elicitation state, request routing, and worker coordination.

set -euo pipefail

# Track client elicitation capability
MCPBASH_CLIENT_SUPPORTS_ELICITATION="${MCPBASH_CLIENT_SUPPORTS_ELICITATION:-0}"
mcp_elicitation_support_flag_path() {
	printf '%s/elicitation.support' "${MCPBASH_STATE_DIR}"
}

mcp_elicitation_write_support_flag() {
	local value="$1"
	printf '%s' "${value}" >"$(mcp_elicitation_support_flag_path 2>/dev/null)" 2>/dev/null || true
}

mcp_elicitation_init() {
	local client_caps="${1:-{}}"
	MCPBASH_CLIENT_SUPPORTS_ELICITATION=0
	if mcp_json_has_key "${client_caps}" "elicitation"; then
		MCPBASH_CLIENT_SUPPORTS_ELICITATION=1
	else
		# Fallback for environments without JSON tooling: string match
		case "${client_caps}" in
		*\"elicitation\"*) MCPBASH_CLIENT_SUPPORTS_ELICITATION=1 ;;
		esac
	fi
	mcp_elicitation_write_support_flag "${MCPBASH_CLIENT_SUPPORTS_ELICITATION}"
}

mcp_elicitation_is_supported() {
	if [ "${MCPBASH_CLIENT_SUPPORTS_ELICITATION}" = "1" ]; then
		return 0
	fi
	local flag
	flag="$(cat "$(mcp_elicitation_support_flag_path 2>/dev/null)" 2>/dev/null || true)"
	[ "${flag}" = "1" ]
}

mcp_elicitation_clear_request_id() {
	local request_id="$1"
	local id_file
	for id_file in "${MCPBASH_STATE_DIR}"/elicit.*.id; do
		[ -f "${id_file}" ] || continue
		if [ "$(cat "${id_file}")" = "${request_id}" ]; then
			rm -f "${id_file}"
			break
		fi
	done
}

mcp_elicitation_response_path_for_worker() {
	local key="$1"
	printf '%s/elicit.%s.response' "${MCPBASH_STATE_DIR}" "${key}"
}

mcp_elicitation_request_path_for_worker() {
	local key="$1"
	printf '%s/elicit.%s.request' "${MCPBASH_STATE_DIR}" "${key}"
}

mcp_elicitation_request_id_path_for_worker() {
	local key="$1"
	printf '%s/elicit.%s.id' "${MCPBASH_STATE_DIR}" "${key}"
}

mcp_elicitation_request_id_for_worker() {
	local key="$1"
	local path
	path="$(mcp_elicitation_request_id_path_for_worker "${key}")"
	if [ -f "${path}" ]; then
		cat "${path}"
	fi
}

mcp_elicitation_process_requests() {
	local listing key request_file
	listing="$(mcp_ids_list_active_workers 2>/dev/null || true)"
	[ -z "${listing}" ] && return 0

	while IFS= read -r key || [ -n "${key}" ]; do
		[ -z "${key}" ] && continue
		request_file="$(mcp_elicitation_request_path_for_worker "${key}")"
		[ -f "${request_file}" ] || continue
		mcp_elicitation_handle_tool_request "${key}" "${request_file}"
	done <<<"${listing}"
}

mcp_elicitation_handle_tool_request() {
	local key="$1"
	local request_file="$2"
	local response_file
	response_file="$(mcp_elicitation_response_path_for_worker "${key}")"

	local request_json
	# The tool may time out and clean up the request file before the poller can
	# read it (seen intermittently on Windows runners). Handle the race
	# gracefully instead of crashing the server under set -e.
	if [ ! -f "${request_file}" ]; then
		return 0
	fi
	request_json="$(cat "${request_file}" 2>/dev/null || true)"
	if [ -z "${request_json}" ]; then
		rm -f "${request_file}"
		return 0
	fi
	rm -f "${request_file}"

	# If client doesn't support elicitation, respond immediately so tool can proceed
	if ! mcp_elicitation_is_supported; then
		printf '{"action":"decline","content":null}' >"${response_file}"
		return 0
	fi

	local message schema
	message="$(printf '%s' "${request_json}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.message')" || message=""
	schema="$(printf '%s' "${request_json}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.schema')" || schema='{"type":"object","properties":{}}'

	local request_id
	request_id="$(mcp_rpc_next_outgoing_id)"

	local message_json
	message_json="$(mcp_json_quote_text "${message}")"

	local elicit_request
	elicit_request="$(printf '{"jsonrpc":"2.0","id":%s,"method":"elicitation/create","params":{"message":%s,"requestedSchema":%s}}' \
		"${request_id}" "${message_json}" "${schema}")"

	printf '%s' "${request_id}" >"$(mcp_elicitation_request_id_path_for_worker "${key}")"
	mcp_rpc_register_pending "${request_id}" "${response_file}"
	mcp_io_send_line "${elicit_request}"
}

mcp_elicitation_cancel_for_worker() {
	local key="$1"
	[ -n "${key}" ] || return 0
	local request_file
	local response_file
	request_file="$(mcp_elicitation_request_path_for_worker "${key}")"
	response_file="$(mcp_elicitation_response_path_for_worker "${key}")"
	rm -f "${request_file}"
	printf '{"action":"cancel","content":null}' >"${response_file}"

	local request_id
	request_id="$(mcp_elicitation_request_id_for_worker "${key}")"
	if [ -n "${request_id}" ]; then
		mcp_rpc_unregister_pending "${request_id}"
	fi
	rm -f "$(mcp_elicitation_request_id_path_for_worker "${key}")"
}

mcp_elicitation_cleanup_for_worker() {
	local key="$1"
	[ -n "${key}" ] || return 0
	rm -f "$(mcp_elicitation_request_path_for_worker "${key}")" "$(mcp_elicitation_response_path_for_worker "${key}")"
	local request_id
	request_id="$(mcp_elicitation_request_id_for_worker "${key}")"
	if [ -n "${request_id}" ]; then
		mcp_rpc_unregister_pending "${request_id}"
	fi
	rm -f "$(mcp_elicitation_request_id_path_for_worker "${key}")"
}
