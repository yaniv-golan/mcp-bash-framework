#!/usr/bin/env bash
# Integration: validate --fix and error paths.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="CLI validate detects issues and --fix repairs executables."

set -euo pipefail

case "$(uname -s 2>/dev/null)" in
MINGW* | MSYS* | CYGWIN*)
	printf 'Skipping validate --fix integration test on Windows environment\n'
	exit 0
	;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_require_command jq

test_create_tmpdir
PROJECT_ROOT="${TEST_TMPDIR}/validate-demo"
mkdir -p "${PROJECT_ROOT}"

printf ' -> create project with valid server meta and tools\n'
mkdir -p "${PROJECT_ROOT}/server.d"
cat >"${PROJECT_ROOT}/server.d/server.meta.json" <<'META'
{
  "name": "validate-demo",
  "title": "Validate Demo"
}
META

mkdir -p "${PROJECT_ROOT}/tools/sample"
cat >"${PROJECT_ROOT}/tools/sample/tool.meta.json" <<'META'
{
  "name": "sample",
  "description": "Sample tool",
  "inputSchema": { "type": "object" }
}
META
cat >"${PROJECT_ROOT}/tools/sample/tool.sh" <<'SH'
echo "ok"
SH
chmod 644 "${PROJECT_ROOT}/tools/sample/tool.sh"

printf ' -> validate reports non-executable script\n'
set +e
output="$(
	cd "${PROJECT_ROOT}" && "${MCPBASH_TEST_ROOT}/bin/mcp-bash" validate 2>&1
)"
status=$?
set -e

if [ "${status}" -eq 0 ]; then
	test_fail "validate succeeded despite non-executable script"
fi
assert_contains "not executable" "${output}" "validate did not report non-executable script"

printf ' -> validate --fix makes script executable\n'
(
	cd "${PROJECT_ROOT}" && "${MCPBASH_TEST_ROOT}/bin/mcp-bash" validate --fix >/dev/null
)

set +e
post_fix_output="$(
	cd "${PROJECT_ROOT}" && "${MCPBASH_TEST_ROOT}/bin/mcp-bash" validate 2>&1
)"
post_fix_status=$?
set -e

if [ "${post_fix_status}" -ne 0 ]; then
	test_fail "validate still failing after --fix for sample tool"
fi
if printf '%s\n' "${post_fix_output}" | grep -q 'tools/sample/tool.sh - not executable'; then
	test_fail "validate still reports sample tool as not executable after --fix"
fi

printf ' -> validate --fix handles multiple scripts\n'
mkdir -p "${PROJECT_ROOT}/tools/extra" "${PROJECT_ROOT}/resources/example"
cat >"${PROJECT_ROOT}/tools/extra/tool.meta.json" <<'META'
{
  "name": "extra",
  "description": "Extra tool",
  "inputSchema": { "type": "object" }
}
META
cat >"${PROJECT_ROOT}/tools/extra/tool.sh" <<'SH'
echo "extra"
SH
chmod 644 "${PROJECT_ROOT}/tools/extra/tool.sh"

cat >"${PROJECT_ROOT}/resources/example/example.meta.json" <<'META'
{
  "name": "resource.example",
  "description": "Example resource",
  "uri": "file:///tmp/example.txt"
}
META
cat >"${PROJECT_ROOT}/resources/example/example.sh" <<'SH'
echo "resource"
SH
chmod 644 "${PROJECT_ROOT}/resources/example/example.sh"

(
	cd "${PROJECT_ROOT}" && "${MCPBASH_TEST_ROOT}/bin/mcp-bash" validate --fix >/dev/null
)

set +e
post_fix_output_multi="$(
	cd "${PROJECT_ROOT}" && "${MCPBASH_TEST_ROOT}/bin/mcp-bash" validate 2>&1
)"
post_fix_status_multi=$?
set -e

if [ "${post_fix_status_multi}" -ne 0 ]; then
	test_fail "validate still failing after --fix for multiple scripts"
fi
if printf '%s\n' "${post_fix_output_multi}" | grep -q 'tools/extra/tool.sh - not executable'; then
	test_fail "validate still reports extra tool as not executable after --fix"
fi
if printf '%s\n' "${post_fix_output_multi}" | grep -q 'resources/example/example.sh - not executable'; then
	test_fail "validate still reports resource script as not executable after --fix"
fi
printf 'CLI validate --fix test passed.\n'
