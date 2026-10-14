#!/usr/bin/env bats
# Unit layer: the per-worker inputs tag in lib/core.sh (mcp_core_inputs_tag_of,
# mcp_core_clear_inputs).

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
}

tag_of() { mcp_core_inputs_tag_of "$1"; }

@test "inputs tag: read from the end of a pid line, a stderr path with spaces included" {
	assert_equal "$(tag_of '123 123 /st dir/stderr.ImR1cCI.log ImR1cCI.12345')" "ImR1cCI.12345"
	assert_equal "$(tag_of '123 123 /x/s.log 12-34_a.17')" "12-34_a.17"
}

@test "inputs tag: none for '-', old three-field lines and anything not <base64url>.<digits>" {
	local line
	for line in '123 123 /st dir/stderr.ImR1cCI.log -' '123 123 /state/stderr.ImR1cCI.log' \
		'123 123 stderr.ImR1cCI.log' '1 2 /x/s.log *.1' '1 2 /x/s.log a.1*' '1 2 /x/s.log ../1' \
		'1 2 /x/s.log ..1' '1 2 /x/s.log a/b.1' '1 2 /x/s.log a.b.1' '1 2 /x/s.log .1' \
		'1 2 /x/s.log a.' '1 2 /x/s.log a.1x' '1 2 /x/s.log a.x1' '1 2 /x/s.log a.1?' \
		'1 2 /x/s.log a.[1]' '1 2 /x/s.log K.12 ' '' 'single'; do
		assert_equal "$(tag_of "${line}")" "" || fail "accepted: ${line}"
	done
}

@test "inputs tag: clearing one tag leaves the others" {
	MCPBASH_STATE_DIR="${BATS_TEST_TMPDIR}/st"
	mkdir -p "${MCPBASH_STATE_DIR}"
	touch "${MCPBASH_STATE_DIR}/inputs.K.12.completion-args.A" "${MCPBASH_STATE_DIR}/inputs.K.123.completion-args.B" \
		"${MCPBASH_STATE_DIR}/inputs.K.1.completion-args.C" "${MCPBASH_STATE_DIR}/inputs.KK.12.completion-args.D"
	mcp_core_clear_inputs "K.12"
	run ls "${MCPBASH_STATE_DIR}"
	assert_output "inputs.K.1.completion-args.C
inputs.K.123.completion-args.B
inputs.KK.12.completion-args.D"
	mcp_core_clear_inputs ""
	run ls "${MCPBASH_STATE_DIR}"
	assert_output --partial "inputs.K.1."
}
