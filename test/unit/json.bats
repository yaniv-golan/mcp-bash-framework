#!/usr/bin/env bash
# Spec §18.2 (Unit layer): validate JSON helpers.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=test/common/env.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/env.sh"
# shellcheck source=test/common/assert.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/assert.sh"

# shellcheck source=lib/runtime.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/lib/runtime.sh"
# shellcheck source=lib/json.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/lib/json.sh"

MCPBASH_FORCE_MINIMAL=false
mcp_runtime_detect_json_tool
if [ "${MCPBASH_MODE}" = "minimal" ]; then
	test_fail "JSON tooling unavailable for normalization test"
fi

printf ' -> normalize with jq/gojq\n'
normalized="$(mcp_json_normalize_line $' {\"foo\":1,\n\"bar\":2 }\n')"
assert_eq '{"bar":2,"foo":1}' "${normalized}" "unexpected normalization result"

printf ' -> detect arrays\n'
if ! mcp_json_is_array '[]'; then
	test_fail "expected empty array to be detected"
fi
if mcp_json_is_array '{"a":1}'; then
	test_fail "object misclassified as array"
fi

printf ' -> minimal mode passthrough and validation\n'
MCPBASH_MODE="minimal"
minimal="$(mcp_json_normalize_line '{"jsonrpc":"2.0","method":"ping"}')"
assert_eq '{"jsonrpc":"2.0","method":"ping"}' "${minimal}"
if mcp_json_normalize_line '{"jsonrpc":2}' >/dev/null 2>&1; then
	test_fail "minimal mode should reject invalid payload"
fi

printf ' -> BOM and whitespace trimming\n'
bom_line=$'\xEF\xBB\xBF  {\"jsonrpc\":\"2.0\",\"method\":\"ping\"}  \n'
trimmed="$(MCPBASH_MODE="full" MCPBASH_JSON_TOOL="gojq" MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN}" mcp_json_normalize_line "${bom_line}")"
assert_eq '{"jsonrpc":"2.0","method":"ping"}' "${trimmed}" "BOM/whitespace not normalized"

printf 'JSON helper tests passed.\n'
