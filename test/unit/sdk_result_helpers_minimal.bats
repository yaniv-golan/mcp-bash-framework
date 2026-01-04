#!/usr/bin/env bash
# Unit layer: SDK CallToolResult helpers in minimal mode (no jq).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=test/common/env.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/env.sh"
# shellcheck source=test/common/assert.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/assert.sh"

# Force minimal mode (no jq available to SDK functions)
MCPBASH_JSON_TOOL="none"
MCPBASH_JSON_TOOL_BIN=""
MCPBASH_MODE="minimal"
export MCPBASH_JSON_TOOL MCPBASH_JSON_TOOL_BIN MCPBASH_MODE

# shellcheck source=sdk/tool-sdk.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/sdk/tool-sdk.sh"

# For assertions, we need jq - use system jq directly
JQ_BIN="$(command -v jq || command -v gojq || true)"
if [ -z "${JQ_BIN}" ]; then
	test_fail "Need jq or gojq for test assertions (even though SDK is in minimal mode)"
fi

jq_check() {
	printf '%s' "$1" | "${JQ_BIN}" -e "$2" >/dev/null 2>&1
}

jq_get() {
	printf '%s' "$1" | "${JQ_BIN}" -r "$2"
}

# ============================================================================
# Minimal mode tests
# ============================================================================

printf ' -> minimal mode: mcp_result_success produces valid JSON\n'
result=$(mcp_result_success '{"foo":"bar"}')
# Must be valid JSON
printf '%s' "$result" | "${JQ_BIN}" -e '.' >/dev/null 2>&1 || test_fail "mcp_result_success output is not valid JSON"
jq_check "$result" '.isError == false' || test_fail "isError should be false"
jq_check "$result" '.structuredContent.success == true' || test_fail "success should be true"

printf ' -> minimal mode: mcp_result_error produces valid JSON even with invalid input\n'
result=$(mcp_result_error 'this is not json')
# Must be valid JSON (this is the critical assertion)
printf '%s' "$result" | "${JQ_BIN}" -e '.' >/dev/null 2>&1 || test_fail "mcp_result_error output is not valid JSON"
jq_check "$result" '.isError == true' || test_fail "isError should be true"
raw=$(jq_get "$result" '.structuredContent.error.raw')
assert_eq "this is not json" "$raw" "raw should contain original input"

printf ' -> minimal mode: mcp_result_error handles empty input\n'
result=$(mcp_result_error '')
printf '%s' "$result" | "${JQ_BIN}" -e '.' >/dev/null 2>&1 || test_fail "mcp_result_error with empty input is not valid JSON"
jq_check "$result" '.isError == true' || test_fail "isError should be true"

printf ' -> minimal mode: mcp_json_truncate adds warning but returns data\n'
result=$(mcp_json_truncate '[1,2,3]' 10)
printf '%s' "$result" | "${JQ_BIN}" -e '.' >/dev/null 2>&1 || test_fail "mcp_json_truncate output is not valid JSON"
warning=$(jq_get "$result" '._warning')
[[ "$warning" == *minimal* ]] || test_fail "warning should mention minimal mode"
jq_check "$result" '.truncated == false' || test_fail "truncated should be false"

printf ' -> minimal mode: mcp_is_valid_json returns 0 (assumes valid)\n'
mcp_is_valid_json 'anything' || test_fail "mcp_is_valid_json should return 0 in minimal mode"

printf ' -> minimal mode: mcp_result_success with special characters produces valid JSON\n'
result=$(mcp_result_success '{"msg":"line1\nline2\ttab"}')
printf '%s' "$result" | "${JQ_BIN}" -e '.' >/dev/null 2>&1 || test_fail "mcp_result_success with special chars is not valid JSON"

printf ' -> minimal mode: mcp_result_success size threshold works\n'
# Create a response that exceeds the small threshold
result=$(mcp_result_success '{"key":"value"}' 10)
printf '%s' "$result" | "${JQ_BIN}" -e '.' >/dev/null 2>&1 || test_fail "mcp_result_success with size threshold is not valid JSON"
text=$(jq_get "$result" '.content[0].text')
# Should be the summary since envelope > 10 bytes
[[ "$text" == *too*large* ]] || test_fail "text should indicate too large"

printf 'SDK result helper minimal mode tests passed.\n'
