#!/usr/bin/env bats
# Unit layer: mcp_core_server_alive (lib/core.sh), the ps branch.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	if [ -r "/proc/$$/stat" ]; then
		skip "this platform uses /proc, not ps"
	fi
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	# shellcheck source=lib/core.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/core.sh"
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "${STUB_BIN}"
}

stub_ps() {
	printf '#!/bin/sh\n%s\n' "$1" >"${STUB_BIN}/ps"
	chmod +x "${STUB_BIN}/ps"
}

@test "server_alive: a running server is alive" {
	stub_ps "printf 'Ss+\\n'"
	PATH="${STUB_BIN}:${PATH}" run mcp_core_server_alive
	assert_success
}

@test "server_alive: a zombie server is not alive" {
	stub_ps "printf 'Z+\\n'"
	PATH="${STUB_BIN}:${PATH}" run mcp_core_server_alive
	assert_failure
}

@test "server_alive: ps output listing several processes falls back to kill -0" {
	stub_ps "printf 'Z\\nS\\n'"
	PATH="${STUB_BIN}:${PATH}" run mcp_core_server_alive
	assert_success
}

@test "server_alive: a failing ps falls back to kill -0" {
	stub_ps "exit 1"
	PATH="${STUB_BIN}:${PATH}" run mcp_core_server_alive
	assert_success
}

@test "server_alive: the real ps reports this process alive" {
	run mcp_core_server_alive
	assert_success
}
