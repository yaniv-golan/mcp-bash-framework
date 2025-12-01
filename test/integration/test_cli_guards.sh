#!/usr/bin/env bash
# Integration: CLI guard for missing MCPBASH_PROJECT_ROOT.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="CLI scaffolding rejects missing project root."

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"

output="$(MCPBASH_PROJECT_ROOT='' "${MCPBASH_TEST_ROOT}/bin/mcp-bash" scaffold tool foo 2>&1 >/dev/null || true)"

if ! printf '%s' "${output}" | grep -qi 'MCPBASH_PROJECT_ROOT is not set'; then
	printf 'Expected scaffold guard error when MCPBASH_PROJECT_ROOT missing.\n' >&2
	exit 1
fi

invalid_root="${TMPDIR%/}/mcpbash.invalid.$$"
invalid_output="$(MCPBASH_PROJECT_ROOT="${invalid_root}" "${MCPBASH_TEST_ROOT}/bin/mcp-bash" 2>&1 >/dev/null || true)"

if ! printf '%s' "${invalid_output}" | grep -qi 'does not exist'; then
	printf 'Expected error for invalid MCPBASH_PROJECT_ROOT, got:\n%s\n' "${invalid_output}" >&2
	exit 1
fi

printf 'CLI guard test passed.\n'
