#!/usr/bin/env bash
# Integration: CLI config variants (show/json/client).
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="CLI config emits expected snippets and JSON."

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
PROJECT_DIR="${TEST_TMPDIR}/cfg-demo"
mkdir -p "${PROJECT_DIR}"

printf ' -> init project\n'
(
	cd "${PROJECT_DIR}" || exit 1
	"${MCPBASH_TEST_ROOT}/bin/mcp-bash" init --name cfg-demo >/dev/null
)

printf ' -> config --show includes name and root\n'
show_output="$(
	cd "${PROJECT_DIR}" || exit 1
	"${MCPBASH_TEST_ROOT}/bin/mcp-bash" config --show
)"

assert_contains "cfg-demo" "${show_output}" "config --show missing project name"
assert_contains "# Claude Desktop" "${show_output}" "config --show missing client heading"
assert_contains "# Cursor" "${show_output}" "config --show missing cursor heading"
canonical_root="$(cd "${PROJECT_DIR}" && (pwd -P 2>/dev/null || pwd))"

printf ' -> config --json descriptor shape\n'
json_output="$(
	cd "${PROJECT_DIR}" || exit 1
	"${MCPBASH_TEST_ROOT}/bin/mcp-bash" config --json
)"

name="$(printf '%s' "${json_output}" | jq -r '.name')"
command_path="$(printf '%s' "${json_output}" | jq -r '.command')"
env_root="$(printf '%s' "${json_output}" | jq -r '.env.MCPBASH_PROJECT_ROOT')"

assert_eq "cfg-demo" "${name}" "config --json name mismatch"
if [ -z "${command_path}" ] || [ ! -x "${command_path}" ]; then
	test_fail "config --json command path is not executable: ${command_path}"
fi
if [ -z "${env_root}" ]; then
	test_fail "config --json missing MCPBASH_PROJECT_ROOT"
fi
expected_root_basename="$(basename "${canonical_root}")"
actual_root_basename="$(basename "${env_root}")"
assert_eq "${expected_root_basename}" "${actual_root_basename}" "config --json project root mismatch"

framework_bin="$(cd "${MCPBASH_TEST_ROOT}" && (pwd -P 2>/dev/null || pwd))/bin/mcp-bash"

printf ' -> config --client cursor filter\n'
cursor_output="$(
	cd "${PROJECT_DIR}" || exit 1
	"${MCPBASH_TEST_ROOT}/bin/mcp-bash" config --client cursor
)"

# --client now outputs pasteable JSON (no prose headings)
if ! printf '%s' "${cursor_output}" | jq -e '.' >/dev/null 2>&1; then
	test_fail "config --client cursor is not valid JSON"
fi
assert_contains "cfg-demo" "${cursor_output}" "config --client cursor missing project name"
assert_contains "MCPBASH_PROJECT_ROOT" "${cursor_output}" "config --client cursor missing env var"
assert_contains "mcpServers" "${cursor_output}" "config --client cursor missing mcpServers wrapper"

printf ' -> config --client claude-desktop\n'
desktop_output="$(
	cd "${PROJECT_DIR}" || exit 1
	"${MCPBASH_TEST_ROOT}/bin/mcp-bash" config --client claude-desktop
)"
if ! printf '%s' "${desktop_output}" | jq -e '.' >/dev/null 2>&1; then
	test_fail "config --client claude-desktop is not valid JSON"
fi
assert_contains "cfg-demo" "${desktop_output}" "config --client claude-desktop missing project name"
assert_contains "MCPBASH_PROJECT_ROOT" "${desktop_output}" "config --client claude-desktop missing env var"
assert_contains "mcpServers" "${desktop_output}" "config --client claude-desktop missing mcpServers wrapper"

printf ' -> config --client claude-cli\n'
cli_output="$(
	cd "${PROJECT_DIR}" || exit 1
	"${MCPBASH_TEST_ROOT}/bin/mcp-bash" config --client claude-cli
)"
if ! printf '%s' "${cli_output}" | jq -e '.' >/dev/null 2>&1; then
	test_fail "config --client claude-cli is not valid JSON"
fi
assert_contains "cfg-demo" "${cli_output}" "config --client claude-cli missing project name"
assert_contains "MCPBASH_PROJECT_ROOT" "${cli_output}" "config --client claude-cli missing env var"

printf ' -> config --client windsurf\n'
windsurf_output="$(
	cd "${PROJECT_DIR}" || exit 1
	"${MCPBASH_TEST_ROOT}/bin/mcp-bash" config --client windsurf
)"
if ! printf '%s' "${windsurf_output}" | jq -e '.' >/dev/null 2>&1; then
	test_fail "config --client windsurf is not valid JSON"
fi
assert_contains "cfg-demo" "${windsurf_output}" "config --client windsurf missing project name"
assert_contains "MCPBASH_PROJECT_ROOT" "${windsurf_output}" "config --client windsurf missing env var"
assert_contains "mcpServers" "${windsurf_output}" "config --client windsurf missing mcpServers wrapper"

printf ' -> config --client librechat\n'
librechat_output="$(
	cd "${PROJECT_DIR}" || exit 1
	"${MCPBASH_TEST_ROOT}/bin/mcp-bash" config --client librechat
)"
if ! printf '%s' "${librechat_output}" | jq -e '.' >/dev/null 2>&1; then
	test_fail "config --client librechat is not valid JSON"
fi
assert_contains "cfg-demo" "${librechat_output}" "config --client librechat missing project name"
assert_contains "MCPBASH_PROJECT_ROOT" "${librechat_output}" "config --client librechat missing env var"

printf ' -> config --inspector helper\n'
inspector_output="$(
	cd "${PROJECT_DIR}" || exit 1
	"${MCPBASH_TEST_ROOT}/bin/mcp-bash" config --inspector
)"
assert_contains "npx @modelcontextprotocol/inspector" "${inspector_output}" "config --inspector missing inspector command"
assert_contains "--transport stdio --" "${inspector_output}" "config --inspector missing transport delimiter"
assert_contains "MCPBASH_PROJECT_ROOT=${canonical_root}" "${inspector_output}" "config --inspector missing project root env"
assert_contains "${framework_bin}" "${inspector_output}" "config --inspector missing framework binary path"

printf 'CLI config variants test passed.\n'
