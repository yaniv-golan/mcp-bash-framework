#!/usr/bin/env bats
# Ensure JSON error logs never include raw payloads.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	# shellcheck source=lib/json.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/json.sh"

	MCPBASH_FORCE_MINIMAL=false
	mcp_runtime_detect_json_tool
	if [ "${MCPBASH_MODE}" = "minimal" ]; then
		skip "JSON tooling unavailable for error logging test"
	fi
}

@test "json_error_logging: JSON parse failure logs are bounded/single-line" {
	padding="$(printf 'x%.0s' {1..1500})"
	secret="Authorization: Bearer SHOULD_NOT_APPEAR"
	# Invalid JSON (unterminated string), with an early newline and a large prefix to
	# ensure the secret is beyond the excerpt cap.
	payload_prefix=$'{"a":"NL_TEST\n'
	payload="${payload_prefix}${padding}${secret}"

	run mcp_json_normalize_line "${payload}"
	assert_failure

	# Single-line invariant: command substitution strips trailing newlines; any
	# remaining newline indicates log injection / unsafe excerpt handling.
	refute_output --partial $'\n'

	# Must not include the secret (it's beyond the excerpt limit).
	refute_output --partial "${secret}"

	# Should include structured fields.
	assert_output --partial 'JSON normalization failed'
	assert_output --partial 'bytes='
	assert_output --partial 'sha256='
	assert_output --partial 'truncated='
	assert_output --partial 'excerpt="'
}

@test "json_error_logging: regression guard - no raw payload printf remains" {
	# SECURITY: prevent reintroducing raw `${json}`/`${line}` in error-path printf statements.
	run grep -E "printf '.*failed for: %s.*'\\s+\\\"\\$\\{(json|line)\\}\\\"" "${MCPBASH_HOME}/lib/json.sh"
	assert_failure
}
