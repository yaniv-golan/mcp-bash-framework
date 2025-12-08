#!/usr/bin/env bash
# Unit layer: roots canonicalization and run-tool overrides.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=test/common/env.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/env.sh"
# shellcheck source=test/common/assert.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/assert.sh"

# shellcheck source=lib/roots.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/lib/roots.sh"
# shellcheck source=lib/cli/run_tool.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/lib/cli/run_tool.sh"

test_create_tmpdir
ROOT_OK="${TEST_TMPDIR}/ok-root"
mkdir -p "${ROOT_OK}"

printf ' -> canonicalize rejects missing path (strict)\n'
if mcp_roots_canonicalize_checked "${TEST_TMPDIR}/missing" "test" 1; then
	test_fail "expected missing path to be rejected"
fi

printf ' -> canonicalize accepts existing path and resolves traversal\n'
resolved="$(mcp_roots_canonicalize_checked "${ROOT_OK}/../ok-root" "test" 1)"
expected="$(cd "${ROOT_OK}" && pwd -P)"
assert_eq "${expected}" "${resolved}" "expected canonicalized path to match realpath"

printf ' -> run-tool --roots fails on invalid entry\n'
if MCPBASH_PROJECT_ROOT="${TEST_TMPDIR}" mcp_cli_run_tool_prepare_roots "${TEST_TMPDIR}/nope"; then
	test_fail "expected run-tool roots validation to fail for invalid path"
fi

printf ' -> run-tool --roots accepts existing entry\n'
if ! MCPBASH_PROJECT_ROOT="${TEST_TMPDIR}" mcp_cli_run_tool_prepare_roots "${ROOT_OK}"; then
	test_fail "expected run-tool roots validation to pass for existing path"
fi

printf 'roots validation tests passed.\n'
