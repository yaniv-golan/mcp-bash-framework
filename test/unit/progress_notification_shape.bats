#!/usr/bin/env bats
# Unit layer: notifications/progress shape from the SDK (mcp_progress) and the
# runtime (mcp_progress_emit_notification). The MCP schema types `total` as a
# number, so an unknown total must be left out, never sent as null.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	mcp_runtime_detect_json_tool
	MCP_PROGRESS_TOKEN="tok-1"
	MCP_PROGRESS_STREAM="${BATS_TEST_TMPDIR}/progress.ndjson"
	: >"${MCP_PROGRESS_STREAM}"
}

@test "progress: SDK omits total when none is given" {
	# shellcheck source=sdk/tool-sdk.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/sdk/tool-sdk.sh"
	mcp_progress 40 "working"
	run "${MCPBASH_JSON_TOOL_BIN}" -e '.params | (has("total") | not) and .progress == 40 and .message == "working" and .progressToken == "tok-1"' "${MCP_PROGRESS_STREAM}"
	assert_success
}

@test "progress: SDK sends a numeric total when given" {
	# shellcheck source=sdk/tool-sdk.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/sdk/tool-sdk.sh"
	mcp_progress 40 "working" 100
	run "${MCPBASH_JSON_TOOL_BIN}" -e '.params.total == 100' "${MCP_PROGRESS_STREAM}"
	assert_success
}

@test "progress: SDK drops a non-numeric total" {
	# shellcheck source=sdk/tool-sdk.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/sdk/tool-sdk.sh"
	mcp_progress 40 "working" "lots"
	run "${MCPBASH_JSON_TOOL_BIN}" -e '.params | has("total") | not' "${MCP_PROGRESS_STREAM}"
	assert_success
}

@test "progress: runtime omits total when none is given" {
	# shellcheck source=lib/progress.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/progress.sh"
	mcp_progress_emit_notification 10 "starting"
	run "${MCPBASH_JSON_TOOL_BIN}" -e '.params | (has("total") | not) and .progress == 10' "${MCP_PROGRESS_STREAM}"
	assert_success
}

@test "progress: runtime sends a numeric total when given" {
	# shellcheck source=lib/progress.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/progress.sh"
	mcp_progress_emit_notification 10 "starting" 50
	run "${MCPBASH_JSON_TOOL_BIN}" -e '.params.total == 50' "${MCP_PROGRESS_STREAM}"
	assert_success
}
