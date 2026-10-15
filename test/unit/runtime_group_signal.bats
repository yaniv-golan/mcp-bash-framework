#!/usr/bin/env bats
# Unit layer: the delayed KILL after a cancel or timeout (lib/runtime.sh).
# It goes where it went before (the tool's group, or the worker pid when the
# worker shares the server's group), except to a group recreated since the
# TERM: a process whose pid is the group id, but not the one that was there.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	GROUP_LEADER=""
}

teardown() {
	[ -z "${GROUP_LEADER}" ] || kill -KILL "-${GROUP_LEADER}" 2>/dev/null || true
}

# Record signals instead of sending them.
mock_kill() {
	KILLS="${BATS_TEST_TMPDIR}/kills"
	: >"${KILLS}"
	kill() { printf '%s\n' "$*" >>"${KILLS}"; }
}

@test "delayed KILL: a worker in the server's group is killed alone" {
	command -v perl >/dev/null || skip "no perl"
	# A group of its own: a stand-in for the server (the leader), a bystander
	# (the host, say) and the worker, all in it.
	perl -e 'setpgrp(0,0); for my $s (9301, 9302) { if (!fork) { exec "sleep", $s } } exec "sleep", 9300' &
	GROUP_LEADER=$!
	local w b i=0
	while { w="$(pgrep -f 'sleep 9302$')"; b="$(pgrep -f 'sleep 9301$')"; [ -z "${w}" ] || [ -z "${b}" ]; } && [ "${i}" -lt 50 ]; do
		sleep 0.1
		i=$((i + 1))
	done
	[ -n "${w}" ] && [ -n "${b}" ] || fail "test processes did not start"
	local g="${GROUP_LEADER}"
	# As the call sites do: note the group before the TERM, KILL after.
	local snap
	snap="$(mcp_runtime_group_snapshot "${g}" "${w}")"
	mcp_runtime_signal_checked KILL "${g}" "${w}" "${g}" "${snap}"
	sleep 0.3
	# Killed or a zombie (the stand-in leader never reaps it).
	case "$(ps -o stat= -p "${w}" 2>/dev/null)" in '' | Z*) ;; *) fail "worker not killed" ;; esac
	kill -0 "${b}" 2>/dev/null || fail "bystander in the server's group was killed"
	kill -0 "${g}" 2>/dev/null || fail "the server stand-in was killed"
}

@test "delayed KILL: a group recreated since the TERM is left alone" {
	mock_kill
	# Each read gives a later start time (a counter in a file: the reads run
	# in command substitutions).
	COUNTER="${BATS_TEST_TMPDIR}/n"
	printf '0' >"${COUNTER}"
	mcp_runtime_process_identity() {
		local n
		n="$(cat "${COUNTER}")"
		n=$((n + 1))
		printf '%s' "${n}" >"${COUNTER}"
		printf 'start-%s' "${n}"
	}
	# Some process has the group id as its pid at both reads, but not the same one.
	mcp_runtime_pid_exists() { return 0; }
	mcp_runtime_signal_checked KILL 100 100 "" "$(mcp_runtime_group_snapshot 100 100)"
	run cat "${KILLS}"
	assert_output ""
}

@test "delayed KILL: the same leader, or none, gets the group signal as before" {
	mock_kill
	mcp_runtime_process_identity() { printf 'start-1'; }
	mcp_runtime_pid_exists() { return 0; }
	mcp_runtime_signal_checked KILL 100 100 "" "$(mcp_runtime_group_snapshot 100 100)"
	# The leader exited (its children may live on in the group): as before.
	mcp_runtime_pid_exists() { return 1; }
	mcp_runtime_signal_checked KILL 100 100 "" "start-1"
	run cat "${KILLS}"
	assert_output "-KILL -100
-KILL -100"
}

@test "delayed KILL: no identity (can't tell), as before" {
	mock_kill
	mcp_runtime_signal_checked KILL 100 100 "" ""
	run cat "${KILLS}"
	assert_output "-KILL -100"
}
