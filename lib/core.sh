#!/usr/bin/env bash
# Lifecycle bootstrap, concurrency, cancellation, timeouts, stdout discipline.

set -euo pipefail

MCPBASH_MAIN_PGID=""
MCPBASH_SHUTDOWN_PENDING=false
MCPBASH_NO_RESPONSE="__MCP_NO_RESPONSE__"
MCPBASH_INITIALIZE_HANDSHAKE_DONE=false
MCPBASH_HANDLER_OUTPUT=""
MCPBASH_SHUTDOWN_WATCHDOG_PID=""
MCPBASH_EXIT_REQUESTED=false
MCPBASH_PROGRESS_FLUSHER_PID=""
MCPBASH_RESOURCE_POLL_PID=""

mcp_register_tool() {
	local payload="$1"
	mcp_tools_register_manual "${payload}"
}

mcp_register_resource() {
	local payload="$1"
	mcp_resources_register_manual "${payload}"
}

mcp_register_prompt() {
	local payload="$1"
	mcp_prompts_register_manual "${payload}"
}

mcp_core_run() {
	mcp_core_require_handlers
	mcp_core_bootstrap_state
	mcp_core_read_loop
	mcp_core_wait_for_workers
}

mcp_core_require_handlers() {
	. "${MCPBASH_HOME}/handlers/lifecycle.sh"
	. "${MCPBASH_HOME}/handlers/ping.sh"
	. "${MCPBASH_HOME}/handlers/logging.sh"
	. "${MCPBASH_HOME}/handlers/tools.sh"
	. "${MCPBASH_HOME}/handlers/resources.sh"
	. "${MCPBASH_HOME}/handlers/prompts.sh"
	. "${MCPBASH_HOME}/handlers/completion.sh"
}

mcp_core_bootstrap_state() {
	MCPBASH_INITIALIZED=false
	MCPBASH_SHUTDOWN_PENDING=false
	MCPBASH_INITIALIZE_HANDSHAKE_DONE=false
	mcp_runtime_init_paths
	mcp_ids_init_state
	mcp_lock_init
	mcp_io_init
	mcp_runtime_enable_job_control
	. "${MCPBASH_HOME}/lib/timeout.sh"
	MCPBASH_MAIN_PGID="$(mcp_runtime_lookup_pgid "$$")"
	MCPBASH_MAX_CONCURRENT_REQUESTS="${MCPBASH_MAX_CONCURRENT_REQUESTS:-16}"
	MCPBASH_MAX_TOOL_OUTPUT_SIZE="${MCPBASH_MAX_TOOL_OUTPUT_SIZE:-10485760}"
	MCPBASH_MAX_PROGRESS_PER_MIN="${MCPBASH_MAX_PROGRESS_PER_MIN:-100}"
	MCPBASH_MAX_LOGS_PER_MIN="${MCPBASH_MAX_LOGS_PER_MIN:-${MCPBASH_MAX_PROGRESS_PER_MIN}}"
	MCPBASH_DEFAULT_TOOL_TIMEOUT="${MCPBASH_DEFAULT_TOOL_TIMEOUT:-30}"
	MCPBASH_DEFAULT_SUBSCRIBE_TIMEOUT="${MCPBASH_DEFAULT_SUBSCRIBE_TIMEOUT:-120}"
	MCPBASH_SHUTDOWN_TIMEOUT="${MCPBASH_SHUTDOWN_TIMEOUT:-5}"
	MCPBASH_SHUTDOWN_TIMER_STARTED=false
	MCPBASH_RESOURCE_POLL_PID=""

	# setup SDK notification streams
	MCP_PROGRESS_STREAM="${MCPBASH_STATE_DIR}/progress.ndjson"
	MCP_LOG_STREAM="${MCPBASH_STATE_DIR}/logs.ndjson"
	: >"${MCP_PROGRESS_STREAM}"
	: >"${MCP_LOG_STREAM}"
	mcp_core_start_progress_flusher
	mcp_core_start_resource_poll
}

mcp_core_read_loop() {
	local line
	while IFS= read -r line; do
		mcp_core_handle_line "${line}"
	done
}

mcp_core_wait_for_workers() {
	local pid
	local exit_code
	local pids

	pids="$(mcp_core_list_worker_pids)"
	if [ -z "${pids}" ]; then
		return 0
	fi

	for pid in ${pids}; do
		if ! wait "${pid}"; then
			exit_code=$?
			printf '%s\n' "mcp-bash: background worker ${pid} exited with status ${exit_code}" >&2
		fi
	done
}

mcp_core_list_worker_pids() {
	local pids filtered pid
	pids="$(jobs -p 2>/dev/null || true)"
	if [ -z "${pids}" ]; then
		printf ''
		return 0
	fi
	filtered=""
	for pid in ${pids}; do
		if [ -n "${MCPBASH_PROGRESS_FLUSHER_PID:-}" ] && [ "${pid}" = "${MCPBASH_PROGRESS_FLUSHER_PID}" ]; then
			continue
		fi
		if [ -n "${MCPBASH_RESOURCE_POLL_PID:-}" ] && [ "${pid}" = "${MCPBASH_RESOURCE_POLL_PID}" ]; then
			continue
		fi
		if [ -z "${filtered}" ]; then
			filtered="${pid}"
		else
			filtered="${filtered}"$'\n'"${pid}"
		fi
	done
	printf '%s' "${filtered}"
}

mcp_core_wait_for_one_worker() {
	local pids pid status
	while :; do
		pids="$(mcp_core_list_worker_pids)"
		if [ -z "${pids}" ]; then
			sleep 0.01
			return 0
		fi
		for pid in ${pids}; do
			if ! kill -0 "${pid}" 2>/dev/null; then
				if ! wait "${pid}"; then
					status=$?
					printf '%s\n' "mcp-bash: background worker ${pid} exited with status ${status}" >&2
				fi
				return 0
			fi
		done
		sleep 0.01
	done
}

mcp_core_active_worker_count() {
	local pids
	pids="$(mcp_core_list_worker_pids)"
	if [ -z "${pids}" ]; then
		printf '0'
		return 0
	fi
	printf '%s' "$(printf '%s\n' "${pids}" | wc -l | tr -d ' ')"
}

mcp_core_wait_for_available_slot() {
	local max="${MCPBASH_MAX_CONCURRENT_REQUESTS:-16}"
	local active
	case "${max}" in
	'' | *[!0-9]*) max=16 ;;
	0) max=1 ;;
	esac
	while :; do
		active="$(mcp_core_active_worker_count)"
		if [ "${active}" -lt "${max}" ]; then
			break
		fi
		mcp_core_wait_for_one_worker
	done
}

mcp_core_start_shutdown_watchdog() {
	local timeout="${MCPBASH_SHUTDOWN_TIMEOUT:-5}"
	case "${timeout}" in
	'' | *[!0-9]*) timeout=5 ;;
	esac
	if [ -n "${MCPBASH_SHUTDOWN_WATCHDOG_PID}" ]; then
		if kill -0 "${MCPBASH_SHUTDOWN_WATCHDOG_PID}" 2>/dev/null; then
			return 0
		fi
		MCPBASH_SHUTDOWN_WATCHDOG_PID=""
	fi
	(
		sleep "${timeout}"
		printf '%s\n' "mcp-bash: shutdown timeout (${timeout}s) elapsed; terminating." >&2
		exit 0
	) &
	MCPBASH_SHUTDOWN_WATCHDOG_PID=$!
}

mcp_core_cancel_shutdown_watchdog() {
	if [ -z "${MCPBASH_SHUTDOWN_WATCHDOG_PID}" ]; then
		return 0
	fi
	if kill "${MCPBASH_SHUTDOWN_WATCHDOG_PID}" 2>/dev/null; then
		wait "${MCPBASH_SHUTDOWN_WATCHDOG_PID}" 2>/dev/null || true
	fi
	MCPBASH_SHUTDOWN_WATCHDOG_PID=""
}

mcp_core_process_legacy_batch() {
	local array_json="$1"
	local tool="$MCPBASH_JSON_TOOL"
	local bin="$MCPBASH_JSON_TOOL_BIN"
	local item
	local batch_output=""

	case "${tool}" in
	gojq | jq)
		if ! batch_output="$(printf '%s' "${array_json}" | "${bin}" -c '.[]' 2>/dev/null)"; then
			return 1
		fi
		;;
	*)
		return 1
		;;
	esac

	while IFS= read -r item; do
		[ -z "${item}" ] && continue
		mcp_core_handle_line "${item}"
	done <<<"${batch_output}"$'\n'

	return 0
}

mcp_core_guard_response_size() {
	local id_json="$1"
	local payload="$2"
	local limit="${MCPBASH_MAX_TOOL_OUTPUT_SIZE:-10485760}"
	local size

	case "${limit}" in
	'' | *[!0-9]*) limit=10485760 ;;
	esac
	if [ -z "${payload}" ]; then
		printf '%s' "${payload}"
		return 0
	fi

	size="$(LC_ALL=C printf '%s' "${payload}" | wc -c | tr -d ' ')"
	if [ "${size}" -le "${limit}" ]; then
		printf '%s' "${payload}"
		return 0
	fi

	printf '%s\n' "mcp-bash: response exceeded ${limit} bytes for id ${id_json:-null}" >&2
	mcp_core_build_error_response "${id_json:-null}" -32603 "Response exceeded MAX_TOOL_OUTPUT_SIZE" ""
}

mcp_core_rate_limit() {
	local key="$1"
	local kind="$2"
	local limit
	local file
	local now
	local preserved=""
	local line
	local count=0
	local lock_name
	local result=0

	[ -z "${key}" ] && return 0

	case "${kind}" in
	progress) limit="${MCPBASH_MAX_PROGRESS_PER_MIN:-100}" ;;
	log) limit="${MCPBASH_MAX_LOGS_PER_MIN:-${MCPBASH_MAX_PROGRESS_PER_MIN:-100}}" ;;
	*) limit=100 ;;
	esac

	case "${limit}" in
	'' | *[!0-9]*) limit=100 ;;
	0) return 0 ;;
	esac

	file="${MCPBASH_STATE_DIR}/rate.${kind}.${key}.log"
	lock_name="rate.${kind}.${key}"
	mcp_lock_acquire "${lock_name}"
	now="$(date +%s)"

	if [ -f "${file}" ]; then
		while IFS= read -r line; do
			[ -z "${line}" ] && continue
			if [ $((now - line)) -lt 60 ]; then
				preserved="${preserved}${line}"$'\n'
				count=$((count + 1))
			fi
		done <"${file}"
	fi

	if [ "${count}" -ge "${limit}" ]; then
		printf '%s' "${preserved}" >"${file}"
		result=1
		mcp_lock_release "${lock_name}"
		return "${result}"
	fi

	printf '%s%s\n' "${preserved}" "${now}" >"${file}"
	mcp_lock_release "${lock_name}"
	return "${result}"
}

mcp_core_handle_line() {
	local raw_line="$1"
	local normalized_line
	local method

	normalized_line="$(mcp_json_normalize_line "${raw_line}")" || {
		mcp_core_emit_parse_error "Parse error" -32700 "Failed to normalize input"
		return
	}

	if [ -z "${normalized_line}" ]; then
		return
	fi

	if mcp_json_is_array "${normalized_line}"; then
		if ! mcp_runtime_batches_enabled; then
			mcp_core_emit_parse_error "Invalid Request" -32600 "Batch arrays are disabled"
			return
		fi
		if ! mcp_core_process_legacy_batch "${normalized_line}"; then
			mcp_core_emit_parse_error "Parse error" -32700 "Unable to process batch array"
		fi
		return
	fi

	method="$(mcp_json_extract_method "${normalized_line}")" || {
		mcp_core_emit_parse_error "Invalid Request" -32600 "Missing method"
		return
	}

	mcp_core_dispatch_object "${normalized_line}" "${method}"

	mcp_core_emit_registry_notifications

	if [ "${MCPBASH_EXIT_REQUESTED}" = true ]; then
		mcp_core_wait_for_workers
		mcp_runtime_cleanup
		exit 0
	fi
}

mcp_core_dispatch_object() {
	local json_line="$1"
	local method="$2"
	local handler=""
	local async="false"
	local id_json

	if [ "${method}" = "notifications/cancelled" ]; then
		mcp_core_handle_cancel_notification "${json_line}"
		return
	fi

	if [ "${method}" = "notifications/message" ]; then
		mcp_core_emit_parse_error "Invalid Request" -32601 "notifications/message is server-originated"
		return
	fi

	if ! id_json="$(mcp_json_extract_id "${json_line}")"; then
		mcp_core_emit_parse_error "Invalid Request" -32600 "Unable to extract id"
		return
	fi

	if [ "${MCPBASH_INITIALIZED}" != true ] && ! mcp_core_method_allowed_preinit "${method}"; then
		mcp_core_emit_not_initialized "${id_json}"
		return
	fi

	if [ "${MCPBASH_SHUTDOWN_PENDING}" = true ] && ! mcp_core_method_allowed_during_shutdown "${method}"; then
		mcp_core_emit_shutting_down "${id_json}"
		return
	fi

	if ! mcp_core_resolve_handler "${method}"; then
		mcp_core_emit_method_not_found "${id_json}"
		return
	fi

	handler="${MCPBASH_RESOLVED_HANDLER}"
	async="${MCPBASH_RESOLVED_ASYNC}"

	if [ "${async}" = "true" ]; then
		mcp_core_spawn_worker "${handler}" "${method}" "${json_line}" "${id_json}"
	else
		mcp_core_execute_handler "${handler}" "${method}" "${json_line}" "${id_json}"
	fi
}

mcp_core_resolve_handler() {
	local method="$1"
	MCPBASH_RESOLVED_HANDLER=""
	MCPBASH_RESOLVED_ASYNC="false"

	case "${method}" in
	initialize | shutdown | exit | initialized | notifications/initialized)
		MCPBASH_RESOLVED_HANDLER="mcp_handle_lifecycle"
		;;
	ping)
		MCPBASH_RESOLVED_HANDLER="mcp_handle_ping"
		;;
	logging/*)
		MCPBASH_RESOLVED_HANDLER="mcp_handle_logging"
		;;
	tools/*)
		MCPBASH_RESOLVED_HANDLER="mcp_handle_tools"
		MCPBASH_RESOLVED_ASYNC="true"
		;;
	resources/*)
		MCPBASH_RESOLVED_HANDLER="mcp_handle_resources"
		MCPBASH_RESOLVED_ASYNC="true"
		;;
	prompts/get)
		MCPBASH_RESOLVED_HANDLER="mcp_handle_prompts"
		MCPBASH_RESOLVED_ASYNC="true"
		;;
	prompts/*)
		MCPBASH_RESOLVED_HANDLER="mcp_handle_prompts"
		;;
	completion/complete)
		MCPBASH_RESOLVED_HANDLER="mcp_handle_completion"
		MCPBASH_RESOLVED_ASYNC="true"
		;;
	completion/*)
		MCPBASH_RESOLVED_HANDLER="mcp_handle_completion"
		;;
	*)
		return 1
		;;
	esac

	return 0
}

mcp_core_execute_handler() {
	local handler="$1"
	local method="$2"
	local json_line="$3"
	local id_json="$4"
	local response

	if ! mcp_core_invoke_handler "${handler}" "${method}" "${json_line}"; then
		response="$(mcp_core_build_error_response "${id_json}" -32601 "Handler not implemented" "")"
	else
		response="${MCPBASH_HANDLER_OUTPUT}"
		if [ "${response}" = "${MCPBASH_NO_RESPONSE}" ]; then
			return 0
		fi
		if [ -z "${response}" ]; then
			response="$(mcp_core_build_error_response "${id_json}" -32603 "Empty handler response" "")"
		fi
	fi

	response="$(mcp_core_guard_response_size "${id_json}" "${response}")"
	rpc_send_line "${response}"
}

mcp_core_spawn_worker() {
	local handler="$1"
	local method="$2"
	local json_line="$3"
	local id_json="$4"
	local key
	local stderr_file=""
	local timeout=""

	mcp_core_wait_for_available_slot

	key="$(mcp_core_get_id_key "${id_json}")"

	if [ -n "${key}" ]; then
		stderr_file="${MCPBASH_STATE_DIR}/stderr.${key}.log"
	else
		stderr_file="${MCPBASH_STATE_DIR}/stderr.${BASHPID:-$$}.${RANDOM}.log"
	fi

	timeout="$(mcp_core_timeout_for_method "${method}" "${json_line}")"
	timeout="$(mcp_core_normalize_timeout "${timeout}")"

	local progress_stream="${MCPBASH_STATE_DIR}/progress.${key:-main}.ndjson"
	local log_stream="${MCPBASH_STATE_DIR}/logs.${key:-main}.ndjson"
	: >"${progress_stream}"
	: >"${log_stream}"
	local cancel_file
	cancel_file="$(mcp_ids_state_path "cancelled" "${key}")"
	rm -f "${cancel_file}"
	local progress_token
	progress_token="$(mcp_json_extract_progress_token "${json_line}")"

	(
		exec 2>"${stderr_file}"
		# shellcheck disable=SC2030
		export MCP_PROGRESS_STREAM="${progress_stream}"
		# shellcheck disable=SC2030
		export MCP_LOG_STREAM="${log_stream}"
		export MCP_PROGRESS_TOKEN="${progress_token}"
		export MCP_CANCEL_FILE="${cancel_file}"
		if [ -n "${timeout}" ]; then
			with_timeout "${timeout}" -- mcp_core_worker_entry "${handler}" "${method}" "${json_line}" "${id_json}" "${key}" "${stderr_file}"
		else
			mcp_core_worker_entry "${handler}" "${method}" "${json_line}" "${id_json}" "${key}" "${stderr_file}"
		fi
	) &

	local pid=$!

	mcp_runtime_set_process_group "${pid}" || true
	local pgid
	pgid="$(mcp_runtime_lookup_pgid "${pid}")"

	mcp_ids_track_worker "${key}" "${pid}" "${pgid}" "${stderr_file}"
	if [ -n "${key}" ] && ! mcp_core_process_alive "${pid}"; then
		wait "${pid}" 2>/dev/null || true
		mcp_ids_clear_worker "${key}"
	fi
}

mcp_core_timeout_for_method() {
	local method="$1"
	local json_line="$2"
	local timeout_value=""

	case "${method}" in
	tools/* | resources/* | prompts/get | completion/complete)
		if mcp_runtime_is_minimal_mode; then
			printf ''
			return 0
		fi
		case "${MCPBASH_JSON_TOOL}" in
		gojq | jq)
			timeout_value="$(printf '%s' "${json_line}" | "${MCPBASH_JSON_TOOL_BIN}" -er '.params.timeoutSecs // empty' 2>/dev/null || true)"
			;;
		*)
			timeout_value=""
			;;
		esac
		;;
	*)
		printf ''
		return 0
		;;
	esac

	if [ -z "${timeout_value}" ]; then
		case "${method}" in
		tools/*)
			timeout_value="${MCPBASH_DEFAULT_TOOL_TIMEOUT:-30}"
			;;
		resources/subscribe)
			timeout_value="${MCPBASH_DEFAULT_SUBSCRIBE_TIMEOUT:-120}"
			;;
		esac
	fi

	printf '%s' "${timeout_value}"
}

mcp_core_worker_entry() {
	local handler="$1"
	local method="$2"
	local json_line="$3"
	local id_json="$4"
	local key="$5"
	local stderr_file="$6"
	local response
	# shellcheck disable=SC2031
	local progress_stream="${MCP_PROGRESS_STREAM:-}"
	# shellcheck disable=SC2031
	local log_stream="${MCP_LOG_STREAM:-}"

	trap 'mcp_core_worker_cleanup "${key}" "${stderr_file}"' EXIT

	if ! mcp_core_invoke_handler "${handler}" "${method}" "${json_line}"; then
		response="$(mcp_core_build_error_response "${id_json}" -32601 "Handler not implemented" "")"
	else
		response="${MCPBASH_HANDLER_OUTPUT}"
		if [ "${response}" = "${MCPBASH_NO_RESPONSE}" ]; then
			response=""
		elif [ -z "${response}" ]; then
			response="$(mcp_core_build_error_response "${id_json}" -32603 "Empty handler response" "")"
		fi
	fi

	if [ -n "${response}" ]; then
		response="$(mcp_core_guard_response_size "${id_json}" "${response}")"
		mcp_core_worker_emit "${key}" "${response}"
	fi

	if [ -n "${progress_stream}" ]; then
		mcp_core_emit_progress_stream "${key}" "${progress_stream}"
		rm -f "${progress_stream}"
		rm -f "${MCPBASH_STATE_DIR}/rate.progress.${key}.log"
		rm -f "${progress_stream}.offset"
	fi
	if [ -n "${log_stream}" ]; then
		mcp_core_emit_log_stream "${key}" "${log_stream}"
		rm -f "${log_stream}"
		rm -f "${MCPBASH_STATE_DIR}/rate.log.${key}.log"
		rm -f "${log_stream}.offset"
	fi
}

mcp_core_worker_emit() {
	local key="$1"
	local payload="$2"
	if [ "${MCPBASH_DEBUG_PAYLOADS:-}" = "true" ] && [ -n "${MCPBASH_STATE_DIR:-}" ]; then
		local length="${#payload}"
		mcp_io_debug_log "worker" "${key}" "emit_len=${length}" "${payload}"
	fi
	mcp_io_send_response "${key}" "${payload}"
}

mcp_core_worker_cleanup() {
	local key="$1"
	local stderr_file="$2"

	if [ -n "${key}" ]; then
		mcp_ids_clear_worker "${key}"
		rm -f "${MCPBASH_STATE_DIR}/rate.progress.${key}.log"
		rm -f "${MCPBASH_STATE_DIR}/rate.log.${key}.log"
		rm -f "${MCPBASH_STATE_DIR}/progress.${key}.ndjson.offset"
		rm -f "${MCPBASH_STATE_DIR}/logs.${key}.ndjson.offset"
	fi

	if [ -n "${stderr_file}" ] && [ -f "${stderr_file}" ]; then
		rm -f "${stderr_file}"
	fi
}

mcp_core_invoke_handler() {
	local handler="$1"
	local method="$2"
	local json_line="$3"
	local tmp_file=""
	local status=0

	if ! declare -f "${handler}" >/dev/null 2>&1; then
		return 127
	fi

	tmp_file="$(mktemp "${MCPBASH_STATE_DIR}/handler.${BASHPID:-$$}.XXXXXX")"
	MCPBASH_HANDLER_OUTPUT=""
	if MCPBASH_DIRECT_FD=3 "${handler}" "${method}" "${json_line}" 3>&1 >"${tmp_file}"; then
		status=0
	else
		status=$?
	fi
	MCPBASH_HANDLER_OUTPUT="$(mcp_io_read_file_exact "${tmp_file}")"
	if [ "${MCPBASH_DEBUG_PAYLOADS:-}" = "true" ] && [ -n "${MCPBASH_STATE_DIR:-}" ]; then
		mcp_io_debug_log "handler" "${method}" "exit=${status}" "${MCPBASH_HANDLER_OUTPUT}"
	fi
	rm -f "${tmp_file}"
	return "${status}"
}

mcp_core_handle_cancel_notification() {
	local json_line="$1"
	local cancel_id

	if [ "${MCPBASH_INITIALIZED}" = "false" ]; then
		return 0
	fi

	cancel_id="$(mcp_json_extract_cancel_id "${json_line}")"
	if [ -z "${cancel_id}" ]; then
		return 0
	fi

	mcp_core_cancel_request "${cancel_id}"
}

mcp_core_cancel_request() {
	local id_json="$1"
	local key
	local info
	local pid=""
	local pgid=""

	key="$(mcp_core_get_id_key "${id_json}")"
	if [ -z "${key}" ]; then
		return 0
	fi

	mcp_ids_mark_cancelled "${key}"

	if ! info="$(mcp_ids_worker_info "${key}")"; then
		return 0
	fi

	pid="$(printf '%s' "${info}" | awk '{print $1}')"
	pgid="$(printf '%s' "${info}" | awk '{print $2}')"

	if [ -z "${pid}" ]; then
		return 0
	fi

	mcp_core_send_signal_chain "${pid}" "${pgid}" TERM
	sleep 1
	if mcp_core_process_alive "${pid}"; then
		mcp_core_send_signal_chain "${pid}" "${pgid}" KILL
	fi
}

mcp_core_send_signal_chain() {
	local pid="$1"
	local pgid="$2"
	local signal="$3"

	mcp_runtime_signal_group "${pgid}" "${signal}" "${pid}" "${MCPBASH_MAIN_PGID}"
}

mcp_core_process_alive() {
	local pid="$1"
	kill -0 "${pid}" 2>/dev/null
}

mcp_core_get_id_key() {
	local id_json="$1"
	mcp_ids_key_from_json "${id_json}"
}

mcp_core_method_allowed_preinit() {
	case "$1" in
	initialize | notifications/initialized | notifications/cancelled | shutdown | exit)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

mcp_core_method_allowed_during_shutdown() {
	case "$1" in
	exit | shutdown | notifications/cancelled | notifications/initialized)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

mcp_core_emit_not_initialized() {
	local id_json="$1"
	if [ -z "${id_json}" ]; then
		id_json="null"
	fi
	rpc_send_line "$(mcp_core_build_error_response "${id_json}" -32002 "Server not initialized" "")"
}

mcp_core_emit_shutting_down() {
	local id_json="$1"
	if [ -z "${id_json}" ]; then
		id_json="null"
	fi
	rpc_send_line "$(mcp_core_build_error_response "${id_json}" -32003 "Server shutting down" "")"
}

mcp_core_build_error_response() {
	local id_json="$1"
	local code="$2"
	local message="$3"
	local data="$4"
	local id_value

	id_value="${id_json:-null}"

	if [ -n "${data}" ]; then
		printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%s,"message":"%s","data":"%s"}}' "${id_value}" "${code}" "${message}" "${data}"
	else
		printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%s,"message":"%s"}}' "${id_value}" "${code}" "${message}"
	fi
}

mcp_core_emit_parse_error() {
	local message="$1"
	local code="$2"
	local details="$3"
	rpc_send_line "$(mcp_core_build_error_response "null" "${code}" "${message}" "${details}")"
}

mcp_core_emit_method_not_found() {
	local id_json="$1"
	rpc_send_line "$(mcp_core_build_error_response "${id_json}" -32601 "Method not found" "")"
}

mcp_core_normalize_timeout() {
	local value="$1"
	value="$(printf '%s' "${value}" | tr -d '\r\n')"
	case "${value}" in
	'') printf '' ;;
	*[!0-9]*) printf '' ;;
	0) printf '' ;;
	*) printf '%s' "${value}" ;;
	esac
}

mcp_core_emit_progress_stream() {
	local key="$1"
	local stream="$2"
	[ -n "${stream}" ] || return 0
	[ -f "${stream}" ] || return 0
	while IFS= read -r line || [ -n "${line}" ]; do
		[ -z "${line}" ] && continue
		if mcp_core_rate_limit "${key}" "progress"; then
			rpc_send_line "${line}"
		fi
	done <"${stream}"
}

mcp_core_extract_log_level() {
	local line="$1"
	local level
	level="$(mcp_json_extract_log_level "${line}" | tr '[:upper:]' '[:lower:]')"
	[ -z "${level}" ] && level="info"
	printf '%s' "${level}"
}

mcp_core_emit_log_stream() {
	local key="$1"
	local stream="$2"
	[ -n "${stream}" ] || return 0
	[ -f "${stream}" ] || return 0
	while IFS= read -r line || [ -n "${line}" ]; do
		[ -z "${line}" ] && continue
		local level
		level="$(mcp_core_extract_log_level "${line}")"
		if mcp_logging_is_enabled "${level}"; then
			if mcp_core_rate_limit "${key}" "log"; then
				rpc_send_line "${line}"
			fi
		fi
	done <"${stream}"
}

mcp_core_emit_registry_notifications() {
	local note
	mcp_tools_poll
	note="$(mcp_tools_consume_notification)"
	if [ -n "${note}" ]; then
		rpc_send_line "${note}"
	fi
	mcp_resources_poll
	note="$(mcp_resources_consume_notification)"
	if [ -n "${note}" ]; then
		rpc_send_line "${note}"
	fi
	mcp_prompts_poll
	note="$(mcp_prompts_consume_notification)"
	if [ -n "${note}" ]; then
		rpc_send_line "${note}"
	fi
}

mcp_core_flush_stream() {
	local key="$1"
	local kind="$2"
	local stream="${MCPBASH_STATE_DIR}/${kind}.${key}.ndjson"
	local offset_file="${stream}.offset"
	[ -f "${stream}" ] || return 0
	local last_offset=0
	if [ -f "${offset_file}" ]; then
		last_offset="$(cat "${offset_file}")"
	fi
	local size
	size="$(wc -c <"${stream}" 2>/dev/null || echo 0)"
	if [ "${size}" -lt "${last_offset}" ]; then
		last_offset=0
	fi
	if [ "${size}" -eq "${last_offset}" ]; then
		return 0
	fi
	tail -c +$((last_offset + 1)) "${stream}" 2>/dev/null \
		| while IFS= read -r line || [ -n "${line}" ]; do
			[ -z "${line}" ] && continue
			if [ "${kind}" = "log" ]; then
				local level
				level="$(mcp_core_extract_log_level "${line}")"
				if ! mcp_logging_is_enabled "${level}"; then
					continue
				fi
			fi
			if mcp_core_rate_limit "${key}" "${kind}"; then
				rpc_send_line "${line}"
			fi
		done
	echo "${size}" >"${offset_file}"
}

mcp_core_flush_worker_streams_once() {
	local listing key
	listing="$(mcp_ids_list_active_workers 2>/dev/null || true)"
	[ -z "${listing}" ] && return 0
	while IFS= read -r key || [ -n "${key}" ]; do
		[ -z "${key}" ] && continue
		mcp_core_flush_stream "${key}" "progress"
		mcp_core_flush_stream "${key}" "log"
	done <<<"${listing}"
}

mcp_core_start_progress_flusher() {
	if [ -n "${MCPBASH_PROGRESS_FLUSHER_PID:-}" ]; then
		return 0
	fi
	(
		while :; do
			if [ "${MCPBASH_ENABLE_LIVE_PROGRESS:-false}" = "true" ]; then
				mcp_core_flush_worker_streams_once
			fi
			sleep "${MCPBASH_PROGRESS_FLUSH_INTERVAL:-0.5}"
		done
	) &
	MCPBASH_PROGRESS_FLUSHER_PID=$!
}

mcp_core_stop_progress_flusher() {
	if [ -z "${MCPBASH_PROGRESS_FLUSHER_PID:-}" ]; then
		return 0
	fi
	if kill "${MCPBASH_PROGRESS_FLUSHER_PID}" 2>/dev/null; then
		wait "${MCPBASH_PROGRESS_FLUSHER_PID}" 2>/dev/null || true
	fi
	MCPBASH_PROGRESS_FLUSHER_PID=""
}

mcp_core_start_resource_poll() {
	local interval="${MCPBASH_RESOURCES_POLL_INTERVAL_SECS:-2}"
	case "${interval}" in
	'' | *[!0-9]*) interval=2 ;;
	esac

	if [ "${interval}" -le 0 ]; then
		return 0
	fi
	if mcp_runtime_is_minimal_mode; then
		return 0
	fi

	if [ -n "${MCPBASH_RESOURCE_POLL_PID:-}" ] && kill -0 "${MCPBASH_RESOURCE_POLL_PID}" 2>/dev/null; then
		return 0
	fi

	(
		while :; do
			mcp_resources_poll_subscriptions
			sleep "${interval}"
		done
	) &
	MCPBASH_RESOURCE_POLL_PID=$!
}

mcp_core_stop_resource_poll() {
	if [ -z "${MCPBASH_RESOURCE_POLL_PID:-}" ]; then
		return 0
	fi
	if kill "${MCPBASH_RESOURCE_POLL_PID}" 2>/dev/null; then
		wait "${MCPBASH_RESOURCE_POLL_PID}" 2>/dev/null || true
	fi
	MCPBASH_RESOURCE_POLL_PID=""
}
