#!/usr/bin/env bats
# Unit layer: SDK mcp_result_text_with_resource helper in minimal mode (no jq).

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

	# Create temp directory for test files
	TEST_TMPDIR=$(mktemp -d)
	export TEST_TMPDIR

	# Create temp file for MCP_TOOL_RESOURCES_FILE
	MCP_TOOL_RESOURCES_FILE=$(mktemp "${TEST_TMPDIR}/resources.XXXXXX")
	export MCP_TOOL_RESOURCES_FILE

	# For assertions, we need jq - use system jq directly
	JQ_BIN="$(command -v jq || command -v gojq || true)"
	if [ -z "${JQ_BIN}" ]; then
		skip "Need jq or gojq for test assertions (even though SDK is in minimal mode)"
	fi
}

teardown() {
	rm -rf "${TEST_TMPDIR:-}" 2>/dev/null || true
}

jq_check() {
	printf '%s' "$1" | "${JQ_BIN}" -e "$2" >/dev/null 2>&1
}

jq_get() {
	printf '%s' "$1" | "${JQ_BIN}" -r "$2"
}

# ============================================================================
# Test 1: Works in minimal mode
# ============================================================================

@test "sdk_result_text_with_resource_minimal: produces valid JSON" {
	local test_file="${TEST_TMPDIR}/test.txt"
	printf 'content' > "${test_file}"

	result=$(mcp_result_text_with_resource '{"done":true}' --path "${test_file}" --mime "text/plain")

	# Must be valid JSON (critical assertion)
	printf '%s' "$result" | "${JQ_BIN}" -e '.' >/dev/null 2>&1
	jq_check "$result" '.isError == false'
}

# ============================================================================
# Test 2: Resource spec written even in minimal mode
# ============================================================================

@test "sdk_result_text_with_resource_minimal: resource spec written" {
	local test_file="${TEST_TMPDIR}/test.txt"
	printf 'content' > "${test_file}"

	result=$(mcp_result_text_with_resource '{"done":true}' --path "${test_file}" --mime "text/plain")

	# Resource file should have content
	[[ -s "${MCP_TOOL_RESOURCES_FILE}" ]]

	# Should be valid JSON
	local res_content
	res_content=$(cat "${MCP_TOOL_RESOURCES_FILE}")
	printf '%s' "$res_content" | "${JQ_BIN}" -e '.' >/dev/null 2>&1

	# Should have the path
	jq_check "$res_content" '.[0].path'
}

# ============================================================================
# Test 3: Returns exit code 0
# ============================================================================

@test "sdk_result_text_with_resource_minimal: returns exit code 0" {
	local test_file="${TEST_TMPDIR}/test.txt"
	printf 'content' > "${test_file}"

	mcp_result_text_with_resource '{"done":true}' --path "${test_file}" --mime "text/plain"
	rc=$?
	assert_equal "0" "$rc"
}

# ============================================================================
# Test 4: MIME fallback in minimal mode
# ============================================================================

@test "sdk_result_text_with_resource_minimal: MIME fallback when auto-detect unavailable" {
	local test_file="${TEST_TMPDIR}/test.bin"
	printf '\x00\x01\x02' > "${test_file}"

	# In minimal mode, MIME detection will use fallback
	result=$(mcp_result_text_with_resource '{"done":true}' --path "${test_file}")
	jq_check "$result" '.isError == false'

	# Should have a MIME type (fallback to application/octet-stream)
	local res_content
	res_content=$(cat "${MCP_TOOL_RESOURCES_FILE}")
	local mime
	mime=$(jq_get "$res_content" '.[0].mimeType')
	assert_equal "application/octet-stream" "$mime"
}
