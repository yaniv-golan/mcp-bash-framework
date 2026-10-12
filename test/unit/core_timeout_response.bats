#!/usr/bin/env bats
# Unit layer: the timeout error response in mcp_core_spawn_worker (lib/core.sh).

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	# shellcheck source=lib/lock.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/lock.sh"
	# shellcheck source=lib/timeout.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/timeout.sh"
	export MCPBASH_JSON_TOOL="${MCPBASH_JSON_TOOL:-jq}"
	export MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN:-$(command -v jq)}"
	# shellcheck source=lib/json.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/json.sh"
	# shellcheck source=lib/ids.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/ids.sh"
	# shellcheck source=lib/core.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/core.sh"

	export MCPBASH_TMP_ROOT="${BATS_TEST_TMPDIR}"
	export MCPBASH_STATE_DIR="${BATS_TEST_TMPDIR}/state"
	mkdir -p "${MCPBASH_STATE_DIR}"
	MCPBASH_LOCK_ROOT="${BATS_TEST_TMPDIR}/locks"
	MCPBASH_MAIN_PGID=""
	export MCPBASH_SKIP_PROCESS_GROUP_LOOKUP=1
	export MCPBASH_ENABLE_LIVE_PROGRESS=false
	mcp_lock_init

	SENT="${BATS_TEST_TMPDIR}/sent"
	: >"${SENT}"
	export SENT

	mcp_core_wait_for_available_slot() { :; }
	mcp_core_get_id_key() { printf '%s' "key1"; }
	mcp_ids_track_worker() { :; }
	mcp_ids_clear_worker() { :; }
	mcp_core_timeout_for_method() { printf '1'; }
	mcp_json_extract_progress_token() { :; }
	mcp_core_worker_emit() { printf '%s\n' "$2" >>"${SENT}"; }
	mcp_core_invoke_handler() {
		MCPBASH_HANDLER_OUTPUT='{"jsonrpc":"2.0","id":1,"result":{}}'
		return 0
	}
}

@test "timeout: a handler that answered just before the deadline gets no second response" {
	# The handler answers at once; the work after the answer (here the
	# buffered progress delivery) outlasts the 1s timeout.
	mcp_core_emit_progress_stream() { sleep 3; }
	mcp_core_spawn_worker "handler" "resources/read" '{}' '1'
	wait
	run cat "${SENT}"
	assert_line --index 0 '{"jsonrpc":"2.0","id":1,"result":{}}'
	[ "$(grep -c . "${SENT}")" -eq 1 ] || fail "expected one response, got: $(cat "${SENT}")"
	[ ! -e "${MCPBASH_STATE_DIR}/handled.key1" ] || fail "handled marker left behind"
}

@test "timeout: a handler still running at the deadline gets the timeout error" {
	mcp_core_invoke_handler() { sleep 3; }
	mcp_core_spawn_worker "handler" "resources/read" '{}' '1'
	wait
	[ "$(grep -c . "${SENT}")" -eq 1 ] || fail "expected one response, got: $(cat "${SENT}")"
	run cat "${SENT}"
	assert_output --partial '"code":-32603'
	assert_output --partial 'resources/read timed out after 1s'
	[ ! -e "${MCPBASH_STATE_DIR}/handled.key1" ] || fail "handled marker left behind"
}
