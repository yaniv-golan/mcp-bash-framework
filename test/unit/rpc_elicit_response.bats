#!/usr/bin/env bats
# Unit layer: how mcp_rpc_handle_response (lib/rpc.sh) normalises a client's
# answer to an elicitation request for the tool. Since 2.0 there is no
# "error" action: anything but a real accept/decline/cancel is "unavailable".

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	MCPBASH_FORCE_MINIMAL=false
	mcp_runtime_detect_json_tool
	[ "${MCPBASH_MODE}" != "minimal" ] || skip "JSON tooling unavailable"
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/json.sh"
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/rpc.sh"
	MCPBASH_STATE_DIR="${BATS_TEST_TMPDIR}/state"
	mkdir -p "${MCPBASH_STATE_DIR}"
	mcp_logging_warning() { :; }
	mcp_logging_debug() { :; }
	RESPONSE="${BATS_TEST_TMPDIR}/response"
}

# $1: the client's JSON-RPC response to request id 7. Prints the action the
# tool would read.
deliver() {
	rm -f "${RESPONSE}"
	mcp_rpc_register_pending 7 "${RESPONSE}"
	mcp_rpc_handle_response "$1"
	"${MCPBASH_JSON_TOOL_BIN}" -r '.action' <"${RESPONSE}"
}

@test "rpc: a client error is unavailable, not error" {
	run deliver '{"jsonrpc":"2.0","id":7,"error":{"code":-32603,"message":"boom"}}'
	assert_output "unavailable"
}

@test "rpc: a result without an action is unavailable" {
	run deliver '{"jsonrpc":"2.0","id":7,"result":{}}'
	assert_output "unavailable"
}

@test "rpc: accept, decline and cancel pass through" {
	local a
	for a in accept decline cancel; do
		run deliver "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"action\":\"${a}\"}}"
		assert_output "${a}"
	done
}
