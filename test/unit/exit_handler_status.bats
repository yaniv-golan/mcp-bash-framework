#!/usr/bin/env bats
# Unit layer: the server's EXIT trap (_mcp_exit_handler in lib/core.sh) reports
# a fatal shell error as a failure. Bash 3.2 runs the EXIT trap with $? = 0
# after one, so without a check the server exited 0.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

# Runs a script that installs the real exit handler, then does $1.
run_with_handler() {
	local action="$1" shell="${2:-bash}"
	local script="${BATS_TEST_TMPDIR}/probe.sh"
	cat >"${script}" <<EOF
set -euo pipefail
mcp_runtime_cleanup() { printf 'cleanup\n' >"${BATS_TEST_TMPDIR}/cleanup.ran"; }
. "${MCPBASH_HOME}/lib/core.sh"
trap '_mcp_exit_handler' EXIT
${action}
EOF
	rm -f "${BATS_TEST_TMPDIR}/cleanup.ran"
	run "${shell}" "${script}"
}

shells() {
	printf '%s\n' bash
	if [ -x /bin/bash ]; then
		printf '%s\n' /bin/bash
	fi
}

@test "exit handler: an unbound variable exits non-zero" {
	local shell
	while IFS= read -r shell; do
		run_with_handler 'f() { printf "%s" "${undefined_variable_xyz}"; }; f' "${shell}"
		[ "${status}" -ne 0 ] || fail "${shell}: fatal error exited 0"
		[ -f "${BATS_TEST_TMPDIR}/cleanup.ran" ] || fail "${shell}: cleanup did not run"
	done < <(shells)
}

@test "exit handler: an intended exit 0 stays 0" {
	local shell
	while IFS= read -r shell; do
		run_with_handler '_MCPBASH_EXIT_CLEAN=true; exit 0' "${shell}"
		assert_success
	done < <(shells)
}

@test "exit handler: non-zero statuses pass through" {
	local shell
	while IFS= read -r shell; do
		run_with_handler 'exit 143' "${shell}"
		assert_equal "${status}" "143"
		run_with_handler 'exit 2' "${shell}"
		assert_equal "${status}" "2"
	done < <(shells)
}
