#!/usr/bin/env bats
# Unit: git provider should enforce allow/deny lists even without policy.sh.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	tmp_err="${BATS_TEST_TMPDIR}/stderr.txt"
	: >"${tmp_err}"

	# Copy the provider into an isolated dir WITHOUT ../lib/policy.sh to force
	# fallback mode (simulates partial/incorrect installation layouts).
	mkdir -p "${BATS_TEST_TMPDIR}/providers"
	cp "${MCPBASH_HOME}/providers/git.sh" "${BATS_TEST_TMPDIR}/providers/git.sh"

	PROVIDER="${BATS_TEST_TMPDIR}/providers/git.sh"
}

run_provider() {
	local uri="$1"
	: >"${tmp_err}"
	MCPBASH_ENABLE_GIT_PROVIDER=true \
		MCPBASH_HOME="${BATS_TEST_TMPDIR}/missing-home" \
		MCPBASH_GIT_ALLOW_HOSTS="${MCPBASH_GIT_ALLOW_HOSTS:-}" \
		MCPBASH_GIT_DENY_HOSTS="${MCPBASH_GIT_DENY_HOSTS:-}" \
		MCPBASH_GIT_ALLOW_ALL="${MCPBASH_GIT_ALLOW_ALL:-}" \
		bash "${PROVIDER}" "${uri}" 1>/dev/null 2>"${tmp_err}"
}

@test "git_provider: enforces allowlist in fallback mode (no policy.sh)" {
	MCPBASH_GIT_ALLOW_HOSTS="allowed.example.com"
	unset MCPBASH_GIT_ALLOW_ALL

	run run_provider "git+https://example.com/repo#main:README.md"
	assert_equal "4" "${status}"
}
