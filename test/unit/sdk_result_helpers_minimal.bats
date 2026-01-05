#!/usr/bin/env bats
# Unit layer: SDK CallToolResult helpers in minimal mode (no jq).

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
# Minimal mode tests
# ============================================================================

@test "sdk_result_helpers_minimal: mcp_result_success produces valid JSON" {
	result=$(mcp_result_success '{"foo":"bar"}')
	# Must be valid JSON
	printf '%s' "$result" | "${JQ_BIN}" -e '.' >/dev/null 2>&1
	jq_check "$result" '.isError == false'
	jq_check "$result" '.structuredContent.success == true'
}

@test "sdk_result_helpers_minimal: mcp_result_error produces valid JSON even with invalid input" {
	result=$(mcp_result_error 'this is not json')
	# Must be valid JSON (this is the critical assertion)
	printf '%s' "$result" | "${JQ_BIN}" -e '.' >/dev/null 2>&1
	jq_check "$result" '.isError == true'
	raw=$(jq_get "$result" '.structuredContent.error.raw')
	assert_equal "this is not json" "$raw"
}

@test "sdk_result_helpers_minimal: mcp_result_error handles empty input" {
	result=$(mcp_result_error '')
	printf '%s' "$result" | "${JQ_BIN}" -e '.' >/dev/null 2>&1
	jq_check "$result" '.isError == true'
}

@test "sdk_result_helpers_minimal: mcp_json_truncate adds warning but returns data" {
	result=$(mcp_json_truncate '[1,2,3]' 10)
	printf '%s' "$result" | "${JQ_BIN}" -e '.' >/dev/null 2>&1
	warning=$(jq_get "$result" '._warning')
	[[ "$warning" == *minimal* ]]
	jq_check "$result" '.truncated == false'
}

@test "sdk_result_helpers_minimal: mcp_is_valid_json returns 0 (assumes valid)" {
	mcp_is_valid_json 'anything'
}

@test "sdk_result_helpers_minimal: mcp_result_success with special characters produces valid JSON" {
	result=$(mcp_result_success '{"msg":"line1\nline2\ttab"}')
	printf '%s' "$result" | "${JQ_BIN}" -e '.' >/dev/null 2>&1
}

@test "sdk_result_helpers_minimal: mcp_result_success size threshold works" {
	# Create a response that exceeds the small threshold
	result=$(mcp_result_success '{"key":"value"}' 10)
	printf '%s' "$result" | "${JQ_BIN}" -e '.' >/dev/null 2>&1
	text=$(jq_get "$result" '.content[0].text')
	# Should be the summary since envelope > 10 bytes
	[[ "$text" == *too*large* ]]
}
