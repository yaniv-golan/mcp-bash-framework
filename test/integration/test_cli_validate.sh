#!/usr/bin/env bash
# Integration: validate errors and --fix repair flow.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="CLI validate errors and --fix repair flow."

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

# --- Error reporting for malformed metadata ---
ERROR_ROOT="${TEST_TMPDIR}/validate-errors"
mkdir -p "${ERROR_ROOT}/server.d" "${ERROR_ROOT}/tools"

cat >"${ERROR_ROOT}/server.d/server.meta.json" <<'META'
{
  "name": "validate-errors"
}
META

# invalid JSON meta (truncated)
mkdir -p "${ERROR_ROOT}/tools/invalid"
cat >"${ERROR_ROOT}/tools/invalid/tool.meta.json" <<'META'
{ "name": "invalid"
META
cat >"${ERROR_ROOT}/tools/invalid/tool.sh" <<'SH'
#!/usr/bin/env bash
echo "invalid"
SH
chmod +x "${ERROR_ROOT}/tools/invalid/tool.sh"

# missing name field
mkdir -p "${ERROR_ROOT}/tools/no-name"
cat >"${ERROR_ROOT}/tools/no-name/tool.meta.json" <<'META'
{
  "description": "Tool without name",
  "inputSchema": { "type": "object" }
}
META
cat >"${ERROR_ROOT}/tools/no-name/tool.sh" <<'SH'
#!/usr/bin/env bash
echo "no-name"
SH
chmod +x "${ERROR_ROOT}/tools/no-name/tool.sh"

# name mismatch between directory and meta
mkdir -p "${ERROR_ROOT}/tools/mismatch"
cat >"${ERROR_ROOT}/tools/mismatch/tool.meta.json" <<'META'
{
  "name": "other-name",
  "description": "Name mismatch tool",
  "inputSchema": { "type": "object" }
}
META
cat >"${ERROR_ROOT}/tools/mismatch/tool.sh" <<'SH'
#!/usr/bin/env bash
echo "mismatch"
SH
chmod +x "${ERROR_ROOT}/tools/mismatch/tool.sh"

# missing shebang but executable
mkdir -p "${ERROR_ROOT}/tools/no-shebang"
cat >"${ERROR_ROOT}/tools/no-shebang/tool.meta.json" <<'META'
{
  "name": "no-shebang",
  "description": "Tool without shebang",
  "inputSchema": { "type": "object" }
}
META
cat >"${ERROR_ROOT}/tools/no-shebang/tool.sh" <<'SH'
echo "no-shebang"
SH
chmod +x "${ERROR_ROOT}/tools/no-shebang/tool.sh"

# server-prefix + camelCase name with kebab-case dir (should NOT warn)
mkdir -p "${ERROR_ROOT}/tools/my-tool"
cat >"${ERROR_ROOT}/tools/my-tool/tool.meta.json" <<'META'
{
  "name": "validate-errors-myTool",
  "description": "Tool with server prefix and camelCase",
  "inputSchema": { "type": "object" }
}
META
cat >"${ERROR_ROOT}/tools/my-tool/tool.sh" <<'SH'
#!/usr/bin/env bash
echo "my-tool"
SH
chmod +x "${ERROR_ROOT}/tools/my-tool/tool.sh"

set +e
error_output="$(
	cd "${ERROR_ROOT}" && "${MCPBASH_TEST_ROOT}/bin/mcp-bash" validate 2>&1
)"
error_status=$?
set -e

if [ "${error_status}" -eq 0 ]; then
	test_fail "validate succeeded despite metadata issues"
fi

assert_contains "tools/invalid/tool.meta.json - invalid JSON" "${error_output}" "expected invalid JSON error for invalid meta"
assert_contains "tools/no-name/tool.meta.json - missing required \"name\"" "${error_output}" "expected missing name error"
assert_contains "tools/mismatch - directory name does not match tool.meta.json name \"other-name\"" "${error_output}" "expected name mismatch warning"
assert_contains "tools/no-shebang/tool.sh - missing shebang" "${error_output}" "expected missing shebang warning"

# Server-prefix + camelCase name with kebab-case dir should NOT warn (DX improvement)
if printf '%s\n' "${error_output}" | grep -q 'tools/my-tool - directory name does not match'; then
	test_fail "validate incorrectly warned about server-prefix + camelCase name (my-tool vs validate-errors-myTool)"
fi

# --- --fix flow (skip on Windows Git Bash) ---
case "$(uname -s 2>/dev/null)" in
MINGW* | MSYS* | CYGWIN*)
	printf 'Skipping validate --fix portion on Windows environment\n'
	exit 0
	;;
esac

FIX_ROOT="${TEST_TMPDIR}/validate-demo"
mkdir -p "${FIX_ROOT}/server.d"

cat >"${FIX_ROOT}/server.d/server.meta.json" <<'META'
{
  "name": "validate-demo",
  "title": "Validate Demo"
}
META

mkdir -p "${FIX_ROOT}/tools/sample"
cat >"${FIX_ROOT}/tools/sample/tool.meta.json" <<'META'
{
  "name": "sample",
  "description": "Sample tool",
  "inputSchema": { "type": "object" }
}
META
cat >"${FIX_ROOT}/tools/sample/tool.sh" <<'SH'
echo "ok"
SH
chmod 644 "${FIX_ROOT}/tools/sample/tool.sh"

set +e
fix_output="$(
	cd "${FIX_ROOT}" && "${MCPBASH_TEST_ROOT}/bin/mcp-bash" validate 2>&1
)"
fix_status=$?
set -e

if [ "${fix_status}" -eq 0 ]; then
	test_fail "validate succeeded despite non-executable script"
fi
assert_contains "not executable" "${fix_output}" "validate did not report non-executable script"

(
	cd "${FIX_ROOT}" && "${MCPBASH_TEST_ROOT}/bin/mcp-bash" validate --fix >/dev/null
)

set +e
post_fix_output="$(
	cd "${FIX_ROOT}" && "${MCPBASH_TEST_ROOT}/bin/mcp-bash" validate 2>&1
)"
post_fix_status=$?
set -e

if [ "${post_fix_status}" -ne 0 ]; then
	test_fail "validate still failing after --fix for sample tool"
fi
if printf '%s\n' "${post_fix_output}" | grep -q 'tools/sample/tool.sh - not executable'; then
	test_fail "validate still reports sample tool as not executable after --fix"
fi

mkdir -p "${FIX_ROOT}/tools/extra" "${FIX_ROOT}/resources/example"
cat >"${FIX_ROOT}/tools/extra/tool.meta.json" <<'META'
{
  "name": "extra",
  "description": "Extra tool",
  "inputSchema": { "type": "object" }
}
META
cat >"${FIX_ROOT}/tools/extra/tool.sh" <<'SH'
echo "extra"
SH
chmod 644 "${FIX_ROOT}/tools/extra/tool.sh"

cat >"${FIX_ROOT}/resources/example/example.meta.json" <<'META'
{
  "name": "resource.example",
  "description": "Example resource",
  "uri": "file:///tmp/example.txt"
}
META
cat >"${FIX_ROOT}/resources/example/example.sh" <<'SH'
echo "resource"
SH
chmod 644 "${FIX_ROOT}/resources/example/example.sh"

(
	cd "${FIX_ROOT}" && "${MCPBASH_TEST_ROOT}/bin/mcp-bash" validate --fix >/dev/null
)

set +e
post_fix_output_multi="$(
	cd "${FIX_ROOT}" && "${MCPBASH_TEST_ROOT}/bin/mcp-bash" validate 2>&1
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

printf 'CLI validate errors and --fix flow passed.\n'
