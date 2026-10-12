#!/usr/bin/env bats
# Unit tests for timeout isError:true response format (MCP spec compliance).
#
# Tests the _mcp_tools_emit_timeout_result helper and the error result a
# timed-out tool returns: the same shape as every other tool error (no
# structuredContent; details in _meta["mcpbash/error"]), plus _meta.exitCode
# and _meta.stderr.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	export MCPBASH_TMP_ROOT="${BATS_TEST_TMPDIR}"
	export MCPBASH_PROJECT_ROOT="${BATS_TEST_TMPDIR}"
	export MCPBASH_STATE_DIR="${BATS_TEST_TMPDIR}/state"
	mkdir -p "${MCPBASH_STATE_DIR}"

	# Source tools.sh to get access to the helper function
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	mcp_runtime_init_paths
	# shellcheck source=lib/tools.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/tools.sh"

	# Set up JSON tooling
	if command -v jq &>/dev/null; then
		export MCPBASH_JSON_TOOL="jq"
		export MCPBASH_JSON_TOOL_BIN="$(command -v jq)"
	elif command -v gojq &>/dev/null; then
		export MCPBASH_JSON_TOOL="gojq"
		export MCPBASH_JSON_TOOL_BIN="$(command -v gojq)"
	else
		skip "No JSON tool available"
	fi
}

teardown() {
	rm -rf "${BATS_TEST_TMPDIR}/state" 2>/dev/null || true
}

# ==============================================================================
# Helper function tests
# ==============================================================================

fixed_data='{"timeoutSecs":30,"reason":"fixed","exitCode":124}'

@test "timeout helper: returns isError true with the message as text" {
	_mcp_tools_emit_timeout_result "Tool timed out after 30s" "" "${fixed_data}" "" 124

	run jq -e '.isError == true' <<< "${_MCP_TOOLS_RESULT}"
	assert_success

	run jq -r '.content[0].text' <<< "${_MCP_TOOLS_RESULT}"
	assert_output "Tool timed out after 30s"
}

@test "timeout helper: no structuredContent (not checked against outputSchema)" {
	_mcp_tools_emit_timeout_result "Tool timed out after 30s" "" "${fixed_data}" "" 124

	run jq -e 'has("structuredContent") | not' <<< "${_MCP_TOOLS_RESULT}"
	assert_success
}

@test "timeout helper: details in _meta mcpbash/error" {
	_mcp_tools_emit_timeout_result "Tool timed out after 60s (no progress reported)" "" \
		'{"timeoutSecs":60,"reason":"idle","exitCode":124,"progressExtendsTimeout":true,"maxTimeoutSecs":600}' "" 124

	local want='{"type":"timeout","message":"Tool timed out after 60s (no progress reported)","data":{"timeoutSecs":60,"reason":"idle","exitCode":124,"progressExtendsTimeout":true,"maxTimeoutSecs":600}}'
	run jq -e --argjson want "${want}" '._meta["mcpbash/error"] == $want' <<< "${_MCP_TOOLS_RESULT}"
	assert_success
}

@test "timeout helper: hint goes to mcpbash/error and to the text once" {
	_mcp_tools_emit_timeout_result "Tool timed out after 30s" "Try smaller inputs." "${fixed_data}" "" 124

	run jq -r '._meta["mcpbash/error"].hint' <<< "${_MCP_TOOLS_RESULT}"
	assert_output "Try smaller inputs."

	run jq -r '.content[0].text' <<< "${_MCP_TOOLS_RESULT}"
	assert_output $'Tool timed out after 30s\n\nHint: Try smaller inputs.'

	run jq -r '._meta["mcpbash/error"].message' <<< "${_MCP_TOOLS_RESULT}"
	assert_output "Tool timed out after 30s"
}

@test "timeout helper: no hint field when not provided" {
	_mcp_tools_emit_timeout_result "Tool timed out after 30s" "" "${fixed_data}" "" 124

	run jq -e '._meta["mcpbash/error"] | has("hint") | not' <<< "${_MCP_TOOLS_RESULT}"
	assert_success
}

@test "timeout helper: preserves exitCode and stderr in _meta" {
	_mcp_tools_emit_timeout_result "Tool timed out after 30s" "" "${fixed_data}" $'some "error"\noutput' 124

	run jq -e '._meta.exitCode == 124' <<< "${_MCP_TOOLS_RESULT}"
	assert_success

	run jq -r '._meta.stderr' <<< "${_MCP_TOOLS_RESULT}"
	assert_output $'some "error"\noutput'
}

@test "timeout helper: omits stderr from _meta when empty" {
	_mcp_tools_emit_timeout_result "Tool timed out after 30s" "" "${fixed_data}" "" 124

	run jq -e '._meta | has("stderr") | not' <<< "${_MCP_TOOLS_RESULT}"
	assert_success

	run jq -e '._meta.exitCode == 124' <<< "${_MCP_TOOLS_RESULT}"
	assert_success
}

@test "timeout helper: handles SIGKILL and SIGTERM exit codes" {
	_mcp_tools_emit_timeout_result "Tool timed out after 30s" "" '{"timeoutSecs":30,"reason":"fixed","exitCode":137}' "" 137
	run jq -e '._meta.exitCode == 137' <<< "${_MCP_TOOLS_RESULT}"
	assert_success

	_mcp_tools_emit_timeout_result "Tool timed out after 30s" "" '{"timeoutSecs":30,"reason":"fixed","exitCode":143}' "" 143
	run jq -e '._meta.exitCode == 143' <<< "${_MCP_TOOLS_RESULT}"
	assert_success
}

@test "timeout helper: minimal mode (no JSON tool) gives the same result" {
	_mcp_tools_emit_timeout_result "Tool timed out after 30s" "Try smaller inputs." "${fixed_data}" $'err\tline' 124
	local full="${_MCP_TOOLS_RESULT}"

	local jq_bin="${MCPBASH_JSON_TOOL_BIN}"
	unset MCPBASH_JSON_TOOL_BIN
	export MCPBASH_JSON_TOOL="none"
	# The builder falls back to jq on PATH; hide it so the builtins path runs.
	PATH="${BATS_TEST_TMPDIR}/nojq" _mcp_tools_emit_timeout_result "Tool timed out after 30s" "Try smaller inputs." "${fixed_data}" $'err\tline' 124

	run "${jq_bin}" -e --argjson full "${full}" '. == $full' <<< "${_MCP_TOOLS_RESULT}"
	assert_success
}

@test "timeout helper: minimal mode escapes special characters" {
	local jq_bin="${MCPBASH_JSON_TOOL_BIN}"
	unset MCPBASH_JSON_TOOL_BIN
	export MCPBASH_JSON_TOOL="none"

	PATH="${BATS_TEST_TMPDIR}/nojq" _mcp_tools_emit_timeout_result $'Tool timed out after 30s\nDetails: "error"\twith\ttabs' "" "${fixed_data}" "" 124

	run "${jq_bin}" -r '.content[0].text' <<< "${_MCP_TOOLS_RESULT}"
	assert_success
	assert_output $'Tool timed out after 30s\nDetails: "error"\twith\ttabs'
}

# ==============================================================================
# Format function tests (mcp_tools_format_timeout_error)
# ==============================================================================

@test "format timeout error: basic message" {
	unset MCPBASH_TIMEOUT_REASON

	run mcp_tools_format_timeout_error 30
	assert_success
	assert_output "Tool timed out after 30s"
}

@test "format timeout error: idle reason" {
	export MCPBASH_TIMEOUT_REASON="idle"

	run mcp_tools_format_timeout_error 60
	assert_success
	assert_output "Tool timed out after 60s (no progress reported)"
}

@test "format timeout error: max_exceeded reason" {
	export MCPBASH_TIMEOUT_REASON="max_exceeded"
	export MCPBASH_MAX_TIMEOUT_SECS=600

	run mcp_tools_format_timeout_error 30
	assert_success
	assert_output "Tool exceeded maximum runtime of 600s"
}

@test "format timeout error: leaves the hint to the result builder" {
	unset MCPBASH_TIMEOUT_REASON
	export MCPBASH_TIMEOUT_HINT="Try using dryRun=true first."

	run mcp_tools_format_timeout_error 30
	assert_success
	assert_output "Tool timed out after 30s"
}
