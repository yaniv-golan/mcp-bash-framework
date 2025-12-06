#!/usr/bin/env bash
# Unit layer: mcp_require_path helper.

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

test_create_tmpdir
ROOT_ONE="${TEST_TMPDIR}/root-one"
ROOT_TWO="${TEST_TMPDIR}/root-two"
mkdir -p "${ROOT_ONE}" "${ROOT_TWO}"
ROOT_ONE_REALPATH="$(cd "${ROOT_ONE}" && pwd -P)"
ROOT_TWO_REALPATH="$(cd "${ROOT_TWO}" && pwd -P)"

printf ' -> defaults to single root when requested\n'
MCP_ROOTS_PATHS="${ROOT_ONE_REALPATH}"
MCP_ROOTS_COUNT="1"
MCP_TOOL_ARGS_JSON="{}"
resolved="$(mcp_require_path '.path' --default-to-single-root)"
assert_eq "${ROOT_ONE_REALPATH}" "${resolved}" "expected helper to default to single root"

printf ' -> rejects paths outside roots\n'
MCP_TOOL_ARGS_JSON="$(printf '{"path":"%s"}' "${ROOT_TWO_REALPATH}")"
MCPBASH_JSON_TOOL="${MCPBASH_JSON_TOOL:-}"
MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN:-}"
MCPBASH_MODE="${MCPBASH_MODE:-full}"
if MCP_TOOL_ARGS_JSON="${MCP_TOOL_ARGS_JSON}" MCP_ROOTS_PATHS="${MCP_ROOTS_PATHS}" MCP_ROOTS_COUNT="${MCP_ROOTS_COUNT}" MCPBASH_JSON_TOOL="${MCPBASH_JSON_TOOL}" MCPBASH_JSON_TOOL_BIN="${MCPBASH_JSON_TOOL_BIN}" MCPBASH_MODE="${MCPBASH_MODE}" bash -c 'source "$1"; mcp_require_path ".path" --default-to-single-root >/dev/null' _ "${REPO_ROOT}/sdk/tool-sdk.sh"; then
	test_fail "expected path outside roots to fail"
fi

printf ' -> normalizes relative paths against current working directory\n'
cd "${ROOT_ONE}"
MCP_TOOL_ARGS_JSON='{"path":"./nested/../"}'
MCP_ROOTS_PATHS="${ROOT_ONE_REALPATH}"
MCP_ROOTS_COUNT="1"
resolved_rel="$(mcp_require_path '.path')"
printf 'resolved_rel=%s expected=%s\n' "${resolved_rel}" "${ROOT_ONE_REALPATH}"
assert_eq "${ROOT_ONE_REALPATH}" "${resolved_rel}" "relative path should resolve to root path"

printf 'mcp_require_path tests passed.\n'
