#!/usr/bin/env bats
# Unit layer: SDK CallToolResult helper functions (mcp_result_success, mcp_result_error, mcp_json_truncate).

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
		skip "JSON tooling unavailable for SDK result helper tests"
	fi

	# shellcheck source=sdk/tool-sdk.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/sdk/tool-sdk.sh"
}

# Helper to extract JSON fields
jq_get() {
	printf '%s' "$1" | "${MCPBASH_JSON_TOOL_BIN}" -r "$2"
}

jq_check() {
	printf '%s' "$1" | "${MCPBASH_JSON_TOOL_BIN}" -e "$2" >/dev/null 2>&1
}

# ============================================================================
# mcp_result_success tests
# ============================================================================

@test "sdk_result_helpers: mcp_result_success wraps simple value" {
	result=$(mcp_result_success '{"foo": "bar"}')
	jq_check "$result" '.structuredContent.success == true'
	jq_check "$result" '.structuredContent.result.foo == "bar"'
	jq_check "$result" '.isError == false'
}

@test "sdk_result_helpers: mcp_result_success always wraps data including objects with result field" {
	result=$(mcp_result_success '{"result": "pass", "score": 95}')
	jq_check "$result" '.structuredContent.result.result == "pass"'
	jq_check "$result" '.structuredContent.result.score == 95'
	jq_check "$result" '.structuredContent.success == true'
}

@test "sdk_result_helpers: mcp_result_success summarizes large responses" {
	large=$(${MCPBASH_JSON_TOOL_BIN} -n '[range(1000)] | map({id: ., data: ([range(100) | "x"] | add)})')
	result=$(mcp_result_success "$large" 100)
	text=$(jq_get "$result" '.content[0].text')
	[[ "$text" == Success:* ]]
	[[ "$text" == *array* ]]
}

@test "sdk_result_helpers: mcp_result_success content.text is NOT double-encoded" {
	result=$(mcp_result_success '{"foo": "bar"}')
	text=$(jq_get "$result" '.content[0].text')
	# If double-encoded, parsing would fail or give wrong result
	parsed_success=$(printf '%s' "$text" | "${MCPBASH_JSON_TOOL_BIN}" -r '.success')
	assert_equal "true" "$parsed_success"
}

@test "sdk_result_helpers: mcp_result_success handles special characters" {
	result=$(mcp_result_success '{"msg": "line1\nline2", "quote": "he said \"hi\""}')
	jq_check "$result" '.isError == false'
}

@test "sdk_result_helpers: mcp_result_success handles empty array" {
	result=$(mcp_result_success '[]')
	jq_check "$result" '.structuredContent.success == true'
	jq_check "$result" '.structuredContent.result == []'
}

@test "sdk_result_helpers: mcp_result_success handles deeply nested objects" {
	result=$(mcp_result_success '{"a":{"b":{"c":{"d":1}}}}')
	val=$(jq_get "$result" '.structuredContent.result.a.b.c.d')
	assert_equal "1" "$val"
}

@test "sdk_result_helpers: mcp_result_success handles unicode" {
	result=$(mcp_result_success '{"emoji":"🎉","chinese":"中文"}')
	emoji=$(jq_get "$result" '.structuredContent.result.emoji')
	assert_equal "🎉" "$emoji"
}

@test "sdk_result_helpers: mcp_result_success handles null values" {
	result=$(mcp_result_success '{"val":null}')
	jq_check "$result" '.structuredContent.result.val == null'
}

@test "sdk_result_helpers: mcp_result_success rejects empty input but returns 0" {
	result=$(mcp_result_success '')
	rc=$?
	assert_equal "0" "$rc"
	jq_check "$result" '.isError == true'
}

@test "sdk_result_helpers: mcp_result_success handles JSON false value" {
	result=$(mcp_result_success 'false')
	jq_check "$result" '.structuredContent.success == true'
	jq_check "$result" '.structuredContent.result == false'
	jq_check "$result" '.isError == false'
}

@test "sdk_result_helpers: mcp_result_success handles JSON null value" {
	result=$(mcp_result_success 'null')
	jq_check "$result" '.structuredContent.success == true'
	jq_check "$result" '.structuredContent.result == null'
	jq_check "$result" '.isError == false'
}

@test "sdk_result_helpers: mcp_result_success rejects multiple JSON values" {
	result=$(mcp_result_success '1 2 3')
	jq_check "$result" '.isError == true'
	msg=$(jq_get "$result" '.structuredContent.error.message')
	[[ "$msg" == *multiple* ]]
}

@test "sdk_result_helpers: mcp_result_success always returns 0 even on validation error" {
	result=$(mcp_result_success 'invalid json')
	rc=$?
	assert_equal "0" "$rc"
	jq_check "$result" '.isError == true'
}

@test "sdk_result_helpers: mcp_result_success uses tojson for argv safety" {
	large=$(${MCPBASH_JSON_TOOL_BIN} -n '[range(1000)] | map({id: ., data: ([range(100) | "x"] | add)})')
	result=$(mcp_result_success "$large")
	jq_check "$result" '.isError == false'
	jq_check "$result" '.structuredContent.success == true'
}

@test "sdk_result_helpers: mcp_result_success handles non-numeric max_text_bytes" {
	result=$(mcp_result_success '{"key":"value"}' "not-a-number")
	jq_check "$result" '.isError == false'
	jq_check "$result" '.structuredContent.success == true'
}

@test "sdk_result_helpers: mcp_result_success truncates correctly at emoji boundary" {
	result=$(mcp_result_success '{"emoji":"🎉🎉🎉"}' 50)
	jq_check "$result" '.isError == false'
	text=$(jq_get "$result" '.content[0].text')
	[ -n "$text" ]
}

# ============================================================================
# mcp_result_error tests
# ============================================================================

@test "sdk_result_helpers: mcp_result_error sets isError true" {
	result=$(mcp_result_error '{"type": "not_found", "message": "User not found"}')
	jq_check "$result" '.isError == true'
	text=$(jq_get "$result" '.content[0].text')
	assert_equal "User not found" "$text"
}

@test "sdk_result_helpers: mcp_result_error handles empty input gracefully" {
	result=$(mcp_result_error '')
	jq_check "$result" '.isError == true'
	# Must be valid JSON
	printf '%s' "$result" | "${MCPBASH_JSON_TOOL_BIN}" -e '.' >/dev/null 2>&1
}

@test "sdk_result_helpers: mcp_result_error handles invalid JSON input" {
	result=$(mcp_result_error 'this is not json')
	jq_check "$result" '.isError == true'
	raw=$(jq_get "$result" '.structuredContent.error.raw')
	assert_equal "this is not json" "$raw"
}

@test "sdk_result_helpers: mcp_result_error always returns 0" {
	result=$(mcp_result_error '{"type":"test","message":"test"}')
	rc=$?
	assert_equal "0" "$rc"
}

@test "sdk_result_helpers: mcp_result_error handles valid non-object JSON" {
	result=$(mcp_result_error '"just a string"')
	jq_check "$result" '.isError == true'
	msg=$(jq_get "$result" '.structuredContent.error.message')
	[[ "$msg" == *object* ]]
}

@test "sdk_result_helpers: mcp_result_error handles array input" {
	result=$(mcp_result_error '[]')
	jq_check "$result" '.isError == true'
	msg=$(jq_get "$result" '.structuredContent.error.message')
	[[ "$msg" == *object* ]]
}

@test "sdk_result_helpers: mcp_result_error with non-string message uses tostring" {
	result=$(mcp_result_error '{"type":"test","message":42}')
	jq_check "$result" '.isError == true'
	text=$(jq_get "$result" '.content[0].text')
	assert_equal "42" "$text"
}

# ============================================================================
# mcp_is_valid_json tests
# ============================================================================

@test "sdk_result_helpers: mcp_is_valid_json returns 0 for false" {
	mcp_is_valid_json 'false'
}

@test "sdk_result_helpers: mcp_is_valid_json returns 0 for null" {
	mcp_is_valid_json 'null'
}

@test "sdk_result_helpers: mcp_is_valid_json returns 1 for empty string" {
	run mcp_is_valid_json ''
	assert_failure
}

@test "sdk_result_helpers: mcp_is_valid_json returns 1 for whitespace-only" {
	run mcp_is_valid_json '   '
	assert_failure
}

@test "sdk_result_helpers: mcp_is_valid_json returns 1 for multiple JSON values" {
	run mcp_is_valid_json '1 2'
	assert_failure
}

@test "sdk_result_helpers: mcp_is_valid_json returns 1 for invalid JSON" {
	run mcp_is_valid_json 'not valid json'
	assert_failure
}

# ============================================================================
# mcp_byte_length tests
# ============================================================================

@test "sdk_result_helpers: mcp_byte_length counts bytes correctly" {
	len=$(mcp_byte_length "hello")
	assert_equal "5" "$len"
}

@test "sdk_result_helpers: mcp_byte_length handles unicode" {
	# 🎉 is 4 bytes in UTF-8
	len=$(mcp_byte_length "🎉")
	assert_equal "4" "$len"
}

# ============================================================================
# mcp_json_truncate tests
# ============================================================================

@test "sdk_result_helpers: mcp_json_truncate returns small arrays unchanged" {
	result=$(mcp_json_truncate '[1,2,3]' 1000)
	jq_check "$result" '.truncated == false'
	jq_check "$result" '.result == [1,2,3]'
}

@test "sdk_result_helpers: mcp_json_truncate binary searches to max fit" {
	large=$(${MCPBASH_JSON_TOOL_BIN} -n '[range(100)] | map({id: ., pad: ([range(50) | "x"] | add)})')
	result=$(mcp_json_truncate "$large" 500)
	jq_check "$result" '.truncated == true'
	jq_check "$result" '.kept < .total'
	jq_check "$result" '.result | type == "array"'
}

@test "sdk_result_helpers: mcp_json_truncate handles .results wrapper" {
	data='{"results": [1,2,3,4,5], "meta": "preserved"}'
	result=$(mcp_json_truncate "$data" 50)
	jq_check "$result" '.result.meta == "preserved"'
	jq_check "$result" '.result.results | type == "array"'
}

@test "sdk_result_helpers: mcp_json_truncate early-exits when first element exceeds limit" {
	large=$(${MCPBASH_JSON_TOOL_BIN} -n '[{"id": 1, "data": "this is way too long for the limit"}]')
	result=$(mcp_json_truncate "$large" 10)
	jq_check "$result" '.truncated == true'
	kept=$(jq_get "$result" '.kept')
	assert_equal "0" "$kept"
	jq_check "$result" '.result == []'
}

@test "sdk_result_helpers: mcp_json_truncate always returns 0 even on error" {
	result=$(mcp_json_truncate 'not valid json' 100)
	rc=$?
	assert_equal "0" "$rc"
	jq_check "$result" '.error.type == "invalid_json"'
}

@test "sdk_result_helpers: mcp_json_truncate always returns 0 on non-truncatable large data" {
	large='{"key": "'$(printf 'x%.0s' {1..10000})'"}'
	result=$(mcp_json_truncate "$large" 100)
	rc=$?
	assert_equal "0" "$rc"
	jq_check "$result" '.error.type == "output_too_large"'
}

@test "sdk_result_helpers: mcp_json_truncate handles pretty-printed input correctly" {
	pretty=$(${MCPBASH_JSON_TOOL_BIN} -n '[1,2,3]')
	result=$(mcp_json_truncate "$pretty" 20)
	jq_check "$result" '.truncated == false'
	jq_check "$result" '.result == [1,2,3]'
}

@test "sdk_result_helpers: mcp_json_truncate handles invalid JSON gracefully" {
	result=$(mcp_json_truncate 'this is not json' 1000)
	jq_check "$result" '.error.type == "invalid_json"'
	jq_check "$result" '.result == null'
	raw=$(jq_get "$result" '.error.raw')
	assert_equal "this is not json" "$raw"
}

@test "sdk_result_helpers: mcp_json_truncate .results branch uses compact output for sizing" {
	data='{"results": [{"id":1},{"id":2},{"id":3}], "meta": "x"}'
	result=$(mcp_json_truncate "$data" 50)
	jq_check "$result" '.truncated == true'
	kept=$(jq_get "$result" '.kept')
	[ "$kept" -ge 1 ]
}

@test "sdk_result_helpers: mcp_json_truncate .results branch fails when even empty results too large" {
	huge_meta=$(printf 'x%.0s' {1..1000})
	data='{"results": [1,2,3], "meta": "'"$huge_meta"'"}'
	result=$(mcp_json_truncate "$data" 100)
	jq_check "$result" '.error.type == "output_too_large"'
	msg=$(jq_get "$result" '.error.message')
	[[ "$msg" == *empty*results* ]]
}

@test "sdk_result_helpers: mcp_json_truncate rejects multiple JSON values" {
	result=$(mcp_json_truncate '1 2 3' 1000)
	jq_check "$result" '.error.type == "invalid_json"'
	msg=$(jq_get "$result" '.error.message')
	[[ "$msg" == *[Mm]ultiple* ]]
}

@test "sdk_result_helpers: mcp_json_truncate captures multiline invalid JSON" {
	result=$(mcp_json_truncate $'invalid\njson\nwith\nnewlines' 1000)
	jq_check "$result" '.error.type == "invalid_json"'
	raw=$(jq_get "$result" '.error.raw')
	[[ "$raw" == *invalid* ]]
	[[ "$raw" == *newlines* ]]
}

@test "sdk_result_helpers: mcp_json_truncate handles non-numeric max_bytes" {
	result=$(mcp_json_truncate '[1,2,3]' "invalid")
	jq_check "$result" '.truncated == false'
	jq_check "$result" '.result == [1,2,3]'
}

@test "sdk_result_helpers: mcp_json_truncate distinguishes empty vs multi-value" {
	result=$(mcp_json_truncate '' 1000)
	msg=$(jq_get "$result" '.error.message')
	[[ "$msg" == *[Ee]mpty* ]]

	result=$(mcp_json_truncate '1 2 3' 1000)
	msg=$(jq_get "$result" '.error.message')
	[[ "$msg" == *[Mm]ultiple* ]]
}

# ============================================================================
# __mcp_sdk_uint_or_default tests
# ============================================================================

@test "sdk_result_helpers: __mcp_sdk_uint_or_default returns value for valid number" {
	val=$(__mcp_sdk_uint_or_default "42" "0")
	assert_equal "42" "$val"
}

@test "sdk_result_helpers: __mcp_sdk_uint_or_default returns default for empty" {
	val=$(__mcp_sdk_uint_or_default "" "100")
	assert_equal "100" "$val"
}

@test "sdk_result_helpers: __mcp_sdk_uint_or_default returns default for non-numeric" {
	val=$(__mcp_sdk_uint_or_default "abc" "50")
	assert_equal "50" "$val"
}

@test "sdk_result_helpers: __mcp_sdk_uint_or_default sanitizes default too" {
	val=$(__mcp_sdk_uint_or_default "abc" "not-a-number")
	assert_equal "0" "$val"
}

@test "sdk_result_helpers: __mcp_sdk_uint_or_default strips whitespace" {
	val=$(__mcp_sdk_uint_or_default "  42  " "0")
	assert_equal "42" "$val"
}
