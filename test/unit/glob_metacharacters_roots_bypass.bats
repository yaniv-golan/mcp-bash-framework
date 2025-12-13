#!/usr/bin/env bash
# Unit: regression for roots/tool containment checks with glob metacharacters.
#
# Paths may legally contain glob metacharacters like []?*. Using [[ == "${root}/"* ]]
# or case "${candidate}" in "${root}"/*) turns a literal prefix check into a wildcard
# match (e.g., root[1] matches root1), which can bypass roots containment.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=test/common/env.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/env.sh"
# shellcheck source=test/common/assert.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/assert.sh"

test_create_tmpdir

ROOT_GLOB="${TEST_TMPDIR}/root[1]"
ROOT_SIBLING="${TEST_TMPDIR}/root1"
mkdir -p "${ROOT_GLOB}" "${ROOT_SIBLING}"

ROOT_GLOB_REALPATH="$(cd "${ROOT_GLOB}" && pwd -P)"
ROOT_SIBLING_REALPATH="$(cd "${ROOT_SIBLING}" && pwd -P)"

SECRET_PATH="${ROOT_SIBLING_REALPATH}/secret.txt"
printf 'secret\n' >"${SECRET_PATH}"

printf ' -> file provider: root[1] must not match root1\n'
set +e
MCP_RESOURCES_ROOTS="${ROOT_GLOB_REALPATH}" "${REPO_ROOT}/providers/file.sh" "file://${SECRET_PATH}" >/dev/null 2>&1
rc=$?
set -e
if [ "${rc}" -ne 2 ]; then
	test_fail "expected file provider to reject outside-root path (exit 2), got ${rc}"
fi

printf ' -> lib roots: mcp_roots_contains_path must not treat [] as wildcard\n'
# shellcheck source=lib/roots.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/lib/roots.sh"
MCPBASH_ROOTS_PATHS=("${ROOT_GLOB_REALPATH}")
if mcp_roots_contains_path "${SECRET_PATH}"; then
	test_fail "expected mcp_roots_contains_path to reject path outside root"
fi

printf ' -> sdk roots: mcp_roots_contains must not treat [] as wildcard\n'
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
MCP_ROOTS_PATHS="${ROOT_GLOB_REALPATH}"
MCP_ROOTS_COUNT="1"
if mcp_roots_contains "${SECRET_PATH}"; then
	test_fail "expected sdk mcp_roots_contains to reject path outside root"
fi

printf ' -> tools: mcp_tools_validate_path must not treat [] as wildcard\n'
# shellcheck source=lib/tools.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/lib/tools.sh"
TOOLS_GLOB="${TEST_TMPDIR}/tools[1]"
TOOLS_SIBLING="${TEST_TMPDIR}/tools1"
mkdir -p "${TOOLS_GLOB}" "${TOOLS_SIBLING}"
TOOL_PATH="${TOOLS_SIBLING}/t.sh"
printf '#!/usr/bin/env bash\nprintf ok\n' >"${TOOL_PATH}"
chmod 700 "${TOOL_PATH}" 2>/dev/null || true
MCPBASH_TOOLS_DIR="${TOOLS_GLOB}"
export MCPBASH_TOOLS_DIR
if mcp_tools_validate_path "${TOOL_PATH}"; then
	test_fail "expected mcp_tools_validate_path to reject tool outside tools dir"
fi

printf 'glob metacharacters containment regression passed.\n'

