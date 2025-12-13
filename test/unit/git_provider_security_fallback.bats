#!/usr/bin/env bash
# Unit: git provider should enforce allow/deny lists even without policy.sh.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=test/common/assert.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/assert.sh"

TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/mcpbash-test.XXXXXX")"
export TEST_TMPDIR
trap 'rm -rf "${TEST_TMPDIR}" 2>/dev/null || true' EXIT

tmp_err="${TEST_TMPDIR}/stderr.txt"
: >"${tmp_err}"

# Copy the provider into an isolated dir WITHOUT ../lib/policy.sh to force
# fallback mode (simulates partial/incorrect installation layouts).
mkdir -p "${TEST_TMPDIR}/providers"
cp "${REPO_ROOT}/providers/git.sh" "${TEST_TMPDIR}/providers/git.sh"

PROVIDER="${TEST_TMPDIR}/providers/git.sh"

run_provider() {
	local uri="$1"
	: >"${tmp_err}"
	MCPBASH_ENABLE_GIT_PROVIDER=true \
		MCPBASH_HOME="${TEST_TMPDIR}/missing-home" \
		MCPBASH_GIT_ALLOW_HOSTS="${MCPBASH_GIT_ALLOW_HOSTS:-}" \
		MCPBASH_GIT_DENY_HOSTS="${MCPBASH_GIT_DENY_HOSTS:-}" \
		MCPBASH_GIT_ALLOW_ALL="${MCPBASH_GIT_ALLOW_ALL:-}" \
		bash "${PROVIDER}" "${uri}" 1>/dev/null 2>"${tmp_err}"
}

printf ' -> enforces allowlist in fallback mode (no policy.sh)
'
MCPBASH_GIT_ALLOW_HOSTS="allowed.example.com"
unset MCPBASH_GIT_ALLOW_ALL
set +e
run_provider "git+https://example.com/repo#main:README.md"
rc=$?
set -e
assert_eq "4" "${rc}" "expected exit 4 for non-allowlisted host even in fallback mode"

