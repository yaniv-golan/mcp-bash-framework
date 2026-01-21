#!/usr/bin/env bats
# Unit tests for timeout isError:true response format (MCP spec compliance).
#
# Tests the _mcp_tools_emit_timeout_result helper and the structured error
# format returned when tools timeout. This ensures LLMs receive actionable
# feedback per MCP spec guidance.
#
# Related: docs/internal/spec-timeout-iserror-migration-2026-01.md

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

@test "timeout helper: returns isError true in result" {
	local message="Tool timed out after 30s"
	local structured_error='{"type":"timeout","reason":"fixed","timeoutSecs":30,"exitCode":124}'
	local stderr_tail=""
	local exit_code=124

	_mcp_tools_emit_timeout_result "${message}" "${structured_error}" "${stderr_tail}" "${exit_code}"

	# Verify result structure
	run jq -e '.isError == true' <<< "${_MCP_TOOLS_RESULT}"
	assert_success

	run jq -e '.content[0].type == "text"' <<< "${_MCP_TOOLS_RESULT}"
	assert_success

	run jq -r '.content[0].text' <<< "${_MCP_TOOLS_RESULT}"
	assert_output --partial "timed out"
}

@test "timeout helper: includes structured metadata" {
	local message="Tool timed out after 60s"
	local structured_error='{"type":"timeout","message":"Tool timed out after 60s","reason":"idle","timeoutSecs":60,"exitCode":124}'
	local stderr_tail=""
	local exit_code=124

	_mcp_tools_emit_timeout_result "${message}" "${structured_error}" "${stderr_tail}" "${exit_code}"

	# Verify structuredContent.error contains required fields
	run jq -e '.structuredContent.error | has("type", "reason", "timeoutSecs", "exitCode")' <<< "${_MCP_TOOLS_RESULT}"
	assert_success

	run jq -e '.structuredContent.error.type == "timeout"' <<< "${_MCP_TOOLS_RESULT}"
	assert_success

	run jq -e '.structuredContent.error.timeoutSecs | type == "number"' <<< "${_MCP_TOOLS_RESULT}"
	assert_success

	run jq -e '.structuredContent.error.exitCode | . == 124 or . == 137 or . == 143' <<< "${_MCP_TOOLS_RESULT}"
	assert_success
}

@test "timeout helper: preserves stderr in _meta" {
	local message="Tool timed out after 30s"
	local structured_error='{"type":"timeout","reason":"fixed","timeoutSecs":30,"exitCode":124}'
	local stderr_tail="some error output"
	local exit_code=124

	_mcp_tools_emit_timeout_result "${message}" "${structured_error}" "${stderr_tail}" "${exit_code}"

	# Verify _meta.exitCode and _meta.stderr
	run jq -e '._meta.exitCode == 124' <<< "${_MCP_TOOLS_RESULT}"
	assert_success

	run jq -r '._meta.stderr' <<< "${_MCP_TOOLS_RESULT}"
	assert_output "some error output"
}

@test "timeout helper: omits stderr from _meta when empty" {
	local message="Tool timed out after 30s"
	local structured_error='{"type":"timeout","reason":"fixed","timeoutSecs":30,"exitCode":124}'
	local stderr_tail=""
	local exit_code=124

	_mcp_tools_emit_timeout_result "${message}" "${structured_error}" "${stderr_tail}" "${exit_code}"

	# Verify _meta.stderr is not present when empty
	run jq -e '._meta | has("stderr") | not' <<< "${_MCP_TOOLS_RESULT}"
	assert_success

	# But exitCode should still be present
	run jq -e '._meta.exitCode == 124' <<< "${_MCP_TOOLS_RESULT}"
	assert_success
}

@test "timeout helper: reason fixed for static timeout" {
	local message="Tool timed out after 30s"
	local structured_error='{"type":"timeout","message":"Tool timed out after 30s","reason":"fixed","timeoutSecs":30,"exitCode":124}'
	local stderr_tail=""
	local exit_code=124

	_mcp_tools_emit_timeout_result "${message}" "${structured_error}" "${stderr_tail}" "${exit_code}"

	# Verify reason is "fixed"
	run jq -e '.structuredContent.error.reason == "fixed"' <<< "${_MCP_TOOLS_RESULT}"
	assert_success

	# Verify progressExtendsTimeout is NOT present (static timeout)
	run jq -e '.structuredContent.error | has("progressExtendsTimeout") | not' <<< "${_MCP_TOOLS_RESULT}"
	assert_success
}

@test "timeout helper: reason idle with progress-aware fields" {
	local message="Tool timed out after 30s (no progress reported)"
	local structured_error='{"type":"timeout","message":"Tool timed out after 30s (no progress reported)","reason":"idle","timeoutSecs":30,"exitCode":124,"progressExtendsTimeout":true,"maxTimeoutSecs":600}'
	local stderr_tail=""
	local exit_code=124

	_mcp_tools_emit_timeout_result "${message}" "${structured_error}" "${stderr_tail}" "${exit_code}"

	# Verify reason is "idle"
	run jq -e '.structuredContent.error.reason == "idle"' <<< "${_MCP_TOOLS_RESULT}"
	assert_success

	# Verify progressExtendsTimeout is present and true
	run jq -e '.structuredContent.error.progressExtendsTimeout == true' <<< "${_MCP_TOOLS_RESULT}"
	assert_success

	# Verify maxTimeoutSecs is present
	run jq -e '.structuredContent.error | has("maxTimeoutSecs")' <<< "${_MCP_TOOLS_RESULT}"
	assert_success
}

@test "timeout helper: reason max_exceeded with progress-aware fields" {
	local message="Tool exceeded maximum runtime of 600s"
	local structured_error='{"type":"timeout","message":"Tool exceeded maximum runtime of 600s","reason":"max_exceeded","timeoutSecs":30,"exitCode":124,"progressExtendsTimeout":true,"maxTimeoutSecs":600}'
	local stderr_tail=""
	local exit_code=124

	_mcp_tools_emit_timeout_result "${message}" "${structured_error}" "${stderr_tail}" "${exit_code}"

	# Verify reason is "max_exceeded"
	run jq -e '.structuredContent.error.reason == "max_exceeded"' <<< "${_MCP_TOOLS_RESULT}"
	assert_success

	# Verify progressExtendsTimeout is present and true
	run jq -e '.structuredContent.error.progressExtendsTimeout == true' <<< "${_MCP_TOOLS_RESULT}"
	assert_success
}

@test "timeout helper: minimal mode produces valid JSON" {
	# Force minimal mode by unsetting JSON tool
	unset MCPBASH_JSON_TOOL_BIN
	export MCPBASH_JSON_TOOL="none"

	local message="Tool timed out after 30s"
	local structured_error='{}'  # Not used in minimal mode
	local stderr_tail=""
	local exit_code=124

	_mcp_tools_emit_timeout_result "${message}" "${structured_error}" "${stderr_tail}" "${exit_code}"

	# Verify response is valid JSON
	run jq -e '.' <<< "${_MCP_TOOLS_RESULT}"
	assert_success

	# Verify isError: true
	run jq -e '.isError == true' <<< "${_MCP_TOOLS_RESULT}"
	assert_success

	# Verify content structure
	run jq -e '.content[0].type == "text"' <<< "${_MCP_TOOLS_RESULT}"
	assert_success

	# Note: structuredContent not present in minimal mode
	run jq -e 'has("structuredContent") | not' <<< "${_MCP_TOOLS_RESULT}"
	assert_success
}

@test "timeout helper: minimal mode escapes special characters" {
	unset MCPBASH_JSON_TOOL_BIN
	export MCPBASH_JSON_TOOL="none"

	# Message with characters that need escaping
	local message=$'Tool timed out after 30s\nDetails: "error"\twith\ttabs'
	local structured_error='{}'
	local stderr_tail=""
	local exit_code=124

	_mcp_tools_emit_timeout_result "${message}" "${structured_error}" "${stderr_tail}" "${exit_code}"

	# Verify response is valid JSON (would fail if escaping broken)
	run jq -e '.' <<< "${_MCP_TOOLS_RESULT}"
	assert_success

	# Verify the message text contains expected content
	run jq -r '.content[0].text' <<< "${_MCP_TOOLS_RESULT}"
	assert_output --partial "timed out"
}

@test "timeout helper: handles SIGKILL exit code (137)" {
	local message="Tool timed out after 30s"
	local structured_error='{"type":"timeout","reason":"fixed","timeoutSecs":30,"exitCode":137}'
	local stderr_tail=""
	local exit_code=137

	_mcp_tools_emit_timeout_result "${message}" "${structured_error}" "${stderr_tail}" "${exit_code}"

	run jq -e '._meta.exitCode == 137' <<< "${_MCP_TOOLS_RESULT}"
	assert_success
}

@test "timeout helper: handles SIGTERM exit code (143)" {
	local message="Tool timed out after 30s"
	local structured_error='{"type":"timeout","reason":"fixed","timeoutSecs":30,"exitCode":143}'
	local stderr_tail=""
	local exit_code=143

	_mcp_tools_emit_timeout_result "${message}" "${structured_error}" "${stderr_tail}" "${exit_code}"

	run jq -e '._meta.exitCode == 143' <<< "${_MCP_TOOLS_RESULT}"
	assert_success
}

# ==============================================================================
# Format function tests (mcp_tools_format_timeout_error)
# ==============================================================================

@test "format timeout error: basic message without hint" {
	unset MCPBASH_TIMEOUT_REASON
	unset MCPBASH_TIMEOUT_HINT

	run mcp_tools_format_timeout_error 30
	assert_success
	assert_output "Tool timed out after 30s"
}

@test "format timeout error: idle reason without hint" {
	export MCPBASH_TIMEOUT_REASON="idle"
	unset MCPBASH_TIMEOUT_HINT

	run mcp_tools_format_timeout_error 60
	assert_success
	assert_output "Tool timed out after 60s (no progress reported)"
}

@test "format timeout error: max_exceeded reason without hint" {
	export MCPBASH_TIMEOUT_REASON="max_exceeded"
	export MCPBASH_MAX_TIMEOUT_SECS=600
	unset MCPBASH_TIMEOUT_HINT

	run mcp_tools_format_timeout_error 30
	assert_success
	assert_output "Tool exceeded maximum runtime of 600s"
}

@test "format timeout error: appends hint when set" {
	unset MCPBASH_TIMEOUT_REASON
	export MCPBASH_TIMEOUT_HINT="Try using dryRun=true first."

	run mcp_tools_format_timeout_error 30
	assert_success
	assert_output --partial "Tool timed out after 30s"
	assert_output --partial "Suggestion: Try using dryRun=true first."
}

@test "format timeout error: hint with idle reason" {
	export MCPBASH_TIMEOUT_REASON="idle"
	export MCPBASH_TIMEOUT_HINT="Enable progress reporting for long operations."

	run mcp_tools_format_timeout_error 45
	assert_success
	assert_output --partial "Tool timed out after 45s (no progress reported)"
	assert_output --partial "Suggestion: Enable progress reporting for long operations."
}

@test "format timeout error: hint with max_exceeded reason" {
	export MCPBASH_TIMEOUT_REASON="max_exceeded"
	export MCPBASH_MAX_TIMEOUT_SECS=300
	export MCPBASH_TIMEOUT_HINT="Consider batching large requests."

	run mcp_tools_format_timeout_error 30
	assert_success
	assert_output --partial "Tool exceeded maximum runtime of 300s"
	assert_output --partial "Suggestion: Consider batching large requests."
}

# ==============================================================================
# Structured content hint tests
# ==============================================================================

@test "timeout helper: hint included in structuredContent.error" {
	local message="Tool timed out after 30s\n\nSuggestion: Try smaller inputs."
	local structured_error='{"type":"timeout","message":"Tool timed out after 30s","reason":"fixed","timeoutSecs":30,"exitCode":124,"hint":"Try smaller inputs."}'
	local stderr_tail=""
	local exit_code=124

	_mcp_tools_emit_timeout_result "${message}" "${structured_error}" "${stderr_tail}" "${exit_code}"

	# Verify hint is present in structuredContent.error
	run jq -e '.structuredContent.error | has("hint")' <<< "${_MCP_TOOLS_RESULT}"
	assert_success

	run jq -r '.structuredContent.error.hint' <<< "${_MCP_TOOLS_RESULT}"
	assert_output "Try smaller inputs."
}

@test "timeout helper: hint with progress-aware fields" {
	local message="Tool timed out after 60s (no progress reported)\n\nSuggestion: Enable progress or reduce workload."
	local structured_error='{"type":"timeout","message":"Tool timed out after 60s (no progress reported)","reason":"idle","timeoutSecs":60,"exitCode":124,"progressExtendsTimeout":true,"maxTimeoutSecs":600,"hint":"Enable progress or reduce workload."}'
	local stderr_tail=""
	local exit_code=124

	_mcp_tools_emit_timeout_result "${message}" "${structured_error}" "${stderr_tail}" "${exit_code}"

	# Verify hint is present alongside progress-aware fields
	run jq -e '.structuredContent.error | has("hint", "progressExtendsTimeout", "maxTimeoutSecs")' <<< "${_MCP_TOOLS_RESULT}"
	assert_success

	run jq -r '.structuredContent.error.hint' <<< "${_MCP_TOOLS_RESULT}"
	assert_output "Enable progress or reduce workload."
}

@test "timeout helper: no hint field when not provided" {
	local message="Tool timed out after 30s"
	local structured_error='{"type":"timeout","message":"Tool timed out after 30s","reason":"fixed","timeoutSecs":30,"exitCode":124}'
	local stderr_tail=""
	local exit_code=124

	_mcp_tools_emit_timeout_result "${message}" "${structured_error}" "${stderr_tail}" "${exit_code}"

	# Verify hint is NOT present when not provided
	run jq -e '.structuredContent.error | has("hint") | not' <<< "${_MCP_TOOLS_RESULT}"
	assert_success
}
