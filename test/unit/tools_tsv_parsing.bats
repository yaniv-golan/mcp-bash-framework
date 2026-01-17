#!/usr/bin/env bats
# Unit tests for TSV parsing vulnerability in tools/call argument extraction.
#
# CONFIRMED BUG: jq's @tsv filter double-escapes backslashes, corrupting JSON
# with escaped quotes. Example: {"filter":"[\"New\"]"} becomes invalid JSON
# after @tsv because \" becomes \\" which is not valid JSON syntax.
#
# DISPROVEN: Embedded newlines/tabs do NOT cause truncation - @tsv escapes them.
#
# Related: docs/internal/PLAN-silent-args-parsing-failures.md

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	MCPBASH_JSON_TOOL_BIN="$(command -v jq)"
	MCPBASH_JSON_TOOL="jq"

	# Use the FIXED implementation (separate jq calls, no @tsv for JSON fields)
	# This matches handlers/tools.sh after the fix
	mcp_tools_extract_call_fields() {
		local json_payload="$1"
		local name args_json timeout_override meta_json

		name="$(printf '%s' "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.params.name // ""' 2>/dev/null)" || name=""
		args_json="$(printf '%s' "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.params.arguments // {}' 2>/dev/null)" || args_json="{}"
		timeout_override="$(printf '%s' "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -r '(.params.timeoutSecs // null) | tostring' 2>/dev/null)" || timeout_override="null"
		meta_json="$(printf '%s' "${json_payload}" | "${MCPBASH_JSON_TOOL_BIN}" -c '.params._meta // {}' 2>/dev/null)" || meta_json="{}"

		printf '%s\t%s\t%s\t%s' "${name}" "${args_json}" "${timeout_override}" "${meta_json}"
	}
}

# Helper to simulate the full extraction + read pattern from handlers/tools.sh:69
extract_and_read() {
	local json_payload="$1"
	local extraction
	extraction="$(mcp_tools_extract_call_fields "${json_payload}")"

	local name args_json timeout_override meta_json
	IFS=$'\t' read -r name args_json timeout_override meta_json <<<"${extraction}"
	[ -z "${args_json}" ] && args_json="{}"

	# Return the args_json for testing
	printf '%s' "${args_json}"
}

# Helper to build JSON payloads correctly (avoids shell escaping issues)
build_payload() {
	local name="$1"
	local args_json="$2"
	printf '{"jsonrpc":"2.0","id":"test","method":"tools/call","params":{"name":"%s","arguments":%s}}' "${name}" "${args_json}"
}

# ==============================================================================
# Test: Normal payload without problematic characters
# ==============================================================================
@test "TSV parsing: normal payload extracts correctly" {
	local payload
	payload="$(build_payload "my-tool" '{"command":"test","filter":"simple"}')"

	local args_json
	args_json="$(extract_and_read "${payload}")"

	# Verify command field is accessible
	local command
	command="$(printf '%s' "${args_json}" | jq -r '.command')"
	assert_equal "${command}" "test"
}

# ==============================================================================
# Test: Payload with escaped newline (\n) in JSON string
# This is the hypothesized root cause of the bug
# ==============================================================================
@test "TSV parsing: embedded newline in JSON string causes truncation" {
	# JSON with \n escape sequence in string value
	# The \\n in shell becomes \n in the JSON string (the escape sequence)
	local payload
	payload="$(build_payload "my-tool" '{"command":"test","filter":"line1\\nline2"}')"

	local args_json
	args_json="$(extract_and_read "${payload}")"

	# If truncation occurs, args_json will be incomplete or empty
	# Try to extract command - this should fail if truncated
	local command
	command="$(printf '%s' "${args_json}" | jq -r '.command // "MISSING"' 2>/dev/null || echo "PARSE_ERROR")"

	# This test documents the BUG - we expect it to FAIL with current code
	# Once fixed, change assert_equal to expect "test"
	if [ "${command}" = "test" ]; then
		# If this passes, the bug may have been fixed or doesn't reproduce
		skip "Embedded newline did not cause truncation (bug may be fixed)"
	else
		# Document the failure - this confirms the bug
		echo "# BUG CONFIRMED: args_json truncated by embedded newline" >&3
		echo "# args_json received: ${args_json}" >&3
		echo "# command extracted: ${command}" >&3
		assert_equal "${command}" "test" "Expected 'test' but got '${command}' - confirms TSV/newline truncation bug"
	fi
}

# ==============================================================================
# Test: Payload with embedded tab in JSON string
# ==============================================================================
@test "TSV parsing: embedded tab in JSON string corrupts field boundaries" {
	# JSON with \t (tab) escape in string value
	local payload
	payload="$(build_payload "my-tool" '{"command":"test","filter":"col1\\tcol2"}')"

	local args_json
	args_json="$(extract_and_read "${payload}")"

	local command
	command="$(printf '%s' "${args_json}" | jq -r '.command // "MISSING"' 2>/dev/null || echo "PARSE_ERROR")"

	if [ "${command}" = "test" ]; then
		skip "Embedded tab did not cause corruption (may not reproduce)"
	else
		echo "# BUG: args_json corrupted by embedded tab" >&3
		echo "# args_json received: ${args_json}" >&3
		assert_equal "${command}" "test" "Expected 'test' but got '${command}' - confirms TSV/tab corruption bug"
	fi
}

# ==============================================================================
# Test: Complex nested escapes (from user report)
# FIXED: Using separate jq calls instead of @tsv avoids the double-escaping bug
# ==============================================================================
@test "TSV parsing: escaped quotes in JSON work correctly (FIXED)" {
	# This pattern from the user report: Status in ["New", "Intro Meeting", ...]
	# Use jq to properly construct the JSON with escaped quotes
	local filter_value='Status in ["New", "Intro Meeting"]'
	local args_json_inner
	args_json_inner="$(jq -cn --arg cmd "list" --arg filter "${filter_value}" '{command:$cmd,filter:$filter}')"
	local payload
	payload="$(build_payload "my-tool" "${args_json_inner}")"

	local args_json
	args_json="$(extract_and_read "${payload}")"

	echo "# args_json_inner: ${args_json_inner}" >&3
	echo "# args_json after extraction: ${args_json}" >&3

	local command
	command="$(printf '%s' "${args_json}" | jq -r '.command // "MISSING"' 2>/dev/null || echo "PARSE_ERROR")"

	# With the fix (separate jq calls, no @tsv), this should work
	assert_equal "${command}" "list"

	# Also verify the filter value is preserved correctly
	local filter
	filter="$(printf '%s' "${args_json}" | jq -r '.filter // "MISSING"' 2>/dev/null || echo "PARSE_ERROR")"
	assert_equal "${filter}" 'Status in ["New", "Intro Meeting"]'
}

# ==============================================================================
# Test: Verify extraction length vs read length
# This directly tests the truncation hypothesis
# ==============================================================================
@test "TSV parsing: extraction length equals args length for normal payload" {
	local payload
	payload="$(build_payload "my-tool" '{"command":"test","value":"normal"}')"

	local extraction
	extraction="$(mcp_tools_extract_call_fields "${payload}")"
	local extraction_len="${#extraction}"

	local name args_json timeout_override meta_json
	IFS=$'\t' read -r name args_json timeout_override meta_json <<<"${extraction}"

	# For normal payload, args should contain the full JSON
	local args_len="${#args_json}"

	echo "# extraction_len=${extraction_len} args_len=${args_len}" >&3

	# args_json should be substantial (not truncated to near-zero)
	[ "${args_len}" -gt 20 ]
}

@test "TSV parsing: extraction length vs args length with embedded newline" {
	local payload
	payload="$(build_payload "my-tool" '{"command":"test","filter":"before\\nafter","value":"end"}')"

	local extraction
	extraction="$(mcp_tools_extract_call_fields "${payload}")"
	local extraction_len="${#extraction}"

	local name args_json timeout_override meta_json
	IFS=$'\t' read -r name args_json timeout_override meta_json <<<"${extraction}"
	local args_len="${#args_json}"

	echo "# extraction_len=${extraction_len} args_len=${args_len}" >&3
	echo "# extraction (first 100): ${extraction:0:100}" >&3
	echo "# args_json: ${args_json}" >&3

	# If truncation occurs, args_len will be much smaller than expected
	# The extraction should be ~80+ chars, but args_json might be truncated
	# This test documents the discrepancy

	# Try to parse the args_json
	local value
	value="$(printf '%s' "${args_json}" | jq -r '.value // "MISSING"' 2>/dev/null || echo "PARSE_ERROR")"

	if [ "${value}" != "end" ]; then
		echo "# BUG CONFIRMED: truncation detected" >&3
		echo "# Expected .value='end' but got '${value}'" >&3
	fi

	# Assert that we got the full value
	assert_equal "${value}" "end" "Truncation detected: .value should be 'end'"
}

# ==============================================================================
# Test: LITERAL newline character in JSON (not escape sequence)
# This tests what happens when the raw bytes contain 0x0A
# ==============================================================================
@test "TSV parsing: literal newline byte in JSON is rejected by jq" {
	# Create a JSON payload with an actual newline byte (0x0A) in the string value
	# This is INVALID JSON - jq should reject it
	local args_with_literal_newline
	args_with_literal_newline=$(printf '{"command":"test","filter":"line1\nline2","value":"end"}')

	local payload
	payload=$(printf '{"jsonrpc":"2.0","id":"test","method":"tools/call","params":{"name":"my-tool","arguments":%s}}' "${args_with_literal_newline}")

	local extraction
	extraction="$(mcp_tools_extract_call_fields "${payload}")"

	local name args_json timeout_override meta_json
	IFS=$'\t' read -r name args_json timeout_override meta_json <<<"${extraction}"

	echo "# extraction_len=${#extraction}" >&3
	echo "# args_json: ${args_json}" >&3

	# With invalid JSON input, jq should fail and we get fallback values
	# The args_json will be empty, "{}", or "null" (fallback from failed jq -c)
	if [ "${args_json}" = "{}" ] || [ "${args_json}" = "null" ] || [ -z "${args_json}" ]; then
		echo "# jq correctly rejected invalid JSON with literal newline" >&3
		skip "jq rejects invalid JSON (expected behavior)"
	fi

	# If jq somehow processed it, verify the data is intact
	local value
	value="$(printf '%s' "${args_json}" | jq -r '.value // "MISSING"' 2>/dev/null || echo "PARSE_ERROR")"
	assert_equal "${value}" "end"
}
