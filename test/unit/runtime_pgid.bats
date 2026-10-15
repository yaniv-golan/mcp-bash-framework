#!/usr/bin/env bats
# Unit layer: process group lookup (lib/runtime.sh) where ps cannot answer,
# as with BusyBox ps, which has no -p.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	if [ ! -r "/proc/$$/stat" ]; then
		skip "no /proc on this platform"
	fi
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "${STUB_BIN}"
	# BusyBox-style ps: no -p option.
	printf '#!/bin/sh\necho "ps: unrecognized option: p" >&2\nexit 1\n' >"${STUB_BIN}/ps"
	chmod +x "${STUB_BIN}/ps"
	CHILD=""
}

teardown() {
	[ -z "${CHILD:-}" ] || kill "${CHILD}" 2>/dev/null || true
}

# The pgid as the kernel reports it.
kernel_pgid() {
	local line
	line="$(cat "/proc/$1/stat")"
	line="${line##*) }"
	set -f
	# shellcheck disable=SC2086
	set -- ${line}
	set +f
	printf '%s' "$3"
}

@test "pgid: a process that is not a group leader reports its real group without ps -p" {
	# Started without job control, the child stays in this shell's group, so
	# its group differs from its pid.
	sleep 30 &
	CHILD=$!
	local expected
	expected="$(kernel_pgid "${CHILD}")"
	[ "${expected}" != "${CHILD}" ] || skip "child unexpectedly leads its own group"
	PATH="${STUB_BIN}:${PATH}" run mcp_runtime_lookup_pgid "${CHILD}"
	assert_success
	assert_output "${expected}"
}

@test "pgid: a command name with spaces and a parenthesis is parsed" {
	# A renamed bash (BusyBox applets such as sleep go by their name). The
	# trailing ":" keeps bash from exec-ing sleep, so the name stays.
	local odd="${BATS_TEST_TMPDIR}/a) b"
	cp "$(command -v bash)" "${odd}"
	"${odd}" -c 'sleep 30; :' &
	CHILD=$!
	sleep 0.2
	run mcp_runtime_proc_pgid "${CHILD}"
	assert_success
	assert_output "$(kernel_pgid "${CHILD}")"
}
