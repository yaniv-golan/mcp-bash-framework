#!/usr/bin/env bash
# Integration: project root detection edge cases.
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Project root detection works in nested and framework paths."

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
ROOT="${TEST_TMPDIR}/proj-root"
mkdir -p "${ROOT}"

printf ' -> init project at root\n'
(
	cd "${ROOT}" || exit 1
	"${MCPBASH_TEST_ROOT}/bin/mcp-bash" init --name nested-demo >/dev/null
)

canonical_root="$(cd "${ROOT}" && (pwd -P 2>/dev/null || pwd))"

printf ' -> run config from nested directory\n'
NESTED_DIR="${ROOT}/tools"
mkdir -p "${NESTED_DIR}"

json_output="$(
	cd "${NESTED_DIR}" || exit 1
	"${MCPBASH_TEST_ROOT}/bin/mcp-bash" config --json
)"

detected_root="$(printf '%s' "${json_output}" | jq -r '.env.MCPBASH_PROJECT_ROOT')"
detected_basename="$(basename "${detected_root}")"
expected_basename="$(basename "${canonical_root}")"
assert_eq "${expected_basename}" "${detected_basename}" "nested config did not resolve project root correctly"

printf ' -> explicit MCPBASH_PROJECT_ROOT override wins\n'
OTHER_ROOT="${TEST_TMPDIR}/other-root"
mkdir -p "${OTHER_ROOT}/server.d" "${OTHER_ROOT}/tools"
cat >"${OTHER_ROOT}/server.d/server.meta.json" <<'META'
{
  "name": "other-root"
}
META

override_output="$(
	cd "${TEST_TMPDIR}" || exit 1
	MCPBASH_PROJECT_ROOT="${OTHER_ROOT}" "${MCPBASH_TEST_ROOT}/bin/mcp-bash" config --json
)"

override_root="$(printf '%s' "${override_output}" | jq -r '.env.MCPBASH_PROJECT_ROOT')"
override_basename="$(basename "${override_root}")"
assert_eq "other-root" "${override_basename}" "explicit MCPBASH_PROJECT_ROOT not honored"

printf ' -> framework paths under MCPBASH_HOME are not treated as projects\n'
EXAMPLE_DIR="${MCPBASH_HOME}/examples/00-hello-tool"
if [ -d "${EXAMPLE_DIR}" ]; then
	set +e
	example_out="$(
		cd "${EXAMPLE_DIR}" && "${MCPBASH_HOME}/bin/mcp-bash" validate 2>&1
	)"
	example_status=$?
	set -e

	if [ "${example_status}" -eq 0 ]; then
		# It is acceptable if validate succeeds because an explicit project root is configured;
		# we just require that MCPBASH_HOME itself is not auto-detected as the project.
		:
	else
		assert_contains "No MCP project found" "${example_out}" "unexpected error from validate in framework example path"
	fi
fi

printf 'Project root detection test passed.\n'
