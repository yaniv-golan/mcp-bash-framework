#!/usr/bin/env bash
# Unit layer: SDK CallToolResult helper functions (mcp_result_success, mcp_result_error, mcp_json_truncate).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=test/common/env.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/env.sh"
# shellcheck source=test/common/assert.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/assert.sh"

# Ensure JSON tooling is available so helpers exercise the jq/gojq path.
# shellcheck source=lib/runtime.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/lib/runtime.sh"

MCPBASH_FORCE_MINIMAL=false
mcp_runtime_detect_json_tool
if [ "${MCPBASH_MODE}" = "minimal" ]; then
	test_fail "JSON tooling unavailable for SDK result helper tests"
fi

# shellcheck source=sdk/tool-sdk.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/sdk/tool-sdk.sh"

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

printf ' -> mcp_result_success wraps simple value\n'
result=$(mcp_result_success '{"foo": "bar"}')
jq_check "$result" '.structuredContent.success == true' || test_fail "success should be true"
jq_check "$result" '.structuredContent.result.foo == "bar"' || test_fail "result.foo should be bar"
jq_check "$result" '.isError == false' || test_fail "isError should be false"

printf ' -> mcp_result_success always wraps data including objects with result field\n'
result=$(mcp_result_success '{"result": "pass", "score": 95}')
jq_check "$result" '.structuredContent.result.result == "pass"' || test_fail "nested result.result should be pass"
jq_check "$result" '.structuredContent.result.score == 95' || test_fail "result.score should be 95"
jq_check "$result" '.structuredContent.success == true' || test_fail "success should be true"

printf ' -> mcp_result_success summarizes large responses\n'
large=$(${MCPBASH_JSON_TOOL_BIN} -n '[range(1000)] | map({id: ., data: "x" * 100})')
result=$(mcp_result_success "$large" 100)
text=$(jq_get "$result" '.content[0].text')
[[ "$text" == Success:* ]] || test_fail "text should start with Success:"
[[ "$text" == *array* ]] || test_fail "text should mention array"

printf ' -> mcp_result_success content.text is NOT double-encoded\n'
result=$(mcp_result_success '{"foo": "bar"}')
text=$(jq_get "$result" '.content[0].text')
# If double-encoded, parsing would fail or give wrong result
parsed_success=$(printf '%s' "$text" | "${MCPBASH_JSON_TOOL_BIN}" -r '.success')
assert_eq "true" "$parsed_success" "text field should be parseable JSON with success=true"

printf ' -> mcp_result_success handles special characters\n'
result=$(mcp_result_success '{"msg": "line1\nline2", "quote": "he said \"hi\""}')
jq_check "$result" '.isError == false' || test_fail "isError should be false"

printf ' -> mcp_result_success handles empty array\n'
result=$(mcp_result_success '[]')
jq_check "$result" '.structuredContent.success == true' || test_fail "success should be true"
jq_check "$result" '.structuredContent.result == []' || test_fail "result should be empty array"

printf ' -> mcp_result_success handles deeply nested objects\n'
result=$(mcp_result_success '{"a":{"b":{"c":{"d":1}}}}')
val=$(jq_get "$result" '.structuredContent.result.a.b.c.d')
assert_eq "1" "$val" "deeply nested value should be accessible"

printf ' -> mcp_result_success handles unicode\n'
result=$(mcp_result_success '{"emoji":"🎉","chinese":"中文"}')
emoji=$(jq_get "$result" '.structuredContent.result.emoji')
assert_eq "🎉" "$emoji" "emoji should be preserved"

printf ' -> mcp_result_success handles null values\n'
result=$(mcp_result_success '{"val":null}')
jq_check "$result" '.structuredContent.result.val == null' || test_fail "val should be null"

printf ' -> mcp_result_success rejects empty input but returns 0\n'
set +e
result=$(mcp_result_success '')
rc=$?
set -e
assert_eq "0" "$rc" "should return 0 even on error"
jq_check "$result" '.isError == true' || test_fail "isError should be true for empty input"

printf ' -> mcp_result_success handles JSON false value\n'
result=$(mcp_result_success 'false')
jq_check "$result" '.structuredContent.success == true' || test_fail "success should be true"
jq_check "$result" '.structuredContent.result == false' || test_fail "result should be false"
jq_check "$result" '.isError == false' || test_fail "isError should be false"

printf ' -> mcp_result_success handles JSON null value\n'
result=$(mcp_result_success 'null')
jq_check "$result" '.structuredContent.success == true' || test_fail "success should be true"
jq_check "$result" '.structuredContent.result == null' || test_fail "result should be null"
jq_check "$result" '.isError == false' || test_fail "isError should be false"

printf ' -> mcp_result_success rejects multiple JSON values\n'
result=$(mcp_result_success '1 2 3')
jq_check "$result" '.isError == true' || test_fail "isError should be true for multi-value"
msg=$(jq_get "$result" '.structuredContent.error.message')
[[ "$msg" == *multiple* ]] || test_fail "error message should mention multiple"

printf ' -> mcp_result_success always returns 0 even on validation error\n'
set +e
result=$(mcp_result_success 'invalid json')
rc=$?
set -e
assert_eq "0" "$rc" "should return 0 even on invalid JSON"
jq_check "$result" '.isError == true' || test_fail "isError should be true for invalid JSON"

printf ' -> mcp_result_success uses tojson for argv safety\n'
large=$(${MCPBASH_JSON_TOOL_BIN} -n '[range(1000)] | map({id: ., data: "x" * 100})')
result=$(mcp_result_success "$large")
jq_check "$result" '.isError == false' || test_fail "isError should be false for large input"
jq_check "$result" '.structuredContent.success == true' || test_fail "success should be true"

printf ' -> mcp_result_success handles non-numeric max_text_bytes\n'
result=$(mcp_result_success '{"key":"value"}' "not-a-number")
jq_check "$result" '.isError == false' || test_fail "should succeed with non-numeric max"
jq_check "$result" '.structuredContent.success == true' || test_fail "success should be true"

printf ' -> mcp_result_success truncates correctly at emoji boundary\n'
result=$(mcp_result_success '{"emoji":"🎉🎉🎉"}' 50)
jq_check "$result" '.isError == false' || test_fail "should succeed with emoji"
text=$(jq_get "$result" '.content[0].text')
[ -n "$text" ] || test_fail "text should not be empty"

# ============================================================================
# mcp_result_error tests
# ============================================================================

printf ' -> mcp_result_error sets isError true\n'
result=$(mcp_result_error '{"type": "not_found", "message": "User not found"}')
jq_check "$result" '.isError == true' || test_fail "isError should be true"
text=$(jq_get "$result" '.content[0].text')
assert_eq "User not found" "$text" "text should be the error message"

printf ' -> mcp_result_error handles empty input gracefully\n'
result=$(mcp_result_error '')
jq_check "$result" '.isError == true' || test_fail "isError should be true"
# Must be valid JSON
printf '%s' "$result" | "${MCPBASH_JSON_TOOL_BIN}" -e '.' >/dev/null 2>&1 || test_fail "output should be valid JSON"

printf ' -> mcp_result_error handles invalid JSON input\n'
result=$(mcp_result_error 'this is not json')
jq_check "$result" '.isError == true' || test_fail "isError should be true"
raw=$(jq_get "$result" '.structuredContent.error.raw')
assert_eq "this is not json" "$raw" "raw should contain original input"

printf ' -> mcp_result_error always returns 0\n'
set +e
result=$(mcp_result_error '{"type":"test","message":"test"}')
rc=$?
set -e
assert_eq "0" "$rc" "should always return 0"

printf ' -> mcp_result_error handles valid non-object JSON\n'
result=$(mcp_result_error '"just a string"')
jq_check "$result" '.isError == true' || test_fail "isError should be true"
msg=$(jq_get "$result" '.structuredContent.error.message')
[[ "$msg" == *object* ]] || test_fail "message should mention object requirement"

printf ' -> mcp_result_error handles array input\n'
result=$(mcp_result_error '[]')
jq_check "$result" '.isError == true' || test_fail "isError should be true"
msg=$(jq_get "$result" '.structuredContent.error.message')
[[ "$msg" == *object* ]] || test_fail "message should mention object requirement"

printf ' -> mcp_result_error with non-string message uses tostring\n'
result=$(mcp_result_error '{"type":"test","message":42}')
jq_check "$result" '.isError == true' || test_fail "isError should be true"
text=$(jq_get "$result" '.content[0].text')
assert_eq "42" "$text" "text should be stringified message"

# ============================================================================
# mcp_is_valid_json tests
# ============================================================================

printf ' -> mcp_is_valid_json returns 0 for false\n'
mcp_is_valid_json 'false' || test_fail "mcp_is_valid_json should accept false"

printf ' -> mcp_is_valid_json returns 0 for null\n'
mcp_is_valid_json 'null' || test_fail "mcp_is_valid_json should accept null"

printf ' -> mcp_is_valid_json returns 1 for empty string\n'
if mcp_is_valid_json ''; then
	test_fail "mcp_is_valid_json should reject empty string"
fi

printf ' -> mcp_is_valid_json returns 1 for whitespace-only\n'
if mcp_is_valid_json '   '; then
	test_fail "mcp_is_valid_json should reject whitespace-only"
fi

printf ' -> mcp_is_valid_json returns 1 for multiple JSON values\n'
if mcp_is_valid_json '1 2'; then
	test_fail "mcp_is_valid_json should reject multiple values"
fi

printf ' -> mcp_is_valid_json returns 1 for invalid JSON\n'
if mcp_is_valid_json 'not valid json'; then
	test_fail "mcp_is_valid_json should reject invalid JSON"
fi

# ============================================================================
# mcp_byte_length tests
# ============================================================================

printf ' -> mcp_byte_length counts bytes correctly\n'
len=$(mcp_byte_length "hello")
assert_eq "5" "$len" "hello should be 5 bytes"

printf ' -> mcp_byte_length handles unicode\n'
# 🎉 is 4 bytes in UTF-8
len=$(mcp_byte_length "🎉")
assert_eq "4" "$len" "emoji should be 4 bytes"

# ============================================================================
# mcp_json_truncate tests
# ============================================================================

printf ' -> mcp_json_truncate returns small arrays unchanged\n'
result=$(mcp_json_truncate '[1,2,3]' 1000)
jq_check "$result" '.truncated == false' || test_fail "truncated should be false"
jq_check "$result" '.result == [1,2,3]' || test_fail "result should be unchanged"

printf ' -> mcp_json_truncate binary searches to max fit\n'
large=$(${MCPBASH_JSON_TOOL_BIN} -n '[range(100)] | map({id: ., pad: "x" * 50})')
result=$(mcp_json_truncate "$large" 500)
jq_check "$result" '.truncated == true' || test_fail "truncated should be true"
jq_check "$result" '.kept < .total' || test_fail "kept should be less than total"
jq_check "$result" '.result | type == "array"' || test_fail "result should be array"

printf ' -> mcp_json_truncate handles .results wrapper\n'
data='{"results": [1,2,3,4,5], "meta": "preserved"}'
result=$(mcp_json_truncate "$data" 50)
jq_check "$result" '.result.meta == "preserved"' || test_fail "meta should be preserved"
jq_check "$result" '.result.results | type == "array"' || test_fail "results should be array"

printf ' -> mcp_json_truncate early-exits when first element exceeds limit\n'
large=$(${MCPBASH_JSON_TOOL_BIN} -n '[{"id": 1, "data": "this is way too long for the limit"}]')
result=$(mcp_json_truncate "$large" 10)
jq_check "$result" '.truncated == true' || test_fail "truncated should be true"
kept=$(jq_get "$result" '.kept')
assert_eq "0" "$kept" "kept should be 0"
jq_check "$result" '.result == []' || test_fail "result should be empty array"

printf ' -> mcp_json_truncate always returns 0 even on error\n'
set +e
result=$(mcp_json_truncate 'not valid json' 100)
rc=$?
set -e
assert_eq "0" "$rc" "should return 0 on error"
jq_check "$result" '.error.type == "invalid_json"' || test_fail "error type should be invalid_json"

printf ' -> mcp_json_truncate always returns 0 on non-truncatable large data\n'
large='{"key": "'$(printf 'x%.0s' {1..10000})'"}'
set +e
result=$(mcp_json_truncate "$large" 100)
rc=$?
set -e
assert_eq "0" "$rc" "should return 0 on non-truncatable"
jq_check "$result" '.error.type == "output_too_large"' || test_fail "error type should be output_too_large"

printf ' -> mcp_json_truncate handles pretty-printed input correctly\n'
pretty=$(${MCPBASH_JSON_TOOL_BIN} -n '[1,2,3]')
result=$(mcp_json_truncate "$pretty" 20)
jq_check "$result" '.truncated == false' || test_fail "should not truncate small array"
jq_check "$result" '.result == [1,2,3]' || test_fail "result should be [1,2,3]"

printf ' -> mcp_json_truncate handles invalid JSON gracefully\n'
result=$(mcp_json_truncate 'this is not json' 1000)
jq_check "$result" '.error.type == "invalid_json"' || test_fail "error type should be invalid_json"
jq_check "$result" '.result == null' || test_fail "result should be null"
raw=$(jq_get "$result" '.error.raw')
assert_eq "this is not json" "$raw" "raw should contain original input"

printf ' -> mcp_json_truncate .results branch uses compact output for sizing\n'
data='{"results": [{"id":1},{"id":2},{"id":3}], "meta": "x"}'
result=$(mcp_json_truncate "$data" 50)
jq_check "$result" '.truncated == true' || test_fail "truncated should be true"
kept=$(jq_get "$result" '.kept')
[ "$kept" -ge 1 ] || test_fail "kept should be at least 1"

printf ' -> mcp_json_truncate .results branch fails when even empty results too large\n'
huge_meta=$(printf 'x%.0s' {1..1000})
data='{"results": [1,2,3], "meta": "'"$huge_meta"'"}'
result=$(mcp_json_truncate "$data" 100)
jq_check "$result" '.error.type == "output_too_large"' || test_fail "error type should be output_too_large"
msg=$(jq_get "$result" '.error.message')
[[ "$msg" == *empty*results* ]] || test_fail "message should mention empty results"

printf ' -> mcp_json_truncate rejects multiple JSON values\n'
result=$(mcp_json_truncate '1 2 3' 1000)
jq_check "$result" '.error.type == "invalid_json"' || test_fail "error type should be invalid_json"
msg=$(jq_get "$result" '.error.message')
[[ "$msg" == *[Mm]ultiple* ]] || test_fail "message should mention multiple"

printf ' -> mcp_json_truncate captures multiline invalid JSON\n'
result=$(mcp_json_truncate $'invalid\njson\nwith\nnewlines' 1000)
jq_check "$result" '.error.type == "invalid_json"' || test_fail "error type should be invalid_json"
raw=$(jq_get "$result" '.error.raw')
[[ "$raw" == *invalid* ]] || test_fail "raw should contain invalid"
[[ "$raw" == *newlines* ]] || test_fail "raw should contain newlines"

printf ' -> mcp_json_truncate handles non-numeric max_bytes\n'
result=$(mcp_json_truncate '[1,2,3]' "invalid")
jq_check "$result" '.truncated == false' || test_fail "should not truncate"
jq_check "$result" '.result == [1,2,3]' || test_fail "result should be [1,2,3]"

printf ' -> mcp_json_truncate distinguishes empty vs multi-value\n'
result=$(mcp_json_truncate '' 1000)
msg=$(jq_get "$result" '.error.message')
[[ "$msg" == *[Ee]mpty* ]] || test_fail "message should mention empty"

result=$(mcp_json_truncate '1 2 3' 1000)
msg=$(jq_get "$result" '.error.message')
[[ "$msg" == *[Mm]ultiple* ]] || test_fail "message should mention multiple"

# ============================================================================
# __mcp_sdk_uint_or_default tests
# ============================================================================

printf ' -> __mcp_sdk_uint_or_default returns value for valid number\n'
val=$(__mcp_sdk_uint_or_default "42" "0")
assert_eq "42" "$val" "should return 42"

printf ' -> __mcp_sdk_uint_or_default returns default for empty\n'
val=$(__mcp_sdk_uint_or_default "" "100")
assert_eq "100" "$val" "should return default 100"

printf ' -> __mcp_sdk_uint_or_default returns default for non-numeric\n'
val=$(__mcp_sdk_uint_or_default "abc" "50")
assert_eq "50" "$val" "should return default 50"

printf ' -> __mcp_sdk_uint_or_default sanitizes default too\n'
val=$(__mcp_sdk_uint_or_default "abc" "not-a-number")
assert_eq "0" "$val" "should return 0 when both invalid"

printf ' -> __mcp_sdk_uint_or_default strips whitespace\n'
val=$(__mcp_sdk_uint_or_default "  42  " "0")
assert_eq "42" "$val" "should strip whitespace and return 42"

printf 'SDK result helper tests passed.\n'
