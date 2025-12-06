#!/usr/bin/env bash
# Unit layer: argument coercion helpers (mcp_args_bool/int/require).

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

MCPBASH_FORCE_MINIMAL=false
mcp_runtime_detect_json_tool
if [ "${MCPBASH_MODE}" = "minimal" ]; then
	test_fail "JSON tooling unavailable for SDK helper tests"
fi

# shellcheck source=sdk/tool-sdk.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/sdk/tool-sdk.sh"

printf ' -> bool helper truthy/falsy and default\n'
MCP_TOOL_ARGS_JSON='{"flag":true}'
assert_eq "true" "$(mcp_args_bool '.flag')" "expected JSON true to coerce to true"
MCP_TOOL_ARGS_JSON='{"flag":1}'
assert_eq "true" "$(mcp_args_bool '.flag')" "expected 1 to coerce to true"
MCP_TOOL_ARGS_JSON='{"flag":false}'
assert_eq "false" "$(mcp_args_bool '.flag')" "expected false to coerce to false"
MCP_TOOL_ARGS_JSON='{}'
assert_eq "true" "$(mcp_args_bool '.flag' --default true)" "expected default true to apply"
if (mcp_args_bool '.flag' >/dev/null 2>&1); then
	test_fail "expected missing bool without default to fail"
fi

printf ' -> int helper with bounds and negatives\n'
MCP_TOOL_ARGS_JSON='{"count":5}'
assert_eq "5" "$(mcp_args_int '.count' --min 1 --max 10)" "expected count within bounds"
MCP_TOOL_ARGS_JSON='{"count":-3}'
assert_eq "-3" "$(mcp_args_int '.count' --min -5 --max 0)" "expected negative within bounds"
MCP_TOOL_ARGS_JSON='{"count":3.14}'
if (mcp_args_int '.count' >/dev/null 2>&1); then
	test_fail "expected float to fail integer validation"
fi

printf ' -> require helper fails on missing\n'
MCP_TOOL_ARGS_JSON='{}'
if (mcp_args_require '.value' >/dev/null 2>&1); then
	test_fail "expected missing required arg to fail"
fi
MCP_TOOL_ARGS_JSON='{"value":"abc"}'
assert_eq "abc" "$(mcp_args_require '.value')" "expected require to return value"

printf ' -> minimal mode uses defaults and fails without them\n'
MCPBASH_MODE="minimal"
MCP_TOOL_ARGS_JSON='{}'
assert_eq "false" "$(mcp_args_bool '.flag' --default false)" "expected default in minimal mode"
if (mcp_args_int '.num' --min 0 >/dev/null 2>&1); then
	test_fail "expected missing int without default to fail in minimal mode"
fi
MCPBASH_MODE="full"

printf 'mcp_args_* helper tests passed.\n'
