#!/usr/bin/env bats
# Unit layer: the test harness hands the server a CI-mode value it accepts.
# The server enables CI mode only for "true"; the harness also accepts 1 and yes.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

harness_ci_mode() {
	MCPBASH_CI_MODE="$1" bash -c '. "$1" >/dev/null 2>&1; printf "%s" "${MCPBASH_CI_MODE-unset}"' _ "$2"
}

@test "test_harness: env.sh turns MCPBASH_CI_MODE=1 or yes into true" {
	for value in 1 yes true; do
		run harness_ci_mode "${value}" "${MCPBASH_HOME}/test/common/env.sh"
		assert_output "true"
	done
}

@test "test_harness: fixtures turns MCPBASH_CI_MODE=1 or yes into true" {
	for value in 1 yes true; do
		run harness_ci_mode "${value}" "${MCPBASH_HOME}/test/common/fixtures.bash"
		assert_output "true"
	done
}

@test "test_harness: other MCPBASH_CI_MODE values pass through unchanged" {
	for value in false 0 ""; do
		run harness_ci_mode "${value}" "${MCPBASH_HOME}/test/common/env.sh"
		assert_output "${value}"
	done
}
