#!/usr/bin/env bats
# Unit layer: validate lock helpers from lib/lock.sh.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../../node_modules/bats-file/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	# shellcheck source=lib/lock.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/lock.sh"

	MCPBASH_TMP_ROOT="${BATS_TEST_TMPDIR}"
	export MCPBASH_PROJECT_ROOT="${BATS_TEST_TMPDIR}"
	mcp_runtime_init_paths

	MCPBASH_LOCK_ROOT="${BATS_TEST_TMPDIR}/locks"
}

@test "lock: initialization" {
	mcp_lock_init
	assert_equal "${BATS_TEST_TMPDIR}/locks" "${MCPBASH_LOCK_ROOT}"
}

@test "lock: acquire/release cycle" {
	mcp_lock_init
	mcp_lock_acquire "unit"
	assert_file_exist "${MCPBASH_LOCK_ROOT}/unit.lock/pid"

	mcp_lock_release "unit"
	[ ! -d "${MCPBASH_LOCK_ROOT}/unit.lock" ]
}

@test "lock: reap stale owner" {
	mcp_lock_init
	mkdir -p "${MCPBASH_LOCK_ROOT}/stale.lock"
	printf '%s' "999999" >"${MCPBASH_LOCK_ROOT}/stale.lock/pid"

	mcp_lock_acquire "stale"
	assert_file_exist "${MCPBASH_LOCK_ROOT}/stale.lock/pid"
	mcp_lock_release "stale"
}

@test "lock: grace period for pid creation" {
	mcp_lock_init
	MCPBASH_LOCK_REAP_GRACE_SECS=5
	mkdir -p "${MCPBASH_LOCK_ROOT}/grace.lock"

	mcp_lock_try_reap "${MCPBASH_LOCK_ROOT}/grace.lock"
	[ -d "${MCPBASH_LOCK_ROOT}/grace.lock" ]

	MCPBASH_LOCK_REAP_GRACE_SECS=0
	mcp_lock_try_reap "${MCPBASH_LOCK_ROOT}/grace.lock"
	[ ! -d "${MCPBASH_LOCK_ROOT}/grace.lock" ]
}

# Run a lock call in a child shell; fail the test if it is still running after
# 5 seconds. Workers still running when the server exits must not spin forever
# on a lock root that cleanup deleted.
lock_call_in_child() {
	local call="$1"
	bash -c '
		set -euo pipefail
		. "$1/lib/lock.sh"
		MCPBASH_LOCK_ROOT="$2"
		'"${call}"'
	' _ "${MCPBASH_HOME}" "${MCPBASH_LOCK_ROOT}" &
	LOCK_CHILD_PID=$!
}

wait_for_lock_child() {
	local i=0
	while kill -0 "${LOCK_CHILD_PID}" 2>/dev/null && [ "${i}" -lt 50 ]; do
		sleep 0.1
		i=$((i + 1))
	done
	if kill -0 "${LOCK_CHILD_PID}" 2>/dev/null; then
		kill "${LOCK_CHILD_PID}" 2>/dev/null || true
		fail "lock waiter still spinning 5s after the lock root was removed"
	fi
	local status=0
	wait "${LOCK_CHILD_PID}" || status=$?
	[ "${status}" -ne 0 ]
}

@test "lock: acquire gives up when the lock root does not exist" {
	MCPBASH_LOCK_ROOT="${BATS_TEST_TMPDIR}/gone-locks"
	lock_call_in_child 'mcp_lock_acquire "unit"'
	wait_for_lock_child
}

@test "lock: acquire_timeout without a limit gives up when the lock root does not exist" {
	MCPBASH_LOCK_ROOT="${BATS_TEST_TMPDIR}/gone-locks"
	lock_call_in_child 'mcp_lock_acquire_timeout "unit" 0'
	wait_for_lock_child
}

@test "lock: a waiter exits when the lock root is deleted mid-wait" {
	mcp_lock_init
	mkdir -p "${MCPBASH_LOCK_ROOT}/held.lock"
	# Owned by this live test shell, so the waiter cannot reap it.
	printf '%s' "$$" >"${MCPBASH_LOCK_ROOT}/held.lock/pid"
	lock_call_in_child 'mcp_lock_acquire "held"'
	sleep 0.5
	kill -0 "${LOCK_CHILD_PID}"
	rm -rf "${MCPBASH_LOCK_ROOT}"
	wait_for_lock_child
}
