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
INSTALL_BRANCH="$(git -C "${MCPBASH_TEST_ROOT}" rev-parse --abbrev-ref HEAD)"
MCPBASH_INSTALL_LOCAL_SOURCE="${MCPBASH_TEST_ROOT}" "${MCPBASH_TEST_ROOT}/install.sh" --dir "${INSTALL_ROOT}" --branch "${INSTALL_BRANCH}" --yes

assert_file_exists "${INSTALL_ROOT}/bin/mcp-bash"
assert_file_exists "${INSTALL_ROOT}/VERSION"

installed_version="$("${INSTALL_ROOT}/bin/mcp-bash" --version | awk '{print $2}')"
repo_version="$(tr -d '[:space:]' <"${MCPBASH_TEST_ROOT}/VERSION")"

assert_eq "${repo_version}" "${installed_version}" "installed version mismatch"

printf ' -> idempotent re-run into same directory\n'
MCPBASH_INSTALL_LOCAL_SOURCE="${MCPBASH_TEST_ROOT}" "${MCPBASH_TEST_ROOT}/install.sh" --dir "${INSTALL_ROOT}" --branch "${INSTALL_BRANCH}" --yes

installed_version_2="$("${INSTALL_ROOT}/bin/mcp-bash" --version | awk '{print $2}')"
assert_eq "${installed_version}" "${installed_version_2}" "version changed after re-install"

printf ' -> install from local archive (release-style layout)\n'
ARCHIVE_INSTALL_ROOT="${TEST_TMPDIR}/install-archive"
ARCHIVE_PATH="${TEST_TMPDIR}/mcp-bash-v0.0.0.tar.gz"
ARCHIVE_STAGE="${TEST_TMPDIR}/archive-stage"
mkdir -p "${ARCHIVE_STAGE}/mcp-bash"
(cd "${MCPBASH_TEST_ROOT}" && tar -cf - --exclude .git .) | (cd "${ARCHIVE_STAGE}/mcp-bash" && tar -xf -)
(cd "${ARCHIVE_STAGE}" && tar -czf "${ARCHIVE_PATH}" mcp-bash)
archive_sha=""
if command -v sha256sum >/dev/null 2>&1; then
	archive_sha="$(sha256sum "${ARCHIVE_PATH}" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
	archive_sha="$(shasum -a 256 "${ARCHIVE_PATH}" | awk '{print $1}')"
else
	test_fail "neither sha256sum nor shasum is available"
fi
"${MCPBASH_TEST_ROOT}/install.sh" --dir "${ARCHIVE_INSTALL_ROOT}" --archive "${ARCHIVE_PATH}" --verify "${archive_sha}" --yes
assert_file_exists "${ARCHIVE_INSTALL_ROOT}/bin/mcp-bash"
assert_file_exists "${ARCHIVE_INSTALL_ROOT}/VERSION"

printf ' -> tagged archive auto-verifies using SHA256SUMS when present\n'
ARCHIVE_AUTO_ROOT="${TEST_TMPDIR}/install-archive-auto"
printf '%s  %s\n' "${archive_sha}" "mcp-bash-v0.0.0.tar.gz" >"${TEST_TMPDIR}/SHA256SUMS"
"${MCPBASH_TEST_ROOT}/install.sh" --dir "${ARCHIVE_AUTO_ROOT}" --archive "${ARCHIVE_PATH}" --version "v0.0.0" --yes
assert_file_exists "${ARCHIVE_AUTO_ROOT}/bin/mcp-bash"
assert_file_exists "${ARCHIVE_AUTO_ROOT}/VERSION"

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
