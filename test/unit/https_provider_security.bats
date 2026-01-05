#!/usr/bin/env bats
# Unit tests for HTTPS provider SSRF guardrails.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	PROVIDER="${MCPBASH_HOME}/providers/https.sh"
	tmp_err="${BATS_TEST_TMPDIR}/stderr.txt"
	: >"${tmp_err}"
}

run_provider() {
	local uri="$1"
	shift || true
	: >"${tmp_err}"
	local home="${MCPBASH_HOME_OVERRIDE:-${MCPBASH_HOME}}"
	MCPBASH_HOME="${home}" \
		MCPBASH_HTTPS_ALLOW_HOSTS="${MCPBASH_HTTPS_ALLOW_HOSTS:-}" \
		MCPBASH_HTTPS_DENY_HOSTS="${MCPBASH_HTTPS_DENY_HOSTS:-}" \
		MCPBASH_HTTPS_ALLOW_ALL="${MCPBASH_HTTPS_ALLOW_ALL:-}" \
		bash "${PROVIDER}" "${uri}" 1>/dev/null 2>"${tmp_err}"
}

@test "https_security: blocks localhost (private host)" {
	run run_provider "https://localhost/"
	assert_equal "4" "${status}"
}

@test "https_security: blocks userinfo@127.0.0.1 (SSRF bypass regression)" {
	run run_provider "https://user@127.0.0.1/"
	assert_equal "4" "${status}"
}

@test "https_security: blocks user:pass@localhost (SSRF bypass regression)" {
	run run_provider "https://user:pass@localhost/"
	assert_equal "4" "${status}"
}

@test "https_security: blocks obfuscated integer IPv4 host literal" {
	run run_provider "https://2130706433/"
	assert_equal "4" "${status}"
}

@test "https_security: denies public hosts by default unless allowlisted" {
	unset MCPBASH_HTTPS_ALLOW_HOSTS MCPBASH_HTTPS_ALLOW_ALL
	run run_provider "https://example.com/"
	assert_equal "4" "${status}"

	run grep -q "requires MCPBASH_HTTPS_ALLOW_HOSTS" "${tmp_err}"
	assert_success
}

@test "https_security: enforces allowlist even if policy helpers cannot be sourced" {
	MCPBASH_HOME_OVERRIDE="${BATS_TEST_TMPDIR}/missing-home"
	MCPBASH_HTTPS_ALLOW_HOSTS="allowed.example.com"
	unset MCPBASH_HTTPS_ALLOW_ALL

	run run_provider "https://example.com/"
	assert_equal "4" "${status}"
}
