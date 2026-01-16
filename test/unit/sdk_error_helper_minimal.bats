#!/usr/bin/env bats
# Unit layer: SDK mcp_error helper in minimal mode (no jq).

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# Force minimal mode (no jq available to SDK functions)
	MCPBASH_JSON_TOOL="none"
	MCPBASH_JSON_TOOL_BIN=""
	MCPBASH_MODE="minimal"
	export MCPBASH_JSON_TOOL MCPBASH_JSON_TOOL_BIN MCPBASH_MODE

	# shellcheck source=sdk/tool-sdk.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/sdk/tool-sdk.sh"

	# Suppress logging during tests
	MCP_LOG_STREAM=""
	export MCP_LOG_STREAM

	# For assertions, we need jq - use system jq directly
	JQ_BIN="$(command -v jq || command -v gojq || true)"
	if [ -z "${JQ_BIN}" ]; then
		skip "Need jq or gojq for test assertions (even though SDK is in minimal mode)"
	fi
}

jq_check() {
	printf '%s' "$1" | "${JQ_BIN}" -e "$2" >/dev/null 2>&1
}

jq_get() {
	printf '%s' "$1" | "${JQ_BIN}" -r "$2"
}

# ============================================================================
# Test 9: Minimal mode fallback produces valid JSON
# ============================================================================

@test "sdk_error_helper_minimal: produces valid JSON" {
	result=$(mcp_error "not_found" "User not found")
	# Must be valid JSON (critical assertion)
	printf '%s' "$result" | "${JQ_BIN}" -e '.' >/dev/null 2>&1
	jq_check "$result" '.isError == true'
}

@test "sdk_error_helper_minimal: type and message in raw field" {
	# In minimal mode, mcp_result_error wraps our JSON as .raw string
	result=$(mcp_error "validation_error" "Invalid input")
	raw=$(jq_get "$result" '.structuredContent.error.raw')
	# The raw field contains our JSON as a string
	[[ "$raw" == *'"type":"validation_error"'* ]]
	[[ "$raw" == *'"message":"Invalid input"'* ]]
}

@test "sdk_error_helper_minimal: hint in raw field" {
	result=$(mcp_error "test" "message" --hint "try this")
	printf '%s' "$result" | "${JQ_BIN}" -e '.' >/dev/null 2>&1
	raw=$(jq_get "$result" '.structuredContent.error.raw')
	[[ "$raw" == *'"hint":"try this"'* ]]
}

@test "sdk_error_helper_minimal: data in raw field" {
	result=$(mcp_error "test" "message" --data '{"key":"value"}')
	printf '%s' "$result" | "${JQ_BIN}" -e '.' >/dev/null 2>&1
	raw=$(jq_get "$result" '.structuredContent.error.raw')
	[[ "$raw" == *'"data":{"key":"value"}'* ]]
}

@test "sdk_error_helper_minimal: special characters escaped" {
	result=$(mcp_error "test" 'Message with "quotes" and backslash\\')
	# Must be valid JSON
	printf '%s' "$result" | "${JQ_BIN}" -e '.' >/dev/null 2>&1
	jq_check "$result" '.isError == true'
}

@test "sdk_error_helper_minimal: defaults work" {
	result=$(mcp_error)
	printf '%s' "$result" | "${JQ_BIN}" -e '.' >/dev/null 2>&1
	jq_check "$result" '.structuredContent.error.type == "internal_error"'
	jq_check "$result" '.structuredContent.error.message == "Unknown error"'
}

@test "sdk_error_helper_minimal: returns exit code 0" {
	mcp_error "error" "message"
	rc=$?
	assert_equal "0" "$rc"
}
