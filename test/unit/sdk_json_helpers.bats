#!/usr/bin/env bash
# Unit layer: SDK JSON helper functions (mcp_json_escape/mcp_json_obj/mcp_json_arr).

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
	test_fail "JSON tooling unavailable for SDK JSON helper tests"
fi

# shellcheck source=sdk/tool-sdk.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/sdk/tool-sdk.sh"

printf ' -> mcp_json_escape roundtrip\n'
escaped="$(mcp_json_escape 'value "with" quotes and
newlines')"
roundtrip="$(printf '%s' "${escaped}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.')"
assert_eq 'value "with" quotes and
newlines' "${roundtrip}" "mcp_json_escape did not roundtrip through jq/gojq"

printf ' -> mcp_json_obj string values\n'
obj="$(mcp_json_obj message 'Hello "World"' count 42)"
msg="$(printf '%s' "${obj}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.message')"
count_type="$(printf '%s' "${obj}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.count | type')"
count_value="$(printf '%s' "${obj}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.count')"
assert_eq 'Hello "World"' "${msg}" "unexpected message field"
assert_eq 'string' "${count_type}" "count should be encoded as string"
assert_eq '42' "${count_value}" "count string value mismatch"

printf ' -> mcp_json_arr values\n'
arr="$(mcp_json_arr "one" "two" "three")"
len="$(printf '%s' "${arr}" | "${MCPBASH_JSON_TOOL_BIN}" 'length')"
first="$(printf '%s' "${arr}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.[0]')"
last="$(printf '%s' "${arr}" | "${MCPBASH_JSON_TOOL_BIN}" -r '.[2]')"
assert_eq '3' "${len}" "array length mismatch"
assert_eq 'one' "${first}" "first element mismatch"
assert_eq 'three' "${last}" "last element mismatch"

printf ' -> mcp_json_obj odd argument count is fatal\n'
if (mcp_json_obj only_key >/dev/null 2>&1); then
	test_fail "mcp_json_obj should fail on odd argument count"
fi

printf 'SDK JSON helper tests passed.\n'

