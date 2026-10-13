#!/usr/bin/env bats
# Unit layer: mcp_core_flush_stream (lib/core.sh), live progress/log delivery.
#
# A tool keeps appending to its stream while the server flushes it. A flush
# used to measure the size, then read to the end of the file and record the
# measured size as sent: a line appended in between was sent and then sent
# again by the next flush. A flush now sends exactly the bytes it measured,
# and only complete lines.

load '../../node_modules/bats-support/load'
load '../../node_modules/bats-assert/load'
load '../common/fixtures'

setup() {
	# shellcheck source=lib/runtime.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/runtime.sh"
	# shellcheck source=lib/core.sh
	# shellcheck disable=SC1091
	. "${MCPBASH_HOME}/lib/core.sh"
	MCPBASH_STATE_DIR="${BATS_TEST_TMPDIR}/state"
	mkdir -p "${MCPBASH_STATE_DIR}"
	unset MCPBASH_LOCK_ROOT
	SENT="${BATS_TEST_TMPDIR}/sent"
	: >"${SENT}"
	rpc_send_line() { printf '%s\n' "$1" >>"${SENT}"; }
	mcp_core_rate_limit() { return 0; }
	STREAM="${MCPBASH_STATE_DIR}/progress.k1.ndjson"
}

@test "flush_stream: a line appended after the size was measured is sent once" {
	printf '%s\n' '{"n":1}' >"${STREAM}"
	local first_len
	first_len="$(wc -c <"${STREAM}" | tr -d ' ')"
	printf '%s\n' '{"n":2}' >>"${STREAM}"

	# The first flush measures the size before line 2 arrived: its first wc
	# (the size measurement) reports the old size, later ones are real. The
	# lie is kept in a file because the flush calls wc in subshells.
	local lie="${BATS_TEST_TMPDIR}/wc.lie"
	printf '%s' "${first_len}" >"${lie}"
	wc() {
		if [ -s "${lie}" ]; then
			cat "${lie}"
			: >"${lie}"
		else
			command wc "$@"
		fi
	}
	mcp_core_flush_stream k1 progress
	mcp_core_flush_stream k1 progress

	run cat "${SENT}"
	assert_output $'{"n":1}\n{"n":2}'
}

@test "flush_stream: an incomplete last line waits until it is complete" {
	printf '%s\n%s' '{"n":1}' '{"n":' >"${STREAM}"
	mcp_core_flush_stream k1 progress
	run cat "${SENT}"
	assert_output '{"n":1}'

	printf '%s\n' '2}' >>"${STREAM}"
	mcp_core_flush_stream k1 progress
	run cat "${SENT}"
	assert_output $'{"n":1}\n{"n":2}'
}

@test "flush_stream: nothing new sends nothing" {
	printf '%s\n' '{"n":1}' >"${STREAM}"
	mcp_core_flush_stream k1 progress
	mcp_core_flush_stream k1 progress
	run cat "${SENT}"
	assert_output '{"n":1}'
}
