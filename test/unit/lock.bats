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
	# Older than any grace window (mtimes are whole seconds).
	touch -t 202001010000 "${MCPBASH_LOCK_ROOT}/grace.lock"
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

# Several processes contend for one lock; at most one may hold it at a time.
# The critical section marks itself with mkdir, which fails if another holder
# is inside. Before the fix, a waiter that read an empty pid file reaped the
# live lock, and two holders overlapped.
@test "lock: contending processes never hold the lock together" {
	mcp_lock_init
	local marks="${BATS_TEST_TMPDIR}/marks"
	mkdir -p "${marks}"
	local w
	for w in 1 2 3 4 5 6; do
		bash -c '
			set -euo pipefail
			. "$1/lib/lock.sh"
			MCPBASH_LOCK_ROOT="$2"
			marks="$3"
			i=0
			while [ "${i}" -lt 40 ]; do
				mcp_lock_acquire "contended"
				if ! mkdir "${marks}/inside" 2>/dev/null; then
					printf "x" >>"${marks}/overlaps"
				fi
				rmdir "${marks}/inside" 2>/dev/null || true
				mcp_lock_release "contended"
				i=$((i + 1))
			done
		' _ "${MCPBASH_HOME}" "${MCPBASH_LOCK_ROOT}" "${marks}" 2>>"${marks}/stderr" &
	done
	wait
	local overlaps=0
	if [ -f "${marks}/overlaps" ]; then
		overlaps="$(wc -c <"${marks}/overlaps" | tr -d ' ')"
	fi
	if [ "${overlaps}" -ne 0 ]; then
		fail "lock held by two processes at once ${overlaps} time(s) in 240 acquisitions"
	fi
	if [ -s "${marks}/stderr" ]; then
		fail "lock helpers wrote to stderr: $(head -n 3 "${marks}/stderr")"
	fi
	[ ! -d "${MCPBASH_LOCK_ROOT}/contended.lock" ]
}

@test "lock: reap leaves a lock created after the one it saw was released" {
	mcp_lock_init
	local path="${MCPBASH_LOCK_ROOT}/handoff.lock"
	mkdir -p "${path}"
	# Replay the interleaving: the reaper reads no pid (the holder is
	# mid-release), the holder's release finishes before the reaper stats the
	# path, and a new holder takes the lock before the reaper acts.
	eval "mcp_lock_test_orig_$(declare -f mcp_lock_stat_mtime)"
	mcp_lock_stat_mtime() {
		local m
		rm -rf "$1"
		m="$(mcp_lock_test_orig_mcp_lock_stat_mtime "$1")"
		mkdir "$1"
		printf '%s' "$$" >"$1/pid"
		printf '%s' "${m}"
	}
	mcp_lock_reap_now "${path}"
	[ -d "${path}" ]
	assert_equal "$(cat "${path}/pid")" "$$"
}

@test "lock: release leaves a lock with no pid yet (acquire in progress)" {
	mcp_lock_init
	mkdir -p "${MCPBASH_LOCK_ROOT}/pending.lock"
	mcp_lock_release "pending"
	[ -d "${MCPBASH_LOCK_ROOT}/pending.lock" ]
}

@test "lock: reap leaves an empty pid file within the grace period" {
	mcp_lock_init
	MCPBASH_LOCK_REAP_GRACE_SECS=5
	mkdir -p "${MCPBASH_LOCK_ROOT}/empty.lock"
	: >"${MCPBASH_LOCK_ROOT}/empty.lock/pid"
	mcp_lock_try_reap "${MCPBASH_LOCK_ROOT}/empty.lock"
	[ -d "${MCPBASH_LOCK_ROOT}/empty.lock" ]
}

@test "lock: release_owned clears a lock held by the given pid" {
	mcp_lock_init
	mkdir -p "${MCPBASH_LOCK_ROOT}/worker.lock"
	printf '%s' "$$" >"${MCPBASH_LOCK_ROOT}/worker.lock/pid"
	mcp_lock_release_owned "worker" "$$"
	[ ! -d "${MCPBASH_LOCK_ROOT}/worker.lock" ]
	[ ! -d "${MCPBASH_LOCK_ROOT}/.reap.worker.lock" ]
}

@test "lock: acquire leaves no temp pid files behind" {
	mcp_lock_init
	mcp_lock_acquire "tidy"
	mcp_lock_release "tidy"
	run find "${MCPBASH_LOCK_ROOT}" -name '.pid.*'
	assert_output ""
}

@test "lock: a subshell records its own pid, so its lock is reaped once it dies" {
	mcp_lock_init
	# $$ is the parent shell's pid in every subshell; on bash 3.2 (no BASHPID)
	# the owner used to be recorded as $$, which stays alive, so a killed
	# worker's lock was never reaped.
	(
		mcp_lock_acquire "owned"
		sleep 30
	) &
	local holder=$!
	local n=0
	while [ ! -s "${MCPBASH_LOCK_ROOT}/owned.lock/pid" ]; do
		n=$((n + 1))
		[ "${n}" -lt 100 ] || fail "the subshell never took the lock"
		sleep 0.05
	done
	run cat "${MCPBASH_LOCK_ROOT}/owned.lock/pid"
	assert_output "${holder}"
	kill -KILL "${holder}" 2>/dev/null || true
	wait "${holder}" 2>/dev/null || true
	run mcp_lock_acquire_timeout "owned" 3
	assert_success
}

@test "lock: a subshell releases the lock it took" {
	mcp_lock_init
	(
		mcp_lock_acquire "sub"
		mcp_lock_release "sub"
	)
	[ ! -d "${MCPBASH_LOCK_ROOT}/sub.lock" ] || fail "subshell's lock still held: owner $(cat "${MCPBASH_LOCK_ROOT}/sub.lock/pid" 2>/dev/null)"
}

@test "lock: subshells of one shell contend correctly, and a killed holder is reaped" {
	mcp_lock_init
	local marks="${BATS_TEST_TMPDIR}/marks"
	mkdir -p "${marks}"
	# Workers are subshells of the server, as here; one is killed mid-hold.
	(
		mcp_lock_acquire "shared"
		: >"${marks}/held"
		sleep 30
	) &
	local victim=$!
	local n=0
	while [ ! -e "${marks}/held" ]; do
		n=$((n + 1))
		[ "${n}" -lt 100 ] || fail "the victim never took the lock"
		sleep 0.05
	done
	local w
	for w in 1 2 3 4; do
		(
			i=0
			while [ "${i}" -lt 15 ]; do
				mcp_lock_acquire "shared"
				if ! mkdir "${marks}/inside" 2>/dev/null; then
					printf 'x' >>"${marks}/overlaps"
				fi
				rmdir "${marks}/inside" 2>/dev/null || true
				mcp_lock_release "shared"
				i=$((i + 1))
			done
			: >"${marks}/done.${w}"
		) 2>>"${marks}/stderr" &
	done
	kill -KILL "${victim}" 2>/dev/null || true
	# Waiters must reap the dead holder's lock and finish.
	n=0
	while [ "$(ls "${marks}" | grep -c '^done\.')" -lt 4 ]; do
		n=$((n + 1))
		if [ "${n}" -ge 300 ]; then
			fail "waiters still blocked 15s after the holder was killed (lock owner: $(cat "${MCPBASH_LOCK_ROOT}/shared.lock/pid" 2>/dev/null))"
		fi
		sleep 0.05
	done
	wait
	[ ! -f "${marks}/overlaps" ] || fail "lock held twice at once $(wc -c <"${marks}/overlaps" | tr -d ' ') time(s)"
	[ ! -s "${marks}/stderr" ] || fail "stderr: $(head -n 3 "${marks}/stderr")"
	[ ! -d "${MCPBASH_LOCK_ROOT}/shared.lock" ]
}
