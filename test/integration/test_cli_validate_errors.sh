#!/usr/bin/env bash
# Integration: validate error reporting for metadata and shebangs.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="CLI validate reports invalid JSON, missing name, name mismatch, and shebang warnings."

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_require_command jq

test_create_tmpdir
PROJECT_ROOT="${TEST_TMPDIR}/validate-errors"
mkdir -p "${PROJECT_ROOT}/server.d" "${PROJECT_ROOT}/tools"

printf ' -> create project with various metadata issues\n'
cat >"${PROJECT_ROOT}/server.d/server.meta.json" <<'META'
{
  "name": "validate-errors"
}
META

# invalid JSON meta (truncated)
mkdir -p "${PROJECT_ROOT}/tools/invalid"
cat >"${PROJECT_ROOT}/tools/invalid/tool.meta.json" <<'META'
{ "name": "invalid"
META
cat >"${PROJECT_ROOT}/tools/invalid/tool.sh" <<'SH'
#!/usr/bin/env bash
echo "invalid"
SH
chmod +x "${PROJECT_ROOT}/tools/invalid/tool.sh"

# missing name field
mkdir -p "${PROJECT_ROOT}/tools/no-name"
cat >"${PROJECT_ROOT}/tools/no-name/tool.meta.json" <<'META'
{
  "description": "Tool without name",
  "inputSchema": { "type": "object" }
}
META
cat >"${PROJECT_ROOT}/tools/no-name/tool.sh" <<'SH'
#!/usr/bin/env bash
echo "no-name"
SH
chmod +x "${PROJECT_ROOT}/tools/no-name/tool.sh"

# name mismatch between directory and meta
mkdir -p "${PROJECT_ROOT}/tools/mismatch"
cat >"${PROJECT_ROOT}/tools/mismatch/tool.meta.json" <<'META'
{
  "name": "other-name",
  "description": "Name mismatch tool",
  "inputSchema": { "type": "object" }
}
META
cat >"${PROJECT_ROOT}/tools/mismatch/tool.sh" <<'SH'
#!/usr/bin/env bash
echo "mismatch"
SH
chmod +x "${PROJECT_ROOT}/tools/mismatch/tool.sh"

# missing shebang but executable
mkdir -p "${PROJECT_ROOT}/tools/no-shebang"
cat >"${PROJECT_ROOT}/tools/no-shebang/tool.meta.json" <<'META'
{
  "name": "no-shebang",
  "description": "Tool without shebang",
  "inputSchema": { "type": "object" }
}
META
cat >"${PROJECT_ROOT}/tools/no-shebang/tool.sh" <<'SH'
echo "no-shebang"
SH
chmod +x "${PROJECT_ROOT}/tools/no-shebang/tool.sh"

printf ' -> validate reports expected errors and warnings\n'
set +e
output="$(
	cd "${PROJECT_ROOT}" && "${MCPBASH_TEST_ROOT}/bin/mcp-bash" validate 2>&1
)"
status=$?
set -e

if [ "${status}" -eq 0 ]; then
	test_fail "validate succeeded despite metadata issues"
fi

assert_contains "tools/invalid/tool.meta.json - invalid JSON" "${output}" "expected invalid JSON error for invalid meta"
assert_contains "tools/no-name/tool.meta.json - missing required \"name\"" "${output}" "expected missing name error"
assert_contains "tools/mismatch - directory name does not match tool.meta.json name \"other-name\"" "${output}" "expected name mismatch warning"
assert_contains "tools/no-shebang/tool.sh - missing shebang" "${output}" "expected missing shebang warning"
printf 'CLI validate errors test passed.\n'
