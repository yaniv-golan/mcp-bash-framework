#!/usr/bin/env bash
# Integration: installer script basic flows (local source).
# shellcheck disable=SC2034  # Used by test runner for reporting.
TEST_DESC="Installer installs from local source and handles failures."

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/env.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/env.sh"
# shellcheck source=../common/assert.sh
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../common/assert.sh"

test_require_command git

test_create_tmpdir
INSTALL_ROOT="${TEST_TMPDIR}/install-root"

printf ' -> install from local source\n'
MCPBASH_INSTALL_LOCAL_SOURCE="${MCPBASH_TEST_ROOT}" "${MCPBASH_TEST_ROOT}/install.sh" --dir "${INSTALL_ROOT}" --yes

assert_file_exists "${INSTALL_ROOT}/bin/mcp-bash"
assert_file_exists "${INSTALL_ROOT}/VERSION"

installed_version="$("${INSTALL_ROOT}/bin/mcp-bash" --version | awk '{print $2}')"
repo_version="$(tr -d '[:space:]' <"${MCPBASH_TEST_ROOT}/VERSION")"

assert_eq "${repo_version}" "${installed_version}" "installed version mismatch"

printf ' -> idempotent re-run into same directory\n'
MCPBASH_INSTALL_LOCAL_SOURCE="${MCPBASH_TEST_ROOT}" "${MCPBASH_TEST_ROOT}/install.sh" --dir "${INSTALL_ROOT}" --yes

installed_version_2="$("${INSTALL_ROOT}/bin/mcp-bash" --version | awk '{print $2}')"
assert_eq "${installed_version}" "${installed_version_2}" "version changed after re-install"

printf ' -> installer handles nonexistent local source\n'
BAD_ROOT="${TEST_TMPDIR}/does-not-exist"
if MCPBASH_INSTALL_LOCAL_SOURCE="${BAD_ROOT}" "${MCPBASH_TEST_ROOT}/install.sh" --dir "${TEST_TMPDIR}/bad-install" --yes >/dev/null 2>&1; then
	test_fail "installer succeeded with nonexistent local source"
fi

printf ' -> installer fails cleanly on invalid branch (local repo)\n'
LOCAL_REPO="${TEST_TMPDIR}/source-repo"
git init -q --bare "${LOCAL_REPO}"

INVALID_DIR="${TEST_TMPDIR}/invalid-branch-install"
# Override SHELL to avoid extra shell-config noise in this failure case; not
# required for correctness, but keeps the output focused.
set +e
SHELL="/bin/false" MCPBASH_INSTALL_REPO_URL="${LOCAL_REPO}" "${MCPBASH_TEST_ROOT}/install.sh" --dir "${INVALID_DIR}" --branch does-not-exist --yes >/dev/null 2>&1
status=$?
set -e
if [ "${status}" -eq 0 ]; then
	test_fail "installer succeeded with invalid branch against local repo"
fi

printf 'Installer integration test passed.\n'
