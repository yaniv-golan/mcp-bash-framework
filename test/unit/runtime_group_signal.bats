#!/usr/bin/env bats
# Unit layer: delayed signals to a process group or to pids (lib/runtime.sh)
# reach only processes the server started. A process group id, like a pid,
# can be handed out again once every member of the old group has exited.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "${STUB_BIN}"
	# A ps that prints the table in $PS_TABLE ("pid pgid" lines), whatever
	# it is asked.
	printf '#!/bin/sh\ncat "${PS_TABLE}" 2>/dev/null\n' >"${STUB_BIN}/ps"
	chmod +x "${STUB_BIN}/ps"
	export PS_TABLE="${BATS_TEST_TMPDIR}/table"
	: >"${PS_TABLE}"
	KILLS="${BATS_TEST_TMPDIR}/kills"
	: >"${KILLS}"
	# Record signals instead of sending them.
	kill() { printf '%s\n' "$*" >>"${KILLS}"; }
}

table() { printf '%s\n' "$@" >"${PS_TABLE}"; }

@test "pgid lookup: nothing, not the pid, when nothing can say" {
	# A pid with no /proc entry, and a ps that prints nothing: the pid must
	# not be taken for its own group (it would look isolated).
	PATH="${STUB_BIN}:${PATH}" run mcp_runtime_lookup_pgid 999999
	assert_success
	assert_output ""
}

@test "group snapshot: the group's members and the listed pids" {
	table '100 100' '101 100' '102 7' '200 200'
	PATH="${STUB_BIN}:${PATH}" run mcp_runtime_group_snapshot 100 102
	assert_success
	assert_output '100 100
101 100
102 7'
}

@test "checked signal: a group id taken by someone else is left alone" {
	table '200 100' '201 100'
	PATH="${STUB_BIN}:${PATH}" mcp_runtime_signal_checked KILL 100 100 "" $'100 100\n101 100'
	run cat "${KILLS}"
	assert_output ""
}

@test "checked signal: the group is signalled while a member we started is in it" {
	table '101 100' '300 100'
	PATH="${STUB_BIN}:${PATH}" mcp_runtime_signal_checked KILL 100 100 "" $'100 100\n101 100'
	run cat "${KILLS}"
	assert_output "-KILL -100"
}

@test "checked signal: without a group, only the pids still ours" {
	table '501 50' '502 50' '600 50'
	PATH="${STUB_BIN}:${PATH}" mcp_runtime_signal_checked KILL "" 500 "" $'500 50\n501 50\n502 51'
	run cat "${KILLS}"
	assert_output "-KILL 501"
}

@test "checked signal: the server's own group is never signalled" {
	table '101 100'
	PATH="${STUB_BIN}:${PATH}" mcp_runtime_signal_checked KILL 100 101 100 $'101 100'
	run cat "${KILLS}"
	assert_output "-KILL 101"
}

@test "checked signal: with no snapshot (ps can't list), as before" {
	PATH="${STUB_BIN}:${PATH}" mcp_runtime_signal_checked KILL 100 100 "" ""
	run cat "${KILLS}"
	assert_output "-KILL -100"
}
