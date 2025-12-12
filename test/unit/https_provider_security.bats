#!/usr/bin/env bash
# Unit tests for HTTPS provider SSRF guardrails.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=test/common/assert.sh
# shellcheck disable=SC1091
. "${REPO_ROOT}/test/common/assert.sh"

tmp_err=""

test_create_tmpdir() {
	# Minimal local helper (avoid depending on other test env helpers)
	TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/mcpbash-test.XXXXXX")"
	export TEST_TMPDIR
	trap 'rm -rf "${TEST_TMPDIR}" 2>/dev/null || true' EXIT
}

test_create_tmpdir

PROVIDER="${REPO_ROOT}/providers/https.sh"

run_provider() {
	local uri="$1"
	shift || true
	# Capture stderr so we can assert on error messages.
	tmp_err="${TEST_TMPDIR}/stderr.txt"
	: >"${tmp_err}"
	MCPBASH_HOME="${REPO_ROOT}" \
		MCPBASH_HTTPS_ALLOW_HOSTS="${MCPBASH_HTTPS_ALLOW_HOSTS:-}" \
		MCPBASH_HTTPS_DENY_HOSTS="${MCPBASH_HTTPS_DENY_HOSTS:-}" \
		MCPBASH_HTTPS_ALLOW_ALL="${MCPBASH_HTTPS_ALLOW_ALL:-}" \
		bash "${PROVIDER}" "${uri}" 1>/dev/null 2>"${tmp_err}"
}

printf ' -> blocks localhost (private host)
'
set +e
run_provider "https://localhost/"
rc=$?
set -e
assert_eq "4" "${rc}" "expected exit 4 for private host"

printf ' -> blocks userinfo@127.0.0.1 (userinfo SSRF bypass regression)
'
set +e
run_provider "https://user@127.0.0.1/"
rc=$?
set -e
assert_eq "4" "${rc}" "expected exit 4 for userinfo private IP"

printf ' -> blocks user:pass@localhost (userinfo SSRF bypass regression)
'
set +e
run_provider "https://user:pass@localhost/"
rc=$?
set -e
assert_eq "4" "${rc}" "expected exit 4 for userinfo localhost"

printf ' -> blocks obfuscated integer IPv4 host literal
'
set +e
run_provider "https://2130706433/"
rc=$?
set -e
assert_eq "4" "${rc}" "expected exit 4 for obfuscated integer IP"

printf ' -> denies public hosts by default unless allowlisted
'
unset MCPBASH_HTTPS_ALLOW_HOSTS MCPBASH_HTTPS_ALLOW_ALL
set +e
run_provider "https://example.com/"
rc=$?
set -e
assert_eq "4" "${rc}" "expected exit 4 for public host when no allowlist"
if ! grep -q "requires MCPBASH_HTTPS_ALLOW_HOSTS" "${tmp_err}"; then
	test_fail "expected deny-by-default allowlist message"
fi
