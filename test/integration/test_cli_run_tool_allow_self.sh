#!/usr/bin/env bash
# Integration: run-tool supports per-invocation allow via --allow-self.
#
# This test intentionally does NOT source test/common/env.sh because that file
# forces MCPBASH_TOOL_ALLOWLIST="*" and would mask real-world defaults.
#
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="CLI run-tool: --allow-self allows a single tool invocation."

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export MCPBASH_HOME="${REPO_ROOT}"
export PATH="${MCPBASH_HOME}/bin:${PATH}"

tmp_base="${TMPDIR:-/tmp}"
if [ -z "${tmp_base}" ] || [ ! -d "${tmp_base}" ]; then
	tmp_base="/tmp"
fi
tmp_root="$(mktemp -d "${tmp_base%/}/mcpbash.run-tool-allow-self.XXXXXX")"
cleanup() {
	rm -rf "${tmp_root}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

(
	cd "${tmp_root}" || exit 1
	"${MCPBASH_HOME}/bin/mcp-bash" new demo-server >/dev/null
)

# 1) Without allowlist or flag, should be blocked.
blocked_output="$(
	(
		cd "${tmp_root}/demo-server" || exit 1
		unset MCPBASH_TOOL_ALLOWLIST MCPBASH_TOOL_ALLOW_DEFAULT
		"${MCPBASH_HOME}/bin/mcp-bash" run-tool hello --args '{"name":"World"}'
	) 2>&1 || true
)"
assert_contains "blocked by policy" "${blocked_output}" "expected run-tool to be blocked by default policy"
assert_contains "--allow-self" "${blocked_output}" "expected blocked policy error to suggest --allow-self for run-tool"

# 2) With --allow-self, should succeed.
ok_output="$(
	(
		cd "${tmp_root}/demo-server" || exit 1
		unset MCPBASH_TOOL_ALLOWLIST MCPBASH_TOOL_ALLOW_DEFAULT
		"${MCPBASH_HOME}/bin/mcp-bash" run-tool hello --allow-self --args '{"name":"World"}'
	)
)"
assert_contains "Hello, World!" "${ok_output}" "expected hello tool to run with --allow-self"

printf 'run-tool --allow-self test passed.\n'
