#!/usr/bin/env bats
# Unit layer: SDK mcp_error convenience helper function.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# Ensure JSON tooling is available so helpers exercise the jq/gojq path.
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"

	MCPBASH_FORCE_MINIMAL=false
	mcp_runtime_detect_json_tool
	if [ "${MCPBASH_MODE}" = "minimal" ]; then
		skip "JSON tooling unavailable for SDK error helper tests"
	fi

	# shellcheck source=sdk/tool-sdk.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/sdk/tool-sdk.sh"

	# Suppress logging during tests
	MCP_LOG_STREAM=""
	export MCP_LOG_STREAM
}

# Helper to extract JSON fields
jq_get() {
	printf '%s' "$1" | "${MCPBASH_JSON_TOOL_BIN}" -r "$2"
}

jq_check() {
	printf '%s' "$1" | "${MCPBASH_JSON_TOOL_BIN}" -e "$2" >/dev/null 2>&1
}

# ============================================================================
# Test 1: Basic error with type and message
# ============================================================================

@test "sdk_error_helper: basic error with type and message" {
	result=$(mcp_error "not_found" "User not found")
	jq_check "$result" '.isError == true'
	jq_check "$result" '.structuredContent.error.type == "not_found"'
	jq_check "$result" '.structuredContent.error.message == "User not found"'
}

# ============================================================================
# Test 2: Error with hint - verify field present
# ============================================================================

@test "sdk_error_helper: error with hint includes hint field" {
	result=$(mcp_error "validation_error" "Count must be positive" --hint "Try count=10")
	jq_check "$result" '.structuredContent.error.hint == "Try count=10"'
	jq_check "$result" '.structuredContent.error.type == "validation_error"'
}

# ============================================================================
# Test 3: Error with data object - verify JSON structure preserved
# ============================================================================

@test "sdk_error_helper: error with data object preserves JSON structure" {
	result=$(mcp_error "validation_error" "Value out of range" --data '{"min": 1, "max": 100}')
	jq_check "$result" '.structuredContent.error.data.min == 1'
	jq_check "$result" '.structuredContent.error.data.max == 100'
}

# ============================================================================
# Test 4: Error with both hint and data
# ============================================================================

@test "sdk_error_helper: error with both hint and data" {
	result=$(mcp_error "validation_error" "Invalid value" --hint "Check bounds" --data '{"received": -5}')
	jq_check "$result" '.structuredContent.error.hint == "Check bounds"'
	jq_check "$result" '.structuredContent.error.data.received == -5'
}

# ============================================================================
# Test 5: Empty/missing type defaults to internal_error
# ============================================================================

@test "sdk_error_helper: empty type defaults to internal_error" {
	result=$(mcp_error "" "Something went wrong")
	jq_check "$result" '.structuredContent.error.type == "internal_error"'
}

@test "sdk_error_helper: missing type defaults to internal_error" {
	result=$(mcp_error)
	jq_check "$result" '.structuredContent.error.type == "internal_error"'
}

# ============================================================================
# Test 6: Empty/missing message defaults to Unknown error
# ============================================================================

@test "sdk_error_helper: empty message defaults to Unknown error" {
	result=$(mcp_error "test_error" "")
	jq_check "$result" '.structuredContent.error.message == "Unknown error"'
}

@test "sdk_error_helper: missing message defaults to Unknown error" {
	result=$(mcp_error "test_error")
	jq_check "$result" '.structuredContent.error.message == "Unknown error"'
}

# ============================================================================
# Test 7: Special characters in message properly escaped
# ============================================================================

@test "sdk_error_helper: special characters in message escaped" {
	result=$(mcp_error "test" 'Line1\nLine2 and "quotes"')
	# Must be valid JSON
	printf '%s' "$result" | "${MCPBASH_JSON_TOOL_BIN}" -e '.' >/dev/null 2>&1
	jq_check "$result" '.isError == true'
}

@test "sdk_error_helper: unicode in message" {
	result=$(mcp_error "test" "Error: 中文 🎉")
	msg=$(jq_get "$result" '.structuredContent.error.message')
	[[ "$msg" == *"中文"* ]]
	[[ "$msg" == *"🎉"* ]]
}

# ============================================================================
# Test 8: Invalid --data JSON wraps raw value
# ============================================================================

@test "sdk_error_helper: invalid data JSON wraps as _invalid_json" {
	result=$(mcp_error "test" "message" --data 'not valid json')
	jq_check "$result" '.structuredContent.error.data._invalid_json == "not valid json"'
}

# ============================================================================
# Test 10: Always returns exit code 0
# ============================================================================

@test "sdk_error_helper: always returns exit code 0" {
	mcp_error "error" "message"
	rc=$?
	assert_equal "0" "$rc"
}

@test "sdk_error_helper: returns 0 even with invalid data" {
	mcp_error "error" "message" --data 'broken'
	rc=$?
	assert_equal "0" "$rc"
}

# ============================================================================
# Test 13: Unknown flags are silently ignored
# ============================================================================

@test "sdk_error_helper: unknown flags silently ignored" {
	result=$(mcp_error "test" "message" --unknown "value" --also-unknown)
	jq_check "$result" '.structuredContent.error.type == "test"'
	jq_check "$result" '.structuredContent.error.message == "message"'
}

# ============================================================================
# Additional: hint without data, data without hint
# ============================================================================

@test "sdk_error_helper: hint only (no data field)" {
	result=$(mcp_error "test" "message" --hint "try this")
	jq_check "$result" '.structuredContent.error.hint == "try this"'
	# data should not be present
	data=$(jq_get "$result" '.structuredContent.error.data // "ABSENT"')
	assert_equal "ABSENT" "$data"
}

@test "sdk_error_helper: data only (no hint field)" {
	result=$(mcp_error "test" "message" --data '{"key": "val"}')
	jq_check "$result" '.structuredContent.error.data.key == "val"'
	# hint should not be present
	hint=$(jq_get "$result" '.structuredContent.error.hint // "ABSENT"')
	assert_equal "ABSENT" "$hint"
}

# ============================================================================
# Verify output structure matches mcp_result_error
# ============================================================================

@test "sdk_error_helper: output has correct CallToolResult structure" {
	result=$(mcp_error "not_found" "Resource not found")
	# Check all required CallToolResult fields
	jq_check "$result" '.content | type == "array"'
	jq_check "$result" '.content[0].type == "text"'
	jq_check "$result" '.structuredContent.success == false'
	jq_check "$result" '.isError == true'
}

# ============================================================================
# Test 11: Debug logging triggered for all errors
# ============================================================================

@test "sdk_error_helper: debug logging triggered for all errors" {
	local log_file
	log_file=$(mktemp)
	MCP_LOG_STREAM="$log_file"
	export MCP_LOG_STREAM

	mcp_error "test_type" "test message" >/dev/null

	# Verify debug log was written
	log_content=$(cat "$log_file")
	rm -f "$log_file"

	# Should contain debug level log with type info
	[[ "$log_content" == *'"level":"debug"'* ]]
	[[ "$log_content" == *'type=test_type'* ]]
}

# ============================================================================
# Test 12: Warn logging triggered only when hint provided
# ============================================================================

@test "sdk_error_helper: warn logging only when hint provided" {
	local log_file
	log_file=$(mktemp)
	MCP_LOG_STREAM="$log_file"
	export MCP_LOG_STREAM

	# Error without hint - should NOT have warning
	mcp_error "test" "no hint error" >/dev/null
	log_content=$(cat "$log_file")
	if [[ "$log_content" == *'"level":"warning"'* ]]; then
		rm -f "$log_file"
		fail "Warning logged without hint"
	fi

	# Clear and test with hint
	: >"$log_file"
	mcp_error "test" "with hint" --hint "try this" >/dev/null
	log_content=$(cat "$log_file")
	rm -f "$log_file"

	# Should contain warning level log
	[[ "$log_content" == *'"level":"warning"'* ]]
	[[ "$log_content" == *'hint'* ]]
}
