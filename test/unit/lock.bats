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
