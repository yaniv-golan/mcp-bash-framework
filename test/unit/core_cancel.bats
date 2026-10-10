#!/usr/bin/env bats
# Unit layer: cancellation escalation in lib/core.sh.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	# shellcheck source=lib/lock.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/lock.sh"
	# shellcheck source=lib/core.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/core.sh"

	MCPBASH_LOCK_ROOT="${BATS_TEST_TMPDIR}/locks"
	MCPBASH_STDOUT_LOCK_NAME="stdout"
	MCPBASH_MAIN_PGID=""
	export MCPBASH_SKIP_PROCESS_GROUP_LOOKUP=1
	mcp_lock_init

	# Stand-ins for the request-id bookkeeping: the "worker" is a process that
	# ignores TERM, so only the KILL escalation can end it.
	mcp_core_get_id_key() { printf '%s' "key1"; }
	mcp_ids_mark_cancelled() { :; }
	mcp_ids_worker_info() { printf '%s %s' "${STUBBORN_PID}" ""; }

	bash -c 'trap "" TERM; while :; do sleep 0.1; done' &
	STUBBORN_PID=$!
}

teardown() {
	kill -9 "${STUBBORN_PID}" 2>/dev/null || true
}

@test "cancel: returns at once and still escalates to KILL" {
	mcp_core_cancel_request '"r1"'
	# The 1s grace before KILL must not run in the caller (the main loop). TERM
	# is ignored, so if the call returned before escalating, the process is
	# still alive now; the old code waited and killed it before returning.
	kill -0 "${STUBBORN_PID}" || fail "cancel waited for the KILL escalation in the caller"

	# ...and the background escalation kills it after the grace period.
	local i=0
	while kill -0 "${STUBBORN_PID}" 2>/dev/null && [ "${i}" -lt 50 ]; do
		sleep 0.1
		i=$((i + 1))
	done
	if kill -0 "${STUBBORN_PID}" 2>/dev/null; then
		fail "TERM-ignoring worker still alive 5s after cancel"
	fi
}

@test "cancel: escalation releases a stdout lock held by the killed worker" {
	mkdir -p "${MCPBASH_LOCK_ROOT}/stdout.lock"
	printf '%s' "${STUBBORN_PID}" >"${MCPBASH_LOCK_ROOT}/stdout.lock/pid"
	mcp_core_cancel_request '"r1"'
	local i=0
	while [ -d "${MCPBASH_LOCK_ROOT}/stdout.lock" ] && [ "${i}" -lt 50 ]; do
		sleep 0.1
		i=$((i + 1))
	done
	[ ! -d "${MCPBASH_LOCK_ROOT}/stdout.lock" ] || fail "stdout lock still held 5s after cancel"
}
