#!/usr/bin/env bats
# Unit layer: roots canonicalization and run-tool overrides.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/roots.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/roots.sh"
	# shellcheck source=lib/cli/run_tool.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/cli/run_tool.sh"

	ROOT_OK="${BATS_TEST_TMPDIR}/ok-root"
	mkdir -p "${ROOT_OK}"
}

@test "roots: canonicalize rejects missing path (strict)" {
	run mcp_roots_canonicalize_checked "${BATS_TEST_TMPDIR}/missing" "test" 1
	assert_failure
}

@test "roots: canonicalize accepts existing path and resolves traversal" {
	resolved="$(mcp_roots_canonicalize_checked "${ROOT_OK}/../ok-root" "test" 1)"
	expected="$(cd "${ROOT_OK}" && pwd -P)"
	assert_equal "${expected}" "${resolved}"
}

@test "roots: run-tool --roots fails on invalid entry" {
	run bash -c "MCPBASH_PROJECT_ROOT='${BATS_TEST_TMPDIR}' . '${MCPBASH_HOME}/lib/cli/run_tool.sh'; mcp_cli_run_tool_prepare_roots '${BATS_TEST_TMPDIR}/nope'"
	assert_failure
}

@test "roots: run-tool --roots accepts existing entry" {
	run bash -c "MCPBASH_PROJECT_ROOT='${BATS_TEST_TMPDIR}' . '${MCPBASH_HOME}/lib/cli/run_tool.sh'; mcp_cli_run_tool_prepare_roots '${ROOT_OK}'"
	assert_success
}
