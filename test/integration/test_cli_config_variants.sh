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

printf ' -> config --client cursor filter\n'
cursor_output="$(
	cd "${PROJECT_DIR}" || exit 1
	"${MCPBASH_TEST_ROOT}/bin/mcp-bash" config --client cursor
)"

assert_contains "Cursor:" "${cursor_output}" "config --client cursor missing heading"
assert_contains "cfg-demo" "${cursor_output}" "config --client cursor missing project name"
assert_contains "MCPBASH_PROJECT_ROOT" "${cursor_output}" "config --client cursor missing env var"

printf ' -> config --client claude-desktop\n'
desktop_output="$(
	cd "${PROJECT_DIR}" || exit 1
	"${MCPBASH_TEST_ROOT}/bin/mcp-bash" config --client claude-desktop
)"
assert_contains "Claude Desktop" "${desktop_output}" "config --client claude-desktop missing heading"
assert_contains "cfg-demo" "${desktop_output}" "config --client claude-desktop missing project name"
assert_contains "MCPBASH_PROJECT_ROOT" "${desktop_output}" "config --client claude-desktop missing env var"

printf ' -> config --client claude-cli\n'
cli_output="$(
	cd "${PROJECT_DIR}" || exit 1
	"${MCPBASH_TEST_ROOT}/bin/mcp-bash" config --client claude-cli
)"
assert_contains "Claude CLI" "${cli_output}" "config --client claude-cli missing heading"
assert_contains "cfg-demo" "${cli_output}" "config --client claude-cli missing project name"
assert_contains "MCPBASH_PROJECT_ROOT" "${cli_output}" "config --client claude-cli missing env var"

printf ' -> config --client windsurf\n'
windsurf_output="$(
	cd "${PROJECT_DIR}" || exit 1
	"${MCPBASH_TEST_ROOT}/bin/mcp-bash" config --client windsurf
)"
assert_contains "Windsurf" "${windsurf_output}" "config --client windsurf missing heading"
assert_contains "cfg-demo" "${windsurf_output}" "config --client windsurf missing project name"
assert_contains "MCPBASH_PROJECT_ROOT" "${windsurf_output}" "config --client windsurf missing env var"

printf ' -> config --client librechat\n'
librechat_output="$(
	cd "${PROJECT_DIR}" || exit 1
	"${MCPBASH_TEST_ROOT}/bin/mcp-bash" config --client librechat
)"
assert_contains "LibreChat" "${librechat_output}" "config --client librechat missing heading"
assert_contains "cfg-demo" "${librechat_output}" "config --client librechat missing project name"
assert_contains "MCPBASH_PROJECT_ROOT" "${librechat_output}" "config --client librechat missing env var"

printf 'CLI config variants test passed.\n'
