#!/usr/bin/env bats
# Unit layer: embedding files with --resource on mcp_result_json (2.0; it replaced mcp_result_text_with_resource).

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
		skip "JSON tooling unavailable for SDK resource helper tests"
	fi

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
}

teardown() {
	rm -rf "${TEST_TMPDIR:-}" 2>/dev/null || true
}

# Helper to extract JSON fields
jq_get() {
	printf '%s' "$1" | "${MCPBASH_JSON_TOOL_BIN}" -r "$2"
}

jq_check() {
	printf '%s' "$1" | "${MCPBASH_JSON_TOOL_BIN}" -e "$2" >/dev/null 2>&1
}

# ============================================================================
# Test 1: Basic text without resources
# ============================================================================

@test "sdk_result_resource_flag: basic text without resources" {
	: > "${MCP_TOOL_RESOURCES_FILE}"
	result=$(mcp_result_json '{"status":"done"}')
	jq_check "$result" '.isError == false'
	jq_check "$result" '.isError == false'
	# Resources file should be empty (no resources)
	[[ ! -s "${MCP_TOOL_RESOURCES_FILE}" ]]
}

# ============================================================================
# Test 2: Text with single resource
# ============================================================================

@test "sdk_result_resource_flag: text with single resource" {
	local test_file="${TEST_TMPDIR}/test.txt"
	printf 'Hello World' > "${test_file}"

	result=$(mcp_result_json '{"message":"done"}' --resource "${test_file}" --mime "text/plain")
	jq_check "$result" '.isError == false'

	# Check resources file contains JSON array with the resource
	local res_content
	res_content=$(cat "${MCP_TOOL_RESOURCES_FILE}")
	jq_check "$res_content" '.[0].path'
	jq_check "$res_content" '.[0].mimeType == "text/plain"'
}

# ============================================================================
# Test 3: Text with explicit MIME
# ============================================================================

@test "sdk_result_resource_flag: explicit MIME type preserved" {
	local test_file="${TEST_TMPDIR}/data.bin"
	printf '\x00\x01\x02' > "${test_file}"

	result=$(mcp_result_json '{"done":true}' --resource "${test_file}" --mime "application/custom")

	local res_content
	res_content=$(cat "${MCP_TOOL_RESOURCES_FILE}")
	local mime
	mime=$(jq_get "$res_content" '.[0].mimeType')
	assert_equal "application/custom" "$mime"
}

# ============================================================================
# Test 4: Text with custom URI
# ============================================================================

@test "sdk_result_resource_flag: custom URI preserved" {
	local test_file="${TEST_TMPDIR}/report.txt"
	printf 'Report content' > "${test_file}"

	result=$(mcp_result_json '{"done":true}' --resource "${test_file}" --mime "text/plain" --uri "custom://my-report")

	local res_content
	res_content=$(cat "${MCP_TOOL_RESOURCES_FILE}")
	local uri
	uri=$(jq_get "$res_content" '.[0].uri')
	assert_equal "custom://my-report" "$uri"
}

# ============================================================================
# Test 5: Multiple resources
# ============================================================================

@test "sdk_result_resource_flag: multiple resources" {
	local file1="${TEST_TMPDIR}/one.txt"
	local file2="${TEST_TMPDIR}/two.txt"
	printf 'File 1' > "${file1}"
	printf 'File 2' > "${file2}"

	result=$(mcp_result_json '{"count":2}' \
		--resource "${file1}" --mime "text/plain" \
		--resource "${file2}" --mime "text/plain")

	local res_content
	res_content=$(cat "${MCP_TOOL_RESOURCES_FILE}")
	local count
	count=$(jq_get "$res_content" 'length')
	assert_equal "2" "$count"
}

# ============================================================================
# Test 6: no --mime leaves detection to the server
# ============================================================================

@test "sdk_result_resource_flag: no --mime leaves mimeType null for server detection" {
	local test_file="${TEST_TMPDIR}/test.json"
	printf '{"a":1}' > "${test_file}"

	result=$(mcp_result_json '{"done":true}' --resource "${test_file}")

	local res_content
	res_content=$(cat "${MCP_TOOL_RESOURCES_FILE}")
	# The server detects the type; a declared value would become the label.
	jq_check "$res_content" '.[0] | has("mimeType") and .mimeType == null'
	jq_check "$res_content" '.[0].path == "'"${test_file}"'"'
}

# ============================================================================
# Test 7: Missing MCP_TOOL_RESOURCES_FILE logs warning
# ============================================================================

@test "sdk_result_resource_flag: missing MCP_TOOL_RESOURCES_FILE logs warning" {
	local test_file="${TEST_TMPDIR}/test.txt"
	printf 'content' > "${test_file}"

	local log_file
	log_file=$(mktemp)
	MCP_LOG_STREAM="$log_file"
	export MCP_LOG_STREAM

	# Unset the resources file
	unset MCP_TOOL_RESOURCES_FILE

	result=$(mcp_result_json '{"done":true}' --resource "${test_file}" --mime "text/plain")

	# Should still succeed
	jq_check "$result" '.isError == false'

	# Should log warning
	log_content=$(cat "$log_file")
	rm -f "$log_file"
	[[ "$log_content" == *'MCP_TOOL_RESOURCES_FILE not set'* ]]
}

# ============================================================================
# Test 8: Non-readable file skipped with warning
# ============================================================================

@test "sdk_result_resource_flag: non-readable file skipped" {
	local test_file="${TEST_TMPDIR}/missing.txt"
	# File doesn't exist

	local log_file
	log_file=$(mktemp)
	MCP_LOG_STREAM="$log_file"
	export MCP_LOG_STREAM

	result=$(mcp_result_json '{"done":true}' --resource "${test_file}" --mime "text/plain")

	# Should still succeed
	jq_check "$result" '.isError == false'

	# Resources file should have empty array
	local res_content
	res_content=$(cat "${MCP_TOOL_RESOURCES_FILE}")
	local count
	count=$(jq_get "$res_content" 'length')
	assert_equal "0" "$count"

	# Should log warning
	log_content=$(cat "$log_file")
	rm -f "$log_file"
	[[ "$log_content" == *'not a readable file'* ]]
}

# ============================================================================
# Test 9: Directory path skipped
# ============================================================================

@test "sdk_result_resource_flag: directory path skipped" {
	local log_file
	log_file=$(mktemp)
	MCP_LOG_STREAM="$log_file"
	export MCP_LOG_STREAM

	result=$(mcp_result_json '{"done":true}' --resource "${TEST_TMPDIR}" --mime "text/plain")

	# Should still succeed
	jq_check "$result" '.isError == false'

	# Resources file should have empty array
	local res_content
	res_content=$(cat "${MCP_TOOL_RESOURCES_FILE}")
	local count
	count=$(jq_get "$res_content" 'length')
	assert_equal "0" "$count"

	rm -f "$log_file"
}

# ============================================================================
# Test 10: Empty data argument
# ============================================================================

@test "sdk_result_resource_flag: empty data produces error response" {
	result=$(mcp_result_json "")
	# mcp_result_success rejects empty input
	jq_check "$result" '.isError == true'
}

# ============================================================================
# Test 11: JSON object data
# ============================================================================

@test "sdk_result_resource_flag: JSON object data passed correctly" {
	result=$(mcp_result_json '{"key":"value","num":42}')
	jq_check "$result" '.structuredContent.key == "value"'
	jq_check "$result" '.structuredContent.num == 42'
}

# ============================================================================
# Test 12: Always returns 0
# ============================================================================

@test "sdk_result_resource_flag: always returns exit code 0" {
	local test_file="${TEST_TMPDIR}/test.txt"
	printf 'content' > "${test_file}"

	mcp_result_json '{"done":true}' --resource "${test_file}" --mime "text/plain"
	rc=$?
	assert_equal "0" "$rc"
}

@test "sdk_result_resource_flag: returns 0 even with missing file" {
	mcp_result_json '{"done":true}' --resource "/nonexistent/path.txt" --mime "text/plain"
	rc=$?
	assert_equal "0" "$rc"
}

# ============================================================================
# Test 13: Unknown flags logged
# ============================================================================

@test "sdk_result_resource_flag: unknown flags ignored" {
	local test_file="${TEST_TMPDIR}/test.txt"
	printf 'content' > "${test_file}"

	local log_file
	log_file=$(mktemp)
	MCP_LOG_STREAM="$log_file"
	export MCP_LOG_STREAM

	result=$(mcp_result_json '{"done":true}' --resource "${test_file}" --mime "text/plain" --unknown "value")

	# Should still succeed and embed the file (mcp_result_json ignores
	# options it doesn't know)
	jq_check "$result" '.isError == false'
	rm -f "$log_file"
	[[ "$(cat "${MCP_TOOL_RESOURCES_FILE}")" == *test.txt* ]]
}

# ============================================================================
# Test 14: Path with tab character
# ============================================================================

@test "sdk_result_resource_flag: path with tab character handled" {
	local test_file="${TEST_TMPDIR}/file	with	tabs.txt"
	printf 'content' > "${test_file}"

	result=$(mcp_result_json '{"done":true}' --resource "${test_file}" --mime "text/plain")
	jq_check "$result" '.isError == false'

	# Verify the path was JSON-escaped correctly
	local res_content
	res_content=$(cat "${MCP_TOOL_RESOURCES_FILE}")
	# Must be valid JSON
	printf '%s' "$res_content" | "${MCPBASH_JSON_TOOL_BIN}" -e '.' >/dev/null 2>&1
}

# ============================================================================
# Test 15: Path with pipe character
# ============================================================================

@test "sdk_result_resource_flag: path with pipe character handled" {
	local test_file="${TEST_TMPDIR}/file|with|pipes.txt"
	printf 'content' > "${test_file}"

	result=$(mcp_result_json '{"done":true}' --resource "${test_file}" --mime "text/plain")
	jq_check "$result" '.isError == false'

	# Verify the path was preserved correctly
	local res_content
	res_content=$(cat "${MCP_TOOL_RESOURCES_FILE}")
	local path
	path=$(jq_get "$res_content" '.[0].path')
	[[ "$path" == *"|"* ]]
}

# ============================================================================
# Test 16: Symlink to file followed
# ============================================================================

@test "sdk_result_resource_flag: symlink to file followed" {
	local target="${TEST_TMPDIR}/target.txt"
	local link="${TEST_TMPDIR}/link.txt"
	printf 'target content' > "${target}"
	ln -s "${target}" "${link}"

	result=$(mcp_result_json '{"done":true}' --resource "${link}" --mime "text/plain")
	jq_check "$result" '.isError == false'

	local res_content
	res_content=$(cat "${MCP_TOOL_RESOURCES_FILE}")
	local count
	count=$(jq_get "$res_content" 'length')
	assert_equal "1" "$count"
}

# ============================================================================
# Test 17: Symlink to directory skipped
# ============================================================================

@test "sdk_result_resource_flag: symlink to directory skipped" {
	local dir="${TEST_TMPDIR}/subdir"
	local link="${TEST_TMPDIR}/dirlink"
	mkdir -p "${dir}"
	ln -s "${dir}" "${link}"

	result=$(mcp_result_json '{"done":true}' --resource "${link}" --mime "text/plain")
	jq_check "$result" '.isError == false'

	local res_content
	res_content=$(cat "${MCP_TOOL_RESOURCES_FILE}")
	local count
	count=$(jq_get "$res_content" 'length')
	assert_equal "0" "$count"
}

# ============================================================================
# Test 18: binary file without --mime
# ============================================================================

@test "sdk_result_resource_flag: binary file without --mime is left to the server" {
	local test_file="${TEST_TMPDIR}/test.bin"
	printf '\x00\x01\x02' > "${test_file}"

	result=$(mcp_result_json '{"done":true}' --resource "${test_file}")
	jq_check "$result" '.isError == false'

	# No SDK-side guess: the server detects the type when it embeds the file
	local res_content
	res_content=$(cat "${MCP_TOOL_RESOURCES_FILE}")
	jq_check "$res_content" '.[0].mimeType == null'
}

# ============================================================================
# Test 19: --mime at end without value
# ============================================================================

@test "sdk_result_resource_flag: --mime at end without value leaves detection to the server" {
	local test_file="${TEST_TMPDIR}/test.txt"
	printf 'content' > "${test_file}"

	# --mime with missing value at end is the same as no --mime
	result=$(mcp_result_json '{"done":true}' --resource "${test_file}" --mime)
	jq_check "$result" '.isError == false'

	local res_content
	res_content=$(cat "${MCP_TOOL_RESOURCES_FILE}")
	jq_check "$res_content" '.[0].mimeType == null'
}

# ============================================================================
# Test 20: --resource "" (empty value) skipped
# ============================================================================

@test "sdk_result_resource_flag: empty path value skipped with debug log" {
	local log_file
	log_file=$(mktemp)
	MCP_LOG_STREAM="$log_file"
	export MCP_LOG_STREAM

	result=$(mcp_result_json '{"done":true}' --resource "" --mime "text/plain")
	jq_check "$result" '.isError == false'

	# Empty path is added to array but skipped in loop, resulting in empty JSON array
	local res_content
	res_content=$(cat "${MCP_TOOL_RESOURCES_FILE}")
	[[ "$res_content" == "[]" ]]

	# Should log that it skipped the path
	log_content=$(cat "$log_file")
	rm -f "$log_file"
	[[ "$log_content" == *'skipping'* ]]
}

# ============================================================================
# Test 21: Broken symlink skipped
# ============================================================================

@test "sdk_result_resource_flag: broken symlink skipped" {
	local link="${TEST_TMPDIR}/broken_link"
	ln -s "/nonexistent/target" "${link}"

	local log_file
	log_file=$(mktemp)
	MCP_LOG_STREAM="$log_file"
	export MCP_LOG_STREAM

	result=$(mcp_result_json '{"done":true}' --resource "${link}" --mime "text/plain")
	jq_check "$result" '.isError == false'

	local res_content
	res_content=$(cat "${MCP_TOOL_RESOURCES_FILE}")
	local count
	count=$(jq_get "$res_content" 'length')
	assert_equal "0" "$count"

	rm -f "$log_file"
}

# ============================================================================
# Test 22: Output is valid JSON array
# ============================================================================

@test "sdk_result_resource_flag: output is valid JSON array" {
	local file1="${TEST_TMPDIR}/one.txt"
	local file2="${TEST_TMPDIR}/two.txt"
	printf 'content 1' > "${file1}"
	printf 'content 2' > "${file2}"

	result=$(mcp_result_json '{"done":true}' \
		--resource "${file1}" --mime "text/plain" --uri "uri://one" \
		--resource "${file2}" --mime "text/html" --uri "uri://two")

	local res_content
	res_content=$(cat "${MCP_TOOL_RESOURCES_FILE}")

	# Must be valid JSON array
	jq_check "$res_content" 'type == "array"'

	# Each element must have path, mimeType, uri fields
	jq_check "$res_content" '.[0] | has("path") and has("mimeType") and has("uri")'
	jq_check "$res_content" '.[1] | has("path") and has("mimeType") and has("uri")'
}

# ============================================================================
# Test 23: Device file path skipped
# ============================================================================

@test "sdk_result_resource_flag: device file skipped" {
	# /dev/null is a device, not a regular file
	result=$(mcp_result_json '{"done":true}' --resource "/dev/null" --mime "text/plain")
	jq_check "$result" '.isError == false'

	local res_content
	res_content=$(cat "${MCP_TOOL_RESOURCES_FILE}")
	local count
	count=$(jq_get "$res_content" 'length')
	assert_equal "0" "$count"
}

# ============================================================================
# Test 24: Two helper calls - second replaces first
# ============================================================================

@test "sdk_result_resource_flag: second call replaces first" {
	local file1="${TEST_TMPDIR}/first.txt"
	local file2="${TEST_TMPDIR}/second.txt"
	printf 'first' > "${file1}"
	printf 'second' > "${file2}"

	# First call
	mcp_result_json '{"call":1}' --resource "${file1}" --mime "text/plain" >/dev/null

	# Second call should overwrite
	mcp_result_json '{"call":2}' --resource "${file2}" --mime "text/html" >/dev/null

	local res_content
	res_content=$(cat "${MCP_TOOL_RESOURCES_FILE}")

	# Should only have one resource (from second call)
	local count
	count=$(jq_get "$res_content" 'length')
	assert_equal "1" "$count"

	# Should be from second call
	local mime
	mime=$(jq_get "$res_content" '.[0].mimeType')
	assert_equal "text/html" "$mime"
}

# ============================================================================
# Test 25: Direct TSV write then helper - helper overwrites
# ============================================================================

@test "sdk_result_resource_flag: helper overwrites direct TSV write" {
	local test_file="${TEST_TMPDIR}/test.txt"
	printf 'content' > "${test_file}"

	# Write TSV directly first
	printf '%s\ttext/plain\n' "${test_file}" > "${MCP_TOOL_RESOURCES_FILE}"

	# Helper should overwrite
	mcp_result_json '{"done":true}' --resource "${test_file}" --mime "application/json" >/dev/null

	local res_content
	res_content=$(cat "${MCP_TOOL_RESOURCES_FILE}")

	# Should be valid JSON (not TSV)
	jq_check "$res_content" 'type == "array"'

	# Should have the new MIME type
	local mime
	mime=$(jq_get "$res_content" '.[0].mimeType')
	assert_equal "application/json" "$mime"
}
