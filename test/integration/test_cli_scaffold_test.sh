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

printf ' -> the harness runs every test, not just the first\n'
mkdir -p "${PROJECT}/tools/ok"
printf '{"name":"ok","description":"Says ok","inputSchema":{"type":"object"}}\n' >"${PROJECT}/tools/ok/tool.meta.json"
printf '#!/usr/bin/env bash\necho ok\n' >"${PROJECT}/tools/ok/tool.sh"
chmod +x "${PROJECT}/tools/ok/tool.sh"
cp "${PROJECT}/test/run.sh" "${TEST_TMPDIR}/run.sh.orig"
# Test cases go where a user puts them: before the END OF TESTS marker.
awk '/^# END OF TESTS/ && !done { print "run_test \"ok\" \"{}\" \"first\""; print "run_test \"ok\" \"{}\" \"second\""; done = 1 } { print }' \
	"${TEST_TMPDIR}/run.sh.orig" >"${PROJECT}/test/run.sh"
run_output="$(MCPBASH_TOOL_ALLOWLIST=ok MCPBASH_BIN="${MCPBASH_HOME}/bin/mcp-bash" bash "${PROJECT}/test/run.sh" --force 2>&1)" || {
	printf 'run.sh output:\n%s\n' "${run_output}" >&2
	test_fail "test/run.sh should pass with two passing tests"
}
assert_contains "ok (second)... " "${run_output}" "expected the second test to run"
assert_contains "2 passed" "${run_output}" "expected both tests counted"
cp "${TEST_TMPDIR}/run.sh.orig" "${PROJECT}/test/run.sh"

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
