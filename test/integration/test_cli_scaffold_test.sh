#!/usr/bin/env bash
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="scaffold test creates test harness"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_create_tmpdir

PROJECT="${TEST_TMPDIR}/test-project"
mkdir -p "${PROJECT}"
(
	cd "${PROJECT}" || exit 1
	"${MCPBASH_HOME}/bin/mcp-bash" init --name test-project --no-hello >/dev/null
)

printf ' -> scaffold test creates harness\n'
(
	cd "${PROJECT}" || exit 1
	"${MCPBASH_HOME}/bin/mcp-bash" scaffold test >/dev/null
)

assert_file_exists "${PROJECT}/test/run.sh"
assert_file_exists "${PROJECT}/test/README.md"

# On Unix, check executable bit; on Windows/Git Bash, execute bits are unreliable
if [[ "$(uname -s)" != MINGW* ]] && [[ "$(uname -s)" != MSYS* ]] && [ ! -x "${PROJECT}/test/run.sh" ]; then
	test_fail "test/run.sh should be executable"
fi

# Use bash explicitly to avoid execute-bit issues on Windows
# Pass --force to skip validation step in scaffolded runner (validation is tested elsewhere)
run_output="$(MCPBASH_BIN="${MCPBASH_HOME}/bin/mcp-bash" bash "${PROJECT}/test/run.sh" --force 2>&1)" || {
	printf 'run.sh output:\n%s\n' "${run_output}" >&2
	test_fail "test/run.sh should run successfully with no tests"
}

printf ' -> scaffold test guards existing run.sh\n'
set +e
(
	cd "${PROJECT}" || exit 1
	"${MCPBASH_HOME}/bin/mcp-bash" scaffold test >/dev/null 2>&1
)
status=$?
set -e
if [ "${status}" -eq 0 ]; then
	test_fail "scaffold test should fail if test/run.sh exists"
fi

printf ' -> scaffold test guards existing README\n'
rm -f "${PROJECT}/test/run.sh"
set +e
output="$(
	cd "${PROJECT}" || exit 1
	"${MCPBASH_HOME}/bin/mcp-bash" scaffold test 2>&1
)"
status=$?
set -e
if [ "${status}" -eq 0 ]; then
	test_fail "scaffold test should fail if test/README.md exists"
fi
assert_contains "README.md" "${output}" "expected error to mention README.md"

printf 'scaffold test CLI test passed.\n'
